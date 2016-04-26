open Base

type word = [ `Word of Rfc5322.word ]

type received =
  [ word
  | `Domain of Address.domain
  | `Mailbox of Address.mailbox ]

type t =
  { received : (received list * Date.t option) list
  ; path     : Address.mailbox option }

let of_lexer k l =
  let received = ref [] in
  let path     = ref None in

  let sanitize fields =
    match !received, !path with
    | [], None -> k None fields
    | _ -> k (Some { received = List.rev !received
                   ; path = Option.value ~default:None !path; }) fields
  in

  let rec loop i l = match l with
    | [] -> sanitize (List.rev i)
    | x :: rest ->
      match x with
      | `Received (l, d) ->
        let l = List.map (function
                          | `Domain d  -> `Domain (Address.domain_of_lexer d)
                          | `Mailbox a -> `Mailbox (Address.mailbox_of_lexer a)
                          | #word as x -> x) l in
        let d = Option.bind Date.of_lexer d in
        received := (l, d) :: !received; loop i rest
      | `ReturnPath a ->
        (match !path with
         | None   ->
           path := Some (Option.bind Address.mailbox_of_lexer a);
           loop i rest
         | Some _ -> sanitize (List.rev (x :: i) @ l))
      | field -> loop (field :: i) rest
  in

  loop [] l

let pp fmt { received; path; } =
  let pp_field_opt fmt field_name pp_field field_opt =
    match field_opt with
    | Some field -> p fmt "%s: %a\r\n" field_name pp_field field
    | None       -> ()
  in
  let pp_elt fmt = function
    | `Domain d  -> Address.pp_domain fmt d
    | `Mailbox m -> p fmt "<%a>" Address.pp_mailbox m
    | `Word w    -> pp_word fmt w
  in
  let pp_opt_date fmt = function
    | Some date -> p fmt "; %a" Date.pp date
    | None      -> ()
  in
  let pp_received fmt (lst, date) =
    p fmt "%a%a" (pp_list ~sep:" " pp_elt) lst pp_opt_date date
  in

  pp_field_opt fmt "Return-Path" Address.pp_mailbox path;
  List.iter (p fmt "Received: %a\r\n" pp_received) received;
