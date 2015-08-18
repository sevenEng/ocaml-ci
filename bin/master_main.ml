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

open Cmdliner

let ip =
  Arg.(value & opt string "127.0.0.1" & info ["ip"]
         ~doc:"the ip address of the master")

let port =
  Arg.(value & opt int 8080 & info ["port"]
         ~doc:"the port number of the master")

let fresh =
  Arg.(value & flag & info ["fresh"; "f"]
         ~doc:"start with a fresh new store")

let uri =
  Arg.(required & pos 0 (some string) None & info []
         ~doc:"the address to contact the data store" ~docv:"URI")

let () =
  let master fresh uri ip port =
    Lwt_main.run (Master.run ~fresh ~uri ~ip ~port)
  in
  let term =
    Term.(pure master $ fresh $ uri $ ip $ port,
          info ~doc:"start the master" "ciso-master")
  in
  match Term.eval term with `Error _ -> exit 1 | _ -> exit 0
