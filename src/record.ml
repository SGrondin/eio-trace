open Eio.Std

module Domains = Map.Make(Int)
module Fibers = Map.Make(Int)

module Write = Fxt.Write

type fiber = {
  id : int;
  mutable op : string option;   (* If suspended *)
}

type ring = {
  mutable current_fiber : fiber option;
}

type t = {
  pid : int64;
  fxt : Write.t;
  mutable rings : ring Domains.t;
  mutable fibers : fiber Fibers.t;
}

let ( <<< ) = Int64.shift_left
let ( +++ ) = Int64.add

let koid_of_ring id = (Int64.of_int id <<< 2) +++ 1L
let koid_of_eio id = (Int64.of_int id <<< 2) +++ 2L

let ring_thread t ring =
  { Write.pid = t.pid; tid = koid_of_ring ring }

let fiber_thread t fid =
  { Write.pid = t.pid; tid = koid_of_eio fid }

let get_fiber t id =
  match Fibers.find_opt id t.fibers with
  | Some x -> x
  | None ->
    let x = { id; op = None } in
    t.fibers <- Fibers.add id x t.fibers;
    x

let callbacks t =
  Runtime_events.Callbacks.create ()
    ~runtime_begin:(fun ring ts phase ->
        Write.duration_begin t.fxt
          ~thread:(ring_thread t ring)
          ~name:(Runtime_events.runtime_phase_name phase)
          ~category:"gc"
          ~ts:(Runtime_events.Timestamp.to_int64 ts)
      )
    ~runtime_end:(fun ring ts phase ->
        Write.duration_end t.fxt
          ~thread:(ring_thread t ring)
          ~name:(Runtime_events.runtime_phase_name phase)
          ~category:"gc"
          ~ts:(Runtime_events.Timestamp.to_int64 ts)
      )
    ~lost_events:(fun ring n -> traceln "Warning: ring %d lost %d events" ring n)
  |> Eio_runtime_events.add_callbacks
    (fun ring_id ts e ->
       let ts = Runtime_events.Timestamp.to_int64 ts in
       let ring =
         match Domains.find_opt ring_id t.rings with
         | Some x -> x
         | None ->
           let name = Printf.sprintf "ring%d" ring_id in
           Write.kernel_object t.fxt `Thread (koid_of_ring ring_id) ~name ~args:["process", `Koid t.pid];
           let x = { current_fiber = None } in
           t.rings <- Domains.add ring_id x t.rings;
           x
       in
       let current_fiber = ring.current_fiber in
       let thread =
         match current_fiber with
         | Some f -> fiber_thread t f.id
         | None -> ring_thread t ring_id
       in
       let set_current_fiber id =
         ring.current_fiber <- Some (get_fiber t id);
         Write.thread_wakeup ~cpu:ring_id ~ts t.fxt (Int64.of_int id)
       in
       (* Fmt.epr "%a@." Eio_runtime_events.pp_event e; *)
       match e with
       | `Fiber id ->
         set_current_fiber id;
         Fibers.find_opt id t.fibers |> Option.iter (fun fiber ->
             fiber.op |> Option.iter (fun op ->
                 let thread = fiber_thread t id in
                 Write.duration_end t.fxt ~thread ~ts ~name:op ~category:"eio.suspend";
                 fiber.op <- None;
               )
           )
       | `Create (id, detail) ->
         begin match detail with
           | `Fiber_in cc ->
             ignore (get_fiber t id : fiber);
             let name = Printf.sprintf "fiber%d" id in
             Write.kernel_object t.fxt `Thread (koid_of_eio id) ~name ~args:[
               "process", `Koid t.pid;
             ];
             set_current_fiber id;
             Write.instant_event t.fxt ~thread ~ts ~name:"create-fiber" ~category:"eio" ~args:[
               "id", `Pointer (Int64.of_int id);
               "cc", `Pointer (Int64.of_int cc);
             ];
           | `Cc ty ->
             Write.duration_begin t.fxt
               ~thread ~name:"cc" ~category:"eio" ~ts ~args:[
               "id", `Pointer (Int64.of_int id);
               "type", `String (Eio_runtime_events.cc_ty_to_string ty);
               "cpu", `Int64 (Int64.of_int ring_id);
             ]
           | `Obj _ty -> ()
         end
       | `Exit_fiber id ->
         Write.instant_event t.fxt ~thread ~ts ~name:"exit-fiber" ~category:"eio" ~args:[
           "id", `Pointer (Int64.of_int id);
         ]
       | `Name (id, name) ->
         Write.user_object t.fxt ~name ~thread (Int64.of_int id)
       | `Suspend_fiber op ->
         Option.iter (fun f -> f.op <- Some op) current_fiber;
         Write.duration_begin t.fxt ~thread ~ts ~name:op ~category:"eio.suspend";
         ring.current_fiber <- None
       | `Enter_span op ->
         Write.duration_begin t.fxt ~thread ~name:op ~category:"eio.span" ~ts
       | `Exit_span ->
         Write.duration_end t.fxt ~thread ~name:"" ~category:"eio.span" ~ts
       | `Exit_cc -> Write.duration_end t.fxt ~thread ~name:"cc" ~category:"eio" ~ts
       | `Log msg -> Write.instant_event t.fxt ~thread ~ts ~name:"log" ~category:"eio" ~args:[
           "message", `String msg;
         ]
       | `Suspend_domain Begin ->
         Write.duration_begin t.fxt ~thread:(ring_thread t ring_id) ~ts ~name:"suspend-domain" ~category:"eio"
       | `Suspend_domain End ->
         Write.duration_end t.fxt ~thread:(ring_thread t ring_id) ~ts ~name:"suspend-domain" ~category:"eio"
       | _ -> ()
    )

let trace ~child_finished ~delay t cursor =
  let callbacks = callbacks t in
  let rec aux () =
    let stop = !child_finished in
    let _ : int = Runtime_events.read_poll cursor callbacks None in
    if not stop then (
      Eio_unix.sleep delay;
      aux ()
    )
  in
  aux ()

let spawn_child ~sw ~proc_mgr ~tmp_dir args =
  let env =
    Array.append
      [|
        "OCAML_RUNTIME_EVENTS_START=1";
        "OCAML_RUNTIME_EVENTS_DIR=" ^ tmp_dir;
        "OCAML_RUNTIME_EVENTS_PRESERVE=1";
      |]
      (Unix.environment ())
  in
  Eio.Process.spawn ~sw proc_mgr ~env args

let rec get_cursor tmp_dir child =
  Eio_unix.sleep 0.1;
  try Runtime_events.create_cursor (Some (tmp_dir, Eio.Process.pid child))
  with Failure msg ->
    traceln "%s (will retry)" msg;
    get_cursor tmp_dir child

let ( / ) = Eio.Path.( / )

let run ?ui ?tracefile ~proc_mgr ~fs ~freq args =
  let delay = 1. /. freq in
  let fs = (fs :> Eio.Fs.dir_ty Eio.Path.t) in
  let tracefile = (tracefile :> Eio.Fs.dir_ty Eio.Path.t option) in
  Switch.run @@ fun sw ->
  let tmp_dir = Filename.temp_dir "eio-trace-" ".tmp" in
  let eio_tmp_dir = fs / tmp_dir in
  Switch.on_release sw (fun () -> Eio.Path.rmtree eio_tmp_dir);
  let tracefile =
    match tracefile with
    | Some x -> x
    | None -> eio_tmp_dir / "trace.fxt"
  in
  let out = Eio.Path.open_out ~sw tracefile ~create:(`Or_truncate 0o644) in
  Eio.Buf_write.with_flow out @@ fun w ->
  let fxt = Write.of_writer w in
  traceln "Recording to %a" Eio.Path.pp tracefile;
  let child = spawn_child ~sw ~proc_mgr ~tmp_dir args in
  let t = {
    fxt;
    pid = Int64.of_int (Eio.Process.pid child);
    rings = Domains.empty;
    fibers = Fibers.empty;
  } in
  let finished, set_finished = Promise.create () in
  let child_finished = ref false in
  Switch.run @@ fun sw ->       (* Fibers need to prevent [w] from closing, so need new switch *)
  Fiber.fork ~sw
    (fun () ->
       let cursor = get_cursor tmp_dir child in
       trace t ~child_finished ~delay cursor;
       Promise.resolve set_finished ()
    );
  Fiber.fork ~sw
    (fun () ->
       Fun.protect (fun () -> Eio.Process.await_exn child)
         ~finally:(fun () -> child_finished := true);
    );
  match ui with
  | None -> Ok ()
  | Some ui ->
    (* Wait up to a second for the child to do something before showing the trace *)
    Fiber.first
      (fun () -> Promise.await finished)
      (fun () -> Eio_unix.sleep 1.);
    ui (Eio.Path.native_exn tracefile)
