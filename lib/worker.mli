open Common_types
type t
type store

(** [worker_register master_uri build_store]:
    when started, register itself, when get the id from master,
    build a local store based on the id by build_store *)
val worker_register: Uri.t -> switch:string -> (string -> store Lwt.t) ->
                     t Lwt.t

(** [worker_heartbeat master_uri worker]:
    sends heartbeat to master, the heartbeat contains the worker status: work
    or idle, if idle and the master has assigned a new task A to it,
    the task A produces object a, the function returns a thread holds
    Some (A.id, a.id) *)
val worker_heartbeat: Uri.t -> t -> (id * description) option Lwt.t

(** [worker_publish master_uri worker object]:
    if produces a new object or get a copy from other workers,
    publish it to master in the object tables *)
val worker_publish: Uri.t -> t -> [`Success | `Fail of string | `Delegate of id]
                    -> id -> Object.t -> unit Lwt.t

(** [worker_spawn master_uri worker job_lst]:
    when a job fetched can be resolved,
    worker post the resolved jobs to master *)
val worker_spawn: Uri.t -> t -> (id * Task.job * (id list)) list -> unit Lwt.t

(** [worker_request_object master_uri worker obj_id]:
    before task execution, the worker will gather all the dependencies by this
    function. If the object of obj_id isn't found locally,
    the worker will consult master about the location of the object,
    retrieve it from other workers, save it locally,
    publish it to master that a copy of this object has been made,
    then return the thread *)
val worker_request_object: Uri.t -> t -> id -> Object.t Lwt.t


(******************************************************************************)

(** [execution_loop master_uri worker receive]:
    infinite loop to execute tasks,
    call [receive] to get job id and description from heartbeat process *)
val execution_loop: Uri.t -> t
                    -> (unit -> (id * description) Lwt.t)
                    -> (id -> unit)
                    ->'a Lwt.t

(** [heartbeat_loop master_uri worker send]:
    infinite loop to send out heartbeats to master,
    under the idle state, if gets the response of Some (task_id, obj_id),
    call [send] to send information to execution process *)
val heartbeat_loop: Uri.t -> t
                    -> (unit -> id option Lwt.t)
                    -> (id * description -> unit)
                    -> 'a Lwt.t
