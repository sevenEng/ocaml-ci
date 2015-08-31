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
include Common_worker

let debug fmt =
  section := "task-worker";
  debug fmt

type callback = t -> Task.t -> unit Lwt.t

let default_callback t task =
  let store = store t in
  let id = Task.id task in
  let o = Opam.create ~root:(opam_root t) None in
  Opam.repo_clean o;
  Opam.repo_add o (Task.repos task);
  Opam.pin_clean o;
  Opam.pin_add o (Task.pins task);
  Opam.update o;
  let jobs = Opam.jobs (opam t None) task in
  Lwt_list.iter_p (Store.Job.add store) jobs >>= fun () ->
  Store.Task.add_jobs store id (List.map Job.id jobs)

let start ?(callback=default_callback) =
  let callback t = function
    | `Idle
    | `Job _   -> Lwt.return_unit
    | `Task id ->
      debug "Got a new task: %s!" (Id.to_string id);
      let store = store t in
      let wid = Worker.id (worker t) in
      Store.Task.ack store id wid >>= fun () ->
      Store.Task.get store id >>= fun task ->
      callback t task >>= fun () ->
      Store.Task.refresh_status store id >>= fun () ->
      Store.Worker.idle store wid
  in
  start ~kind:`Task callback
