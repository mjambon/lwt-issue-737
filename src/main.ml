(*
   Attempt to reproduce bug: lwt tasks inherited from parent process,
   executing in child process.
*)

open Printf
open Lwt

let print_line s =
  printf "[pid %i] %s\n%!"
    (Unix.getpid ()) s

let print_err_line s =
  eprintf "[pid %i stderr] %s\n%!"
    (Unix.getpid ()) s

let reap_child child_pid =
  Lwt_unix.waitpid [] child_pid >>= fun (_pid, _status) ->
  return ()

let print_child_logs ~child_pid log_input_fd =
  let input_channel = Lwt_io.of_unix_fd ~mode:Lwt_io.Input log_input_fd in
  let rec loop () =
    Lwt_io.read_line_opt input_channel >>= function
    | Some line ->
        if line <> "" then
          print_line (
            sprintf "child %i says: {%s}"
              child_pid line
          );
        loop ()
    | None ->
        return ()
  in
  catch loop
    (function
      | Lwt_io.Channel_closed _ -> reap_child child_pid
      | e ->
          print_err_line (
            sprintf "failed to read pipe input fd %i: %s"
              (Obj.magic (log_input_fd : Unix.file_descr) : int)
              (Printexc.to_string e)
          );
          return ()
    )

let pipe_reads = ref []

let close_pipe_reads () =
  List.iter (fun fd ->
    try Unix.close fd
    with e ->
      print_err_line (
        sprintf "failed to close pipe input fd %i: %s"
          (Obj.magic fd : int) (Printexc.to_string e)
      )
  ) !pipe_reads

external sys_exit : int -> 'a = "caml_sys_exit"

(*
   We create a child process connected to the parent via a pipe.
   The standard output of the child is redirected to the pipe.
   The parent reads from the pipe and prints these lines on stdout.

   We expect the child to only write to the pipe that we create here.
   In particular, it should not read from pipes connected to previous
   children of its parent even though it inherits them.

   Nevertheless, we observe than the child will sometimes obtain data
   printed by one of its older siblings and print it.
*)
let create_worker () =
  let lwt_log_input_fd, lwt_log_output_fd = Lwt_unix.pipe () in
  let log_input_fd = Lwt_unix.unix_file_descr lwt_log_input_fd in
  let log_output_fd = Lwt_unix.unix_file_descr lwt_log_output_fd in
  pipe_reads := log_input_fd :: !pipe_reads;
  match Lwt_unix.fork () with
  | 0 ->
      close_pipe_reads ();
      Unix.dup2 log_output_fd Unix.stdout;
      print_line "hello"; (* goes to pipe *)
      print_err_line "moo"; (* goes to terminal directly *)

      (* Bypass exit hooks which would call 'Lwt_main.run', causing
         some tasks inherited from the parent to run, such as the read loops
         created by 'print_child_logs'.

         Note that both OCaml calls relying on 'fork' such as 'Sys.command'
         and the 'Lwt_process' module ('unix_spawn') call
         'sys_exit' to bypass exit hooks. Unfortunately, 'sys_exit' isn't
         public. It's obtained with:

           external sys_exit : int -> 'a = "caml_sys_exit"

         Another way to bypass the exit hooks is to use
         'Unix.kill (Unix.getpid ()) Sys.sigkill' but it contrains the
         termination status.
      *)
      sys_exit 0

  | child_pid ->
      async (fun () ->
        print_child_logs ~child_pid log_input_fd
      )

let run num_children =
  Array.init num_children (fun _i ->
    create_worker ();
    Lwt_unix.sleep 1.
  )
  |> Array.to_list
  |> Lwt.join

let main () =
  Lwt_main.run (run 10)

let () = main ()
