(*
   Attempt to reproduce bug: lwt tasks inherited by parent process,
   executing in child process.
*)

open Printf
open Lwt

let print_line s =
  printf "[%i] %s\n%!" (Unix.getpid ()) s

let reap_child child_pid =
  Lwt_unix.waitpid [] child_pid >>= fun (_pid, _status) ->
  return ()

let print_child_logs ~child_pid lwt_log_input_fd =
  let input_channel = Lwt_io.of_unix_fd ~mode:Lwt_io.Input lwt_log_input_fd in
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
      | e -> raise e (* and die *)
    )

let create_worker () =
  let lwt_log_input_fd, lwt_log_output_fd = Lwt_unix.pipe () in
  let log_input_fd = Lwt_unix.unix_file_descr lwt_log_input_fd in
  let log_output_fd = Lwt_unix.unix_file_descr lwt_log_output_fd in
  match Lwt_unix.fork () with
  | 0 ->
      Unix.close log_input_fd;
      Unix.dup2 log_output_fd Unix.stdout;
      Unix.dup2 log_output_fd Unix.stderr;
      print_line "hello";
      exit 0
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
