open Common_types

(* object id -> task
   if task A is supposed to produce object a,
   then there is the binding a.id -> A *)
type job_tbl

(* object id -> object id
   if task A has dependencies objects b, c, d,
   and task A is supposed to produce object a,
   then there will be bindins b.id -> a.id, c.id -> a.id, d.id -> a.id,
   whenever b/c/d is published in the obj_tbl,
   a hook function will examine if task A becomes runnable *)
type hook_tbl

(* task state *)
type state = [`Pending | `Runnable | `Completed | `Dispatched of worker_token]

(* object id -> task state
   if task A is supposed to produce object a,
   then there is binding a.id -> A.state *)
type state_tbl

(******************************************************************************)

(*  finds a suitable task based on given worker token, if there is one,
    return the task id and description *)
val find_job: worker_token -> (id * compiler * description) option

(* given an object id and a worker token, add them in the logmap *)
val publish_object: worker_token -> [`Success | `Fail of string | `Delegate of id]
                    -> id -> unit Lwt.t

(* given a task id and return the pacakge name and version information *)
val task_info: ?abbr:bool -> id -> string

(* pickup any uncompleted tasks due to master failure *)
val bootstrap: unit -> unit Lwt.t

(* eliminate a worker's token when worker is down*)
val invalidate_token: worker_token -> unit

(* add new jobs into jobs/tables*)
val update_tables: (id * Task.job * id list) list -> unit Lwt.t

(* get related jobs of an id and the corresponding state *)
val progress_info: id -> string Lwt.t
(******************************************************************************)

(* given the pull request number from ocaml/opam-repository, resolve the task
   and add tasks into task table *)
val github_hook : int -> unit Lwt.t

(* given a package name with version constraint probably, resolve the task
   and add tasks into task table *)
val user_demand: pkg:string -> unit Lwt.t
