(*
 * Copyright (c) 2013-2015 David Sheets <sheets@alum.mit.edu>
 * Copyright (c)      2015 Qi Li <liqi0425@gmail.com>
 * Copyright (c)      2015 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

let debug fmt = Gol.debug ~section:"master" fmt

module Response = Cohttp_lwt_unix.Response
module Body = Cohttp_lwt_body

let body_of_message m =
  Message.sexp_of_master_msg m
  |> Sexplib.Sexp.to_string
  |> Body.of_string

let message_of_body body =
  Body.to_string body >>= fun b ->
  Sexplib.Sexp.of_string b
  |> Message.worker_msg_of_sexp
  |> Lwt.return

let empty_response ~status =
  let resp = Response.make ~status () in
  let body = Body.empty in
  Lwt.return (resp, body)

let register_handler s _params _headers body =
  message_of_body body >>= fun m ->
  let host =
    let open Message in
    match m with
    | Register h -> h
    | Heartbeat _ | Publish _ | Spawn_jobs _ ->
      failwith "Wrong message for register"
  in
  let id, token = Monitor.new_worker host in
  Store.register_token s token >>= fun () ->
  let m = Message.Ack_register (id, token) in
  let resp = Response.make ~status:`Created () in
  let body = body_of_message m in
  debug "register: %d new worker registered" id;
  Lwt.return (resp, body)

let heartbeat_handler params headers body =
  let id = List.assoc "id" params |> int_of_string in
  let token =
    match Cohttp.Header.get headers "worker" with Some t -> t | None -> ""
  in
  Monitor.verify_worker id token;
  message_of_body body >|= fun m ->
  let resp_m =
    let open Message in
    match m with
    | Heartbeat None ->
      debug "heartbeat: %d idle" id;
      (match Scheduler.find_job token with
       | None -> Ack_heartbeat
       | Some (jid, c, desp) -> Monitor.new_job jid c token;
         New_job (jid, desp))
    | Heartbeat (Some _jid) ->
      Message.Ack_heartbeat
    | Register _ | Publish _ | Spawn_jobs _ ->
      failwith "wrong message for heartbeat"
  in
  let resp = Response.make ~status:`OK () in
  let body = body_of_message resp_m in
  resp, body

let publish_handler s params headers body =
  let id = List.assoc "id" params |> int_of_string in
  let token =
    match Cohttp.Header.get headers "worker" with Some t -> t | None -> ""
  in
  Monitor.verify_worker id token;
  message_of_body body >>= fun m ->
  let result, jid =
    let open Message in
    match m with
    | Publish (result, id) -> result, id
    | Register _ | Heartbeat _ | Spawn_jobs _ ->
      failwith "wrong message for publish"
  in
  let r = match result with
    | `Success ->
      Monitor.publish_object jid token; "SUCCESS"
    | `Delegate d ->
      Monitor.job_completed jid token; "DELEGATE: " ^ Scheduler.task_info d
    | `Fail f ->
      Monitor.job_completed jid token; "FAIL: " ^ f
  in
  debug "publish: %d object %s %s" id (Scheduler.task_info jid) r;
  Scheduler.publish_object s token result jid >>= fun () ->
  empty_response ~status:`Created

let spawn_handler s params headers body =
  let id = List.assoc "id" params |> int_of_string in
  let token =
    match Cohttp.Header.get headers "worker" with Some t -> t | None -> ""
  in
  Monitor.verify_worker id token;
  message_of_body body >>= fun m ->
  let m_job_lst =
    let open Message in
    match m with
    | Spawn_jobs job_lst -> job_lst
    | Publish _ | Register _ | Heartbeat _ ->
      failwith "wrong message for spawn"
  in
  let job_lst =
    List.rev_map (fun (jid, desp, deps) ->
        let job = Job.of_string desp in
        jid, job, deps
      ) m_job_lst
  in
  Scheduler.update_tables s job_lst >>= fun () ->
  empty_response ~status:`Created

let github_hook_handler _s params _headers _body =
  let _pr_num = List.assoc "pr_num" params |> int_of_string in
  (* Scheduler.github_hook s pr_num >>= fun () ->
     empty_response ~status:`Accepted *)
  failwith "TODO"

let mk_pkg str =
  match Stringext.cut str ~on:"." with
  | None        -> Package.create str
  | Some (n, v) -> Package.create ~version:v n

let user_pkg_demand_handler s params _headers _body =
  let c = try List.assoc "compiler" params with _ -> "" in
  let dep = try List.assoc "depopt" params with _ -> "" in
  let repo_name = try List.assoc "name" params with _ -> "" in
  let repo_addr = try List.assoc "address" params with _ -> "" in
  let split s ~by = Re.(by |> char |> compile |> (fun re -> split re s)) in
  let pin_pkg = try List.assoc "pin" params with _ -> "" in
  let pin_target = try List.assoc "target" params with _ -> "" in
  let compilers = split c ~by:';' in
  let depopts = split dep ~by:';' in
  let repositories: Task.repository list =
    if repo_name = "" || repo_addr = "" then
      []
    else (
      let names = split repo_name ~by:';' in
      let addrs = split repo_addr ~by:';' in
      assert (List.length names = List.length addrs);
      List.combine names addrs
    )
  in
  let pins: Task.pin list =
    if pin_pkg = "" || pin_target = "" then
      []
    else (
      let pkgs = split pin_pkg ~by:';' in
      let targets = split pin_target ~by:';' in
      assert (List.length pkgs = List.length targets);
      List.combine pkgs targets
    )
  in
  let pkg = mk_pkg (List.assoc "pkg" params) in
  let depopts = List.rev_map mk_pkg depopts in
  let ptask = Task.create ~depopts pkg in
  let worker_hosts = Monitor.worker_environments () in
  let envs =
    List.fold_left (fun acc h ->
        let compilers =
          if compilers = [] then Monitor.compilers () else compilers
        in
        (List.rev_map (fun c -> h, c) compilers) @ acc
      ) [] worker_hosts
  in
  let job_lst =
    List.rev_map (fun (h, c) ->
        let id = Task.hash_id ~repositories ~pins ptask [] c h in
        let job =
          Job.create ~id ~inputs:[] ~compiler:c ~host:h ~repositories ~pins ptask
        in
        id, job, []
      ) envs
  in
  Scheduler.update_tables s job_lst >|= fun () ->
  let resp = Response.make ~status:`Accepted () in
  let ids = List.rev_map (fun (id, _, _) -> id) job_lst in
  let body_str = Printf.sprintf "%s\n" (String.concat "\n" ids) in
  let body = Body.of_string body_str in
  resp, body

let user_job_query_handler s params _headers _body =
  let jid = List.assoc "jid" params in
  Scheduler.progress_info s jid >|= fun str ->
  let body = Body.of_string str in
  let resp = Response.make ~status:`OK () in
  resp, body

let user_worker_query_handler _param _headers _body =
  let statuses = Monitor.worker_statuses () in
  let info =
    List.rev_map (fun (wid, token, status) ->
        let status_str = match Monitor.info_of_status status with
          | s, None -> s
          | s, Some id -> Printf.sprintf "%s %s" s (Scheduler.task_info id) in
        let h, _ = Monitor.worker_env token in
        Printf.sprintf "worker %d, %s, %s" wid h status_str
      ) statuses
  in
  let str =
    Printf.sprintf "%s\n"
      (if info <> [] then (String.concat "\n" info) else "No alive workers")
  in
  let resp = Response.make ~status:`OK () in
  let body = Body.of_string str in
  Lwt.return (resp, body)

let user_object_query_handler s params _headers _body =
  let jid = List.assoc "jid" params in
  Lwt.catch (fun () ->
      Store.retrieve_job s jid >>= fun (job, _) ->
      Store.retrieve_object s jid >>= fun obj ->
      let inputs = Job.inputs job in
      let c, h = Job.env job in
      let task_info = Job.task job |> Task.info_of_task in
      let result = Object.result obj in
      Lwt_list.rev_map_s (fun i ->
          Store.retrieve_job s i >|= fun (j, _) ->
          i ^ ":" ^ (Job.task j |> Task.info_of_task)
        ) inputs
      >|= fun input_info ->
      let input_info = Printf.sprintf "\n%s" (String.concat "\n" input_info) in
      let cut str = String.sub str 0 5 in
      let ass_lst = [
        "Id"    , cut jid;
        "Task"  , task_info;
        "Inputs", input_info;
        "Env"   , Printf.sprintf "%s %s" c h;
        "Result", Object.string_of_result result
      ] in
      let str =
        List.map (fun (n, v) -> Printf.sprintf "[%s]: %s" n v) ass_lst
        |> String.concat "\n"
        |> (fun info -> info ^ "\n")
      in
      let resp = Response.make ~status:`OK () in
      let body = Body.of_string str in
      resp, body)
    (fun _exn ->
       empty_response ~status:`Not_found)

open Opium.Std

let handler_wrapper handler keys req =
  let params = List.map (fun k -> k, param req k) keys in
  let headers = Request.headers req in
  let body = req.Request.body in
  handler params headers body >>= fun r ->
  Response.of_response_body r
  |> Lwt.return

let register s =
  post "/worker/registration"
       (handler_wrapper (register_handler s) [])

let heartbeat =
  post "/workers/:id/state"
       (handler_wrapper heartbeat_handler ["id"])

let publish s =
  post "/workers/:id/objects"
       (handler_wrapper (publish_handler s) ["id"])

let spawn s =
  post "/workers/:id/newjobs"
       (handler_wrapper (spawn_handler s) ["id"])

let github_hook s =
  post "/github/:pr_num"
       (handler_wrapper (github_hook_handler s) ["pr_num"])

let package_demand s =
  post "/package/:pkg" (fun req ->
    let uri = Request.uri req in
    let query' = Uri.query uri in
    let query = List.map (fun (k, vs) -> k, String.concat ";" vs) query' in
    let pkg = param req "pkg" in
    let params = ("pkg", pkg) :: query in
    let headers = Request.headers req in
    let body = req.Request.body in
    user_pkg_demand_handler s params headers body >>= fun r ->
    Response.of_response_body r
    |> Lwt.return)

let job_query s =
  get "/object/:jid"
      (handler_wrapper (user_job_query_handler s) ["jid"])

let worker_query =
  get "/workers/statuses"
      (handler_wrapper user_worker_query_handler [])

let object_info_query t =
  get "/object/:jid/info"
      (handler_wrapper (user_object_query_handler t) ["jid"])

let server s =
  App.empty
  |> register s
  |> heartbeat
  |> publish s
  |> spawn s
  |> package_demand s
  |> github_hook s
  |> job_query s
  |> worker_query
  |> object_info_query s

let run ~fresh ~uri ~ip:_ip ~port =
  (* FIXME: ip is not used! *)
  Store.create ~uri ~fresh () >>= fun s ->
  Scheduler.bootstrap s >>= fun () ->
  let rec t_monitor () =
    Monitor.worker_monitor s >>= fun workers ->
    debug "monitor: a worker died!";
    List.iter (fun (_, t) -> Scheduler.invalidate_token t) workers;
    t_monitor ()
  in
  Lwt.join [App.start (server s |> App.port port); t_monitor ()]
