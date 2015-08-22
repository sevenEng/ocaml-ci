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

type t = {
  name: string;
  version: string option;
}

let equal x y =
  String.compare x.name y.name = 0
  && match x.version, y.version with
  | None  , None   -> true
  | Some x, Some y -> String.compare x y = 0
  | _ -> false

let pp ppf t =
  Fmt.(pf ppf
    "@[<v>\
     name:    %s@;\
     version: %a@]"
    t.name (option string) t.version)

let json =
  let o = Jsont.objc ~kind:"package" () in
  let name = Jsont.(mem o "name" string) in
  let version = Jsont.(mem_opt o "version" string) in
  let c = Jsont.obj ~seal:true o in
  let dec o = `Ok { name = Jsont.get name o; version = Jsont.get version o } in
  let enc t = Jsont.(new_obj c [memv name t.name; memv version t.version]) in
  Jsont.view (dec, enc) c

let name t = t.name
let version t = t.version
let create ?version name = { name; version }

let of_string s = match Stringext.cut s ~on:"." with
  | None        -> create s
  | Some (n, v) -> create ~version:v n

let to_string t = match t.version with
  | None   -> t.name
  | Some v -> t.name ^ "." ^ v

type info = {
  opam: Cstruct.t;
  url : Cstruct.t;
}

let pp_info ppf i =
  (* FIXME: to_string *)
  Fmt.pf ppf "@[<v>%s@;%s@]" (Cstruct.to_string i.opam) (Cstruct.to_string i.url)

let json_cstruct =
  let dec o = `Ok (Cstruct.of_string o) in
  let enc c = Cstruct.to_string c in
  Jsont.view (dec, enc) Jsont.nat_string

let json_info =
  let o = Jsont.objc ~kind:"package" () in
  let opam = Jsont.(mem o "opam" json_cstruct) in
  let url = Jsont.(mem ~opt:`Yes_rem o "url" json_cstruct) in
  let c = Jsont.obj ~seal:true o in
  let dec o = `Ok { opam = Jsont.get opam o; url = Jsont.get url o } in
  let enc t = Jsont.(new_obj c [memv opam t.opam; memv url t.url]) in
  Jsont.view (dec, enc) c

let info ~opam ~url = { opam; url }
let opam i = i.opam
let url i = i.opam
