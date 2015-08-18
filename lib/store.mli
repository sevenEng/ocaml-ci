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

(* FIXME: doc *)

open Common_types

type t

(* FIXME: why do we need tokens? *)
type token with sexp
val string_of_token: token -> string
val token_of_string: string -> token
val create_token: string -> token

val create: ?uri:string -> ?fresh:bool -> unit -> t Lwt.t

val register_token: t -> token -> unit Lwt.t

val invalidate_token: t -> token -> unit Lwt.t

val query_object: t -> id -> bool Lwt.t

val publish_object: t -> token -> id -> Object.t -> unit Lwt.t

val retrieve_object: t -> id -> Object.t Lwt.t

val log_job: t -> id -> Job.t * (id list) -> unit Lwt.t

val unlog_job: t -> id -> unit Lwt.t

val retrieve_jobs: t -> (id * Job.t * (id list)) list Lwt.t

val retrieve_job: t -> id -> (Job.t * (id list)) Lwt.t

val query_compiler: t -> id -> bool Lwt.t

val publish_compiler: t -> token -> id -> Object.t -> unit Lwt.t

val retrieve_compiler: t -> id -> Object.t Lwt.t
