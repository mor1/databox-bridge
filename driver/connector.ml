open Lwt.Infix
open Mirage_types_lwt

let connector = Logs.Src.create "connector" ~doc:"Network Connector"
module Log = (val Logs_lwt.src_log connector : Logs_lwt.LOG)

let _ = Printexc.record_backtrace true
module Ethif = Ethif.Make(Netif)
module Arpv4 = Arpv4.Make(Ethif)(Mclock)(OS.Time)
module Static_ipv4 = Static_ipv4.Make(Ethif)(Arpv4)


module Make(N: NETWORK)(E: ETHIF)(Arp: ARP)(Ip: IPV4) = struct

  type ip_pool = {
    mutable free_ips: Ipaddr.V4.t list;
    mutable used_ips: Ipaddr.V4.t list;
    mutex: Lwt_mutex.t;
  }

  let _free_ip_cnt = 2
  let _detect_duplicates_sleep = 5000. (* ms *)

  let count_free ipp =
    Lwt_mutex.with_lock ipp.mutex (fun () ->
        Lwt.return @@ List.length ipp.free_ips)

  let put_ip ipp ip =
    Lwt_mutex.with_lock ipp.mutex (fun () ->
        ipp.free_ips <- ip :: ipp.free_ips;
        Lwt.return_unit)

  let use_ip ipp () =
    Lwt_mutex.with_lock ipp.mutex (fun () ->
        let ip = List.hd ipp.free_ips in
        ipp.free_ips <- (List.tl ipp.free_ips);
        ipp.used_ips <- ip :: ipp.used_ips;
        Lwt.return ip)


  let delete_duplicated ~delete_used ip ipp cond =
    Lwt_mutex.with_lock ipp.mutex (fun () ->
        let free_ips' =
          List.filter (fun free -> 0 <> Ipaddr.V4.compare ip free) ipp.free_ips in
        if List.length free_ips' < List.length ipp.free_ips then begin
          ipp.free_ips <- free_ips';
          Lwt_condition.signal cond () end;
        Lwt.return_unit) >>= fun () ->

    Lwt_mutex.with_lock ipp.mutex (fun () ->
        Lwt.return ipp.used_ips)
    >>= fun used_ips ->
    if List.mem ip used_ips then
      delete_used ip >>= fun () ->
      Lwt_mutex.with_lock ipp.mutex (fun () ->
          let used_ips' =
            List.filter (fun used -> 0 <> Ipaddr.V4.compare ip used) ipp.used_ips in
          ipp.used_ips <- used_ips';
          Lwt.return_unit)
    else Lwt.return_unit


  let detect_duplicates ~delete_used ipp arp cond =
    Lwt_mutex.with_lock ipp.mutex (fun () ->
        Lwt.return @@ (ipp.free_ips @ ipp.used_ips))
    >>= Lwt_list.iter_p (fun ip ->
        Arp.query arp ip >>= function
        | Ok _ ->
            Log.warn (fun m -> m "duplicate detected: %a" Ipaddr.V4.pp_hum ip)
            >>= fun () ->
            delete_duplicated ~delete_used ip ipp cond
        | Error _ -> Lwt.return_unit)


  let populate_pool ipp arp cond Proto.({interface; netmask}) =
    let network =
      let ip = Ipaddr.V4.of_string_exn interface in
      let prefix = Ipaddr.V4.Prefix.make netmask ip in
      Ipaddr.V4.Prefix.network prefix in
    let last_added =
      let net = Ipaddr.V4.to_int32 network in
      ref (Int32.(add net (shift_left one netmask |> pred))) in
    let next () =
      let next = Int32.(sub !last_added one) in
      last_added := next;
      Ipaddr.V4.of_int32 next in

    let rec count_and_put () =
      count_free ipp >>= fun cnt ->
      if cnt < _free_ip_cnt then
        let candidate = next () in
        Arp.query arp candidate >>= function
        | Ok _ -> count_and_put ()
        | Error _ -> put_ip ipp candidate
      else Lwt_condition.wait cond >>= count_and_put
    in
    count_and_put ()


  let drain_pool ipp arp cond conn =
    let open Proto in
    let rec provision_ip () =
      Client.recv_comm conn >>= function
      | IP_REQ seq ->
          use_ip ipp () >>= fun ip ->
          Client.send_comm conn (ACK (ip, seq)) >>= fun () ->
          Lwt_condition.signal cond ();
          Arp.add_ip arp ip >>= fun () ->
          provision_ip ()
      | _ ->
          Log.err (fun m -> m "provision ip: not IP_REQ") >>= fun () ->
          provision_ip () in

    let delete_used arp ip =
      Client.send_comm conn (IP_DUP ip) >>= fun () ->
      Arp.remove_ip arp ip in
    let rec detect_dup_loop () =
      detect_duplicates ~delete_used:(delete_used arp) ipp arp cond >>= fun () ->
      Lwt_unix.sleep _detect_duplicates_sleep >>= fun () ->
      detect_dup_loop () in

    provision_ip () <&> detect_dup_loop ()


  let maintain_ipp arp conn endp =
    let ipp = {free_ips = []; used_ips = []; mutex = Lwt_mutex.create ()} in
    let cond = Lwt_condition.create () in
    populate_pool ipp arp cond endp <&> drain_pool ipp arp cond conn



  let hexdump_buf_debug desp buf =
    Log.debug (fun m ->
        let b = Buffer.create 128 in
        Cstruct.hexdump_to_buffer b buf;
        m "%s len:%d pkt:%s" desp (Cstruct.len buf) (Buffer.contents b))

  let drop_pkt (_: Cstruct.t) = Lwt.return_unit

  let is_ipv4_multicast buf =
    let dst = Cstruct.BE.get_uint32 buf 16 |> Ipaddr.V4.of_int32 in
    Ipaddr.V4.is_multicast dst


  let to_bridge conn buf =
    Lwt.catch
      (fun () ->
         if is_ipv4_multicast buf
         then Lwt.return_unit
         else
         Proto.Client.send_pkt conn buf
         (*>>= fun () -> hexdump_buf_debug "to_bridge" buf*))
      (fun e ->
         let msg = Printf.sprintf "to_bridge err: %s" @@ Printexc.to_string e in
         Log.err (fun m -> m "%s" msg) >>= fun () ->
         hexdump_buf_debug "to_bridge" buf)


  let rec from_bridge eth arp conn =
    Proto.Client.recv_pkt conn >>= fun buf ->

    let dst_ipaddr = Cstruct.BE.get_uint32 buf 16 |> Ipaddr.V4.of_int32 in
    Arp.query arp dst_ipaddr >>= function
    | Ok destination ->
        let eth_hd =
          let source = E.mac eth in
          let ethertype = Ethif_wire.IPv4 in
          Ethif_packet.(Marshal.make_cstruct {source; destination; ethertype})
        in
        let buf = Cstruct.append eth_hd buf in
        (E.write eth buf >>= function
          | Ok () ->
              from_bridge eth arp conn
          | Error e ->
              Log.err (fun m -> m "from bridge E.write: %a" E.pp_error e))
    | Error e ->
        Log.err (fun m -> m "from bridge Arp.query: %a" Arp.pp_error e)


  let forward_pkt nf eth arp conn endp =
    let to_bridge eth arp conn  =
      (*sendint ip packet to bridge, not ethernet frame*)
      let ipv4 = to_bridge conn in
      let arpv4 = Arp.input arp in
      let ipv6 = drop_pkt in
      let fn = E.input ~arpv4 ~ipv4 ~ipv6 eth in
      N.listen nf fn >>= function
      | Ok () ->
          Log.info (fun m -> m "to_bridge ok: %s" @@ Proto.endp_to_string endp)
      | Error e ->
          Log.err (fun m -> m "to_bridge err: %a" N.pp_error e)
    in

    Lwt.pick [
      to_bridge eth arp conn;
      from_bridge eth arp conn;
    ]


  let start ?(socket_path="/var/tmp/bridge") nf eth arp ip endp =
    Proto.Client.connect socket_path endp >>= function
    | Ok conn ->
        Lwt.pick [
          maintain_ipp arp conn endp;
          forward_pkt nf eth arp conn endp;
        ] >>= fun () ->
        Proto.Client.disconnect conn
    | Error (`Msg msg) ->
        Log.err (fun m -> m "can't connect to %s: %s" socket_path msg)

end


let start dev addr =
  let t =
    Netif.connect dev >>= fun net ->
    Mclock.connect () >>= fun mclock ->
    Ethif.connect net >>= fun ethif ->
    Arpv4.connect ethif mclock >>= fun arp ->
    let network, ip = Ipaddr.V4.Prefix.of_address_string_exn addr in
    Static_ipv4.connect ~ip ~network ~gateway:None ethif arp >>= fun ipv4 ->
    let module M = Make(Netif)(Ethif)(Arpv4)(Static_ipv4) in
    let mac = Ethif.mac ethif in
    let netmask = Ipaddr.V4.Prefix.bits network in
    let endp = Proto.create_endp dev mac ip netmask in
    M.start net ethif arp ipv4 endp
  in
  Lwt.async (fun () ->
      Lwt.finalize (fun () ->
          Lwt.catch (fun () -> t) (fun exn ->
              Log.err (fun m -> m "connector err: %s" (Printexc.to_string exn))))
        (fun () ->
           Log.debug (fun m -> m "connector on [%s/%s] existed!" dev addr)))