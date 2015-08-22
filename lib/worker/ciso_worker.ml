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

let debug fmt = Gol.debug ~section:"worker" fmt
let err fmt = Printf.ksprintf Lwt.fail_with ("Ciso.Worker: " ^^ fmt)
let failwith fmt = Printf.ksprintf failwith ("Ciso.Worker: " ^^ fmt)

let (/) = Filename.concat

module Body = Cohttp_lwt_body
module Code = Cohttp.Code
module Client = Cohttp_lwt_unix.Client
module Response = Cohttp_lwt_unix.Response

module IdSet = struct
  include Set.Make(struct
      type t = [`Object] Id.t
      let compare = Id.compare
    end)
  let of_list = List.fold_left (fun s e -> add e s) empty
end

module System = struct

  (* FIXME: use Bos? *)

  (* from ocaml-git/lib/unix/git_unix.ml *)

  let openfile_pool = Lwt_pool.create 200 (fun () -> Lwt.return_unit)

  let mkdir_pool = Lwt_pool.create 1 (fun () -> Lwt.return_unit)

  let protect_unix_exn = function
    | Unix.Unix_error _ as e -> Lwt.fail (Failure (Printexc.to_string e))
    | e -> Lwt.fail e

  let ignore_enoent = function
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
    | e -> Lwt.fail e

  let protect f x = Lwt.catch (fun () -> f x) protect_unix_exn

  let safe f x = Lwt.catch (fun () -> f x) ignore_enoent

  let remove_file f = safe Lwt_unix.unlink f

  let mkdir dirname =
    let rec aux dir =
      if Sys.file_exists dir && Sys.is_directory dir then Lwt.return_unit
      else (
        let clear =
          if Sys.file_exists dir then (
            Log.debug "%s already exists but is a file, removing." dir;
            remove_file dir;
          ) else
            Lwt.return_unit
        in
        clear >>= fun () ->
        aux (Filename.dirname dir) >>= fun () ->
        Log.debug "mkdir %s" dir;
        protect (Lwt_unix.mkdir dir) 0o755;
      ) in
    Lwt_pool.use mkdir_pool (fun () -> aux dirname)

  let write_cstruct fd b =
    let rec rwrite fd buf ofs len =
      Lwt_bytes.write fd buf ofs len >>= fun n ->
      if len = 0 then Lwt.fail End_of_file
      else if n < len then rwrite fd buf (ofs + n) (len - n)
      else Lwt.return_unit in
    match Cstruct.len b with
    | 0   -> Lwt.return_unit
    | len -> rwrite fd (Cstruct.to_bigarray b) 0 len

  let with_write_file ?temp_dir file fn =
    begin match temp_dir with
      | None   -> Lwt.return_unit
      | Some d -> mkdir d
    end >>= fun () ->
    let dir = Filename.dirname file in
    mkdir dir >>= fun () ->
    let tmp = Filename.temp_file ?temp_dir (Filename.basename file) "write" in
    Lwt_pool.use openfile_pool (fun () ->
        Log.info "Writing %s (%s)" file tmp;
        Lwt_unix.(openfile tmp [O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC] 0o644) >>= fun fd ->
        Lwt.finalize
          (fun () -> protect fn fd >>= fun () -> Lwt_unix.rename tmp file)
          (fun _  -> Lwt_unix.close fd)
      )

  let write_file file ?temp_dir b =
    with_write_file file ?temp_dir (fun fd -> write_cstruct fd b)

  let read_file file =
    Unix.handle_unix_error (fun () ->
        Lwt_pool.use openfile_pool (fun () ->
            Log.info "Reading %s" file;
            let fd = Unix.(openfile file [O_RDONLY; O_NONBLOCK] 0o644) in
            let ba = Lwt_bytes.map_file ~fd ~shared:false () in
            Unix.close fd;
            Lwt.return (Cstruct.of_bigarray ba)
          ))
      ()

  (* end of ocaml-git *)

  let niet () = Lwt.return_unit

  let exec ?on_failure ?(on_success=niet) cmd =
    let on_failure = match on_failure with
      | None   -> (fun () -> err "%S: failure" cmd)
      | Some f -> f
    in
    let open Lwt_unix in
    Lwt_unix.system cmd >>= function
    | WEXITED rc when rc = 0 -> on_success ()
    | WEXITED _ | WSIGNALED _ | WSTOPPED _ -> on_failure ()

  let install_archive (name, content) =
    let tmp = "/tmp/ciso-" / name in
    if Sys.file_exists tmp then Sys.remove tmp;
    write_file tmp content >>= fun () ->
    Lwt.return tmp

  let extract_archive tar =
    if not (Filename.check_suffix tar ".tar.gz") then
      raise (Invalid_argument tar);
    let cmd = Printf.sprintf "tar -xzf %s -C /" tar in
    let on_failure () = err "extract: cannot untar %s" tar in
    let on_success () = debug "extract: OK"; Lwt.return_unit in
    exec ~on_success ~on_failure cmd

  let install_files ~src ~dst files =
    let cp src dst =
      let comm = Printf.sprintf "cp %s %s" src dst in
      let on_failure () = err "cp: cannot copy %s to %s" src dst in
      let on_success () = debug "%s installed" src; Lwt.return_unit in
      exec ~on_success ~on_failure comm
    in
    Lwt_list.iter_s (fun (f, _) ->
        (* FIXME: verify integrity of the digest? *)
        let src_path = src / f in
        let dst_path = dst / f in
        mkdir (Filename.dirname (dst / f)) >>= fun () ->
        cp src_path dst_path
      ) files

  let name_of_archive name =
    assert (Filename.check_suffix name ".tar.gz");
    Filename.chop_extension (Filename.chop_extension name)

  let clean_tmp action name =
    let file = "/tmp" / name in
    let dir = "/tmp" / name_of_archive name in
    let comm = Printf.sprintf "rm -rf %s %s" file dir in
    let on_success () =
      debug "clean_tmp: %s done (%s %s)!" action file dir;
      Lwt.return_unit
    in
    let on_failure () = err "cannot remove %s and %s" file dir in
    exec ~on_failure ~on_success comm

end

type t = {
  w     : Worker.t;                              (* the worker configuration. *)
  local : Store.t;              (* the local store, which is used as a cache. *)
  global: Store.t;                   (* the global store, accessed over HTTP. *)
}

let idle_sleep = 3.0
let working_sleep = 40.0
let master_timeout = 15.0
let origin_fs = ref []

let working_directory w =
  let path = Sys.getenv "HOME"/ "worker-" ^ Id.to_string (Worker.id w) in
  if not (Sys.file_exists path) then
    Lwt_unix.mkdir path 0o770 >|= fun () -> path
  else
    Lwt.return path

let archive_dir id =
  Filename.get_temp_dir_name () / Id.to_string id  ^ ".tar.gz"

let local_store w =
  working_directory w >>= fun root ->
  Store.local ~root ()

let create w uri =
  local_store w        >>= fun local ->
  Store.remote ~uri () >|= fun global ->
  { w; local; global }

let snapshots ?white_list ~prefix =
  let rec loop checksums = function
    | [] -> checksums
    | path :: tl ->
      (* soft link to absent file *)
      if not (Sys.file_exists path) then loop checksums tl
      else if not (Sys.is_directory path) then
        loop ((path, Digest.file path) :: checksums) tl
      else
        let files =
          Sys.readdir path
          |> Array.to_list
          |> List.rev_map (fun f -> path / f)
        in
        loop checksums (List.rev_append files tl)
  in
  let sub_dirs =
    Sys.readdir prefix
    |> Array.to_list
    |> (fun lst -> match white_list with
        | Some wl -> List.filter (fun n -> List.mem n wl) lst
        | None    -> lst)
    |> List.rev_map (fun n -> prefix / n)
  in
  loop [] sub_dirs

let opam_snapshot ~prefix =
  if Sys.file_exists (prefix / "installed") then Opam.read_installed ()
  else []

(* FIXME: we want the outputs even if the job succeeds *)
let collect_outputs ~prefix name = function
  | `Success -> Lwt.return []
  | `Failure ->
     let relative_path = "build" / name in
     let path = prefix / relative_path in
     if Sys.file_exists path then
       let files = Sys.readdir path |> Array.to_list in
       List.filter (fun f ->
           List.exists
             (fun suffix -> Filename.check_suffix f suffix)
             [".info"; ".err"; ".out"; ".env"]
         ) files
       |> List.rev_map (fun f -> let f = relative_path / f in f, Digest.file f)
       |> Lwt.return
     else
       Lwt.return []

let collect_installed ~prefix ~before ~after =
  let module CsMap = Map.Make(String) in
  let cmap =
    List.fold_left
      (fun acc (f, checksum) -> CsMap.add f checksum acc)
      CsMap.empty before
  in
  (* TODO: collect deleted files *)
  let installed =
    List.fold_left (fun acc (f, checksum) ->
        if not (CsMap.mem f cmap) then (f, checksum) :: acc else
          let cs = CsMap.find f cmap in
          if cs <> checksum then (f, checksum) :: acc else acc
      ) [] after
  in
  (* 1 is for the delimiter *)
  let len = 1 + String.length prefix in
  let chop_prefix (f, c) =
    try String.sub f len (String.length f - len), c
    with e -> print_endline f; raise e
  in
  let files = List.rev_map chop_prefix installed in
  Lwt.return files

(* FIXME: console outputs should not be in the archive *)
let create_archive ~prefix job files ~old_pkgs ~new_pkgs =
  let path = archive_dir (Job.id job) in
  let dir  = Filename.dirname path in
  System.install_files ~src:prefix ~dst:dir files >>= fun () ->
  let installed = List.filter (fun p -> not (List.mem p old_pkgs)) new_pkgs in
  Opam.write_installed installed;
  let cmd = Printf.sprintf "tar -zcf %s %s" path dir in
  System.exec cmd >>= fun () ->
  System.read_file path >|= fun content ->
  Object.archive files content

let extract_object ~prefix obj =
  match Object.contents obj with
  | Object.Stderr _ | Object.Stdout _ -> Lwt.return_unit
  | Object.Archive { Object.files; raw } ->
    let path = archive_dir (Object.id obj) in
    System.install_archive (path, raw) >>= fun arch_path ->
    System.extract_archive arch_path >>= fun () ->
    let src = System.name_of_archive arch_path in
    System.install_files ~src ~dst:prefix files >>= fun () ->
    System.clean_tmp "extract_object" (Filename.basename arch_path)

let prepare ~prefix t job  =
  Lwt_list.fold_left_s (fun acc jid ->
      Store.Job.outputs t.local jid >|= fun objs ->
      objs @ acc
    ) [] (Job.inputs job)
  >>= fun objs ->
  (* URGENT FIXME: installation order IS important *)
  Lwt_list.iter_p (fun oid ->
      Store.Object.find t.local oid >>= function
      | None   -> err "cannot find object %s" (Id.to_string oid)
      | Some o -> extract_object ~prefix o
    ) objs

let default_white_list = ["lib"; "bin"; "sbin"; "doc"; "share"; "etc"; "man"]

let build ?(white_list=default_white_list) t job name ~prefix ~install ~remove =
  prepare ~prefix t job  >>= fun () ->
  debug "build: %s, snapshot %s BEFORE" name prefix;
  let before = snapshots ~white_list ~prefix in
  let old_pkgs = opam_snapshot ~prefix in
  debug "build: %s" name;
  begin
    Lwt.catch
      (fun ()   -> install () >|= fun () -> `Success)
      (fun _exn -> Lwt.return `Failure)
  end >>= fun result ->
  let () = match result with
    | `Success -> debug "build: %s Success!" name
    | `Failure -> debug "build: %s Failure!" name
  in
  debug "build: %s, snapshot %s AFTER" name prefix;
  let after = snapshots ~white_list ~prefix in
  let new_pkgs = opam_snapshot ~prefix in
  (* FIXME: move the outputs out of the archive *)
  collect_outputs ~prefix name result      >>= fun output ->
  collect_installed ~prefix ~before ~after >>= fun installed ->
  create_archive ~prefix job (output@installed) ~old_pkgs ~new_pkgs
  >>= fun archive ->
  System.clean_tmp "pkg_build" (archive_dir @@ Job.id job) >>= fun () ->
  remove () >|= fun () ->
  Store.with_transaction t.local "Job complete" (fun t ->
      Store.Object.add t archive >>= fun () ->
      Store.Job.add_output t (Job.id job) (Object.id archive)
    ) >|= function
  | true  -> result
  | false -> `Failure

let build_pkg s job pkgs =
  let pkgs = List.map fst pkgs in
  let name = String.concat ", " (List.map Package.to_string pkgs) in
  let prefix = Opam.root () / Switch.to_string (Job.switch job) in
  build s job name
    ~install:(fun () -> Opam.install pkgs)
    ~remove: (fun () -> Opam.remove pkgs)
    ~prefix

let build_switch s job =
  let switch = Job.switch job in
  let name = Switch.to_string switch in
  let prefix = Opam.root () / name in
  build s job name
    ~install:(fun () -> Opam.switch_to switch)
    ~remove: (fun () -> Lwt.return_unit)
    ~prefix

let procees_job s job =
  match Job.packages job with
  | []   -> build_switch s job (* FIXME: this condition is a bit weird *)
  | pkgs ->  build_pkg s job pkgs

(*
  Lwt.catch (fun () ->
      (match repos with
       | [] -> Opam.clean_repos (); Lwt.return_unit
       | _  -> Opam.add_repos repos)
      >>= fun () ->
      Opam.update () >>= fun () ->
      let c_curr = Opam.compiler () in
      let c = Job.compiler job in
      (if c = c_curr then Lwt.return_unit
       else
         Opam.export_switch c >>= fun () ->
         install_compiler worker c (Job.host job) >|= fun () ->
         debug "execute: compiler %s installed" c
      ) >>= fun () ->
      (match pins with
       | [] -> Lwt.return_unit
       | _  ->
         let build = root / Compiler.to_string c / "build" in
         Unix.mkdir build 0o775;
         Opam.add_pins pins
      ) >>= fun () ->
      let prefix = Opam.get_var "prefix" in
      debug "execute: opam load state";
      Opam.show_repo_pin () >>= fun () ->
      debug "execute: %d dependencies" (List.length deps);
      Lwt_list.iter_s (fun dep ->
          worker_request_object base worker dep >>= fun obj ->
          apply_object prefix obj
        ) deps
      >>= fun () ->
      (* FIXME: we should not have access to task here *)
      let pkgs = Task.packages (Job.task job) in
      let graph = Opam.resolve_packages pkgs in
      match Opam.is_simple graph with
      | None ->
        debug "execute: simple=false";
        let job_lst = Opam.jobs ~repos ~pins graph in
        worker_spawn base worker job_lst >|= fun () ->
        let delegate_id =
          List.fold_left (fun acc (id, job, _) ->
              let p = List.hd (Task.packages (Job.task job)) in
              if List.mem p pkgs then id :: acc else acc
            ) [] job_lst
          |> (fun id_lst -> assert (1 = List.length id_lst); List.hd id_lst)
        in
        let result = `Delegate delegate_id in
        (* FIXME: this is weird *)
        let archive = "", Cstruct.of_string "" in
        let id = Job.output job in
        let obj = Object.create ~id ~outputs:[] ~files:[] ~archive in
        switch_clean_up root c;
        result, obj
      | Some pkg ->
        debug "execute: simple=%s" (Package.to_string pkg);
        let v =
          match Package.version pkg with Some v -> v | None -> assert false
        in
        pkg_build prefix jid (Package.name pkg) v
        >|= fun (result, outputs, files, archive) ->
        (* FIXME: update job result *)
        let id = Job.output job in
        let obj = Object.create ~id ~outputs ~files ~archive in
        switch_clean_up root c;
        result, obj
    ) (fun exn ->
      let result = match exn with
        | Failure f -> `Fail f
        | _ -> `Fail "unknow execution failure" in
      (* FIXME: this is weird *)
      let archive = "", Cstruct.of_string "" in
      let id = Job.output job in
      (* FIXME: update job result *)
      let obj = Object.create ~id ~outputs:[] ~files:[] ~archive in
      switch_clean_up root (Job.compiler job);
      Lwt.return (result, obj))

let rec execution_loop base worker cond =
  Lwt_condition.wait cond >>= fun (jid, deps) ->
  local_query worker.local jid >>= fun completed ->
  if completed then execution_loop base worker cond
  else (
    worker.status <- Working jid;
    (* URGENT FIXME: we don't want to get the task here *)
    (match Task.to_compiler task with
     | None   -> pkg_job_execute base worker jid job deps
     | Some _ -> compiler_job_execute jid job)
    >>= fun (result, obj) ->
    let id = Job.output job in
    (match result with
     | `Delegate _ ->
       Store.publish_object worker.store id obj >>= fun () ->
       Store.unlog_job worker.store jid >>= fun () ->
       worker_publish base worker result jid
     | `Success ->
       Store.publish_object worker.store id obj >>= fun () ->
       Store.unlog_job worker.store jid >>= fun () ->
       Lwt.join [worker_publish base worker result jid;
                 local_publish worker.local id obj]
     | `Fail _ ->
       Store.publish_object worker.store id obj >>= fun () ->
       worker_publish base worker result jid
    ) >>= fun () ->
    worker.status <- Idle;
    execution_loop base worker cond
  )
*)

(*
let rec heartbeat_loop base worker cond =
  match worker.status with
  | Idle -> begin worker_heartbeat base worker >>= function
    | None ->
      Lwt_unix.sleep idle_sleep
      >>= fun () -> heartbeat_loop base worker cond
    | Some (id, desp) ->
      Lwt_condition.signal cond (id, desp);
      Lwt_unix.sleep idle_sleep
      >>= fun () -> heartbeat_loop base worker cond end
  | Working _ ->
    worker_heartbeat base worker >>= fun _ ->
    Lwt_unix.sleep working_sleep
    >>= fun () -> heartbeat_loop base worker cond

let run host uri =
  let worker = Worker.create host in
  Store.remote ~uri () >>= fun global ->
  local_store worker   >>= fun local  ->
  worker_register store base build_store >>= fun worker ->
  let cond = Lwt_condition.create () in
  Lwt.pick [
    heartbeat_loop base worker cond;
    execution_loop base worker cond;
  ]
*)
