(*
   Attempt to reproduce bug: lwt tasks inherited by parent process,
   executing in child process.
*)

open Printf
open Lwt

type item = string

let print_line s =
  printf "[%i] %s\n%!" (Unix.getpid ()) s

let run_child_job post_item =
  Unix.sleepf 0.1;
  (* log something *)
  print_line "hello";
  (* post a stream of results *)
  post_item (Some "item1");
  post_item (Some "item2");
  post_item None

let reap_child child_pid =
  Lwt_unix.waitpid [] child_pid >>= fun (_pid, _status) ->
  return ()

let print_child_logs ~child_pid lwt_log_input_fd =
  let input_channel = Lwt_io.of_unix_fd ~mode:Lwt_io.Input lwt_log_input_fd in
  let rec loop () =
    Lwt_io.read_line_opt input_channel >>= function
    | Some line ->
        if line <> "" then
          print_line (sprintf "child %i says: %s" child_pid line);
        loop ()
    | None ->
        return ()
  in
  catch loop
    (function
      | Lwt_io.Channel_closed _ -> reap_child child_pid
      | e -> raise e (* and die *)
    )

(*
   Post an item from the child to the parent via a pipe.
*)
let make_post_item output_fd =
  let output_channel = Unix.out_channel_of_descr output_fd in
  fun opt_item ->
    Marshal.to_channel output_channel
      (opt_item : item option) [Marshal.Closures];
    flush output_channel

(*
   Create a stream to read items posted by the child via a pipe.
*)
let make_item_stream input_fd =
  let input_channel = Lwt_io.of_unix_fd ~mode:Lwt_io.Input input_fd in
  let read_item () =
    (Lwt_io.read_value input_channel : item option Lwt.t)
  in
  Lwt_stream.from read_item

let create_worker job =
  let lwt_input_fd, lwt_output_fd = Lwt_unix.pipe () in
  let input_fd = Lwt_unix.unix_file_descr lwt_input_fd in
  let output_fd = Lwt_unix.unix_file_descr lwt_output_fd in
  let lwt_log_input_fd, lwt_log_output_fd = Lwt_unix.pipe () in
  let log_input_fd = Lwt_unix.unix_file_descr lwt_log_input_fd in
  let log_output_fd = Lwt_unix.unix_file_descr lwt_log_output_fd in
  match Lwt_unix.fork () with
  | 0 ->
      Unix.close log_input_fd;
      Unix.dup2 log_output_fd Unix.stdout;
      Unix.dup2 log_output_fd Unix.stderr;
      job (make_post_item output_fd);
      exit 0
  | child_pid ->
      Lwt_unix.close lwt_output_fd >>= fun () ->
      let logger = print_child_logs ~child_pid log_input_fd in
      async (fun () -> logger);
      return (child_pid, make_item_stream input_fd)

let consume_results child_pid item_stream =
  Lwt_stream.iter (fun item ->
    print_line (sprintf "child %i posted item %S" child_pid item)
  ) item_stream

let run num_children =
  Array.init num_children (fun _i ->
    create_worker run_child_job >>= fun (child_pid, item_stream) ->
    consume_results child_pid item_stream
  )
  |> Array.to_list
  |> Lwt.join

let main () =
  Lwt_main.run (run 4)

let () = main ()
