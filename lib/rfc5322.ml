open Rfc822

type month =
  [ `Jan | `Feb | `Mar | `Apr
  | `May | `Jun | `Jul | `Aug
  | `Sep | `Oct | `Nov | `Dec ]

type day =
  [ `Mon | `Tue | `Wed | `Thu
  | `Fri | `Sat | `Sun ]

type tz =
  [ `TZ of int
  | `UT
  | `GMT | `EST | `EDT | `CST | `CDT
  | `MST | `MDT | `PST | `PDT
  | `Military_zone of char ]

type date      = int * month * int
type time      = int * int * int option
type date_time = day option * date * time * tz

type atom    = [ `Atom of string ]
type word    = [ atom | `String of string ]
type phrase  = [ word | `Dot | `WSP | Rfc2047.encoded ] list

type domain =
  [ `Literal of string
  | `Domain of atom list ]

type local   = word list
type mailbox = local * domain list
type person  = phrase option * mailbox
type group   = phrase * person list
type address = [ `Group of group | `Person of person ]

type left   = local
type right  = domain
type msg_id = left * right

type received =
  [ `Domain of domain
  | `Mailbox of mailbox
  | `Word of word ]

type field =
  [ `From            of person list
  | `Date            of date_time
  | `Sender          of person
  | `ReplyTo         of address list
  | `To              of address list
  | `Cc              of address list
  | `Bcc             of address list
  | `Subject         of phrase
  | `Comments        of phrase
  | `Keywords        of phrase list
  | `MessageID       of msg_id
  | `InReplyTo       of [`Phrase of phrase | `MsgID of msg_id] list
  | `References      of [`Phrase of phrase | `MsgID of msg_id] list
  | `ResentDate      of date_time
  | `ResentFrom      of person list
  | `ResentSender    of person
  | `ResentTo        of address list
  | `ResentCc        of address list
  | `ResentBcc       of address list
  | `ResentMessageID of msg_id
  | `Received        of received list * date_time option
  | `ReturnPath      of mailbox option
  | `ContentType     of Rfc2045.content
  | `MIMEVersion     of Rfc2045.version
  | `ContentEncoding of Rfc2045.encoding
  | `Field           of string * phrase ]

let cur_chr ?(avoid = []) state =
  while List.exists ((=) (Lexer.cur_chr state)) avoid
  do state.Lexer.pos <- state.Lexer.pos + 1 done;

  Lexer.cur_chr state

(* See RFC 5234 § Appendix B.1:

   VCHAR           = %x21-7E              ; visible (printing) characters
*)
let is_vchar = is_vchar

let s_vchar =
  let make a b incr =
    let rec aux acc i =
      if i > b then List.rev acc
      else aux (incr i :: acc) (incr i)
    in
    aux [a] a
  in

  make 0x21 0x7e ((+) 1) |> List.map Char.chr

(* See RFC 5234 § Appendix B.1:

   SP              = %x20
   HTAB            = %x09                 ; horizontal tab
   WSP             = SP / HTAB            ; white space
*)
let s_wsp  = ['\x20'; '\x09']

(* See RFC 5322 § 3.2.3:

   atext           = ALPHA / DIGIT /      ; Printable US-ASCII
                     "!" / "#" /          ;  characters not including
                     "$" / "%" /          ;  specials. Used for atoms.
                     "&" / "'" /
                     "*" / "+" /
                     "-" / "/" /
                     "=" / "?" /
                     "^" / "_" /
                     "`" / "{" /
                     "|" / "}" /
                     "~"
*)
let is_valid_atext text =
  let i = ref 0 in

  while !i < String.length text
        && is_atext (String.get text !i)
  do incr i done;

  if !i = String.length text
  then true
  else false

(* See RFC 5322 § 3.2.3:

   specials        = %x28 / %x29 /        ; Special characters that do
                     "<"  / ">"  /        ;  not appear in atext
                     "["  / "]"  /
                     ":"  / ";"  /
                     "@"  / %x5C /
                     ","  / "."  /
                     DQUOTE

   See RFC 5234 § Appendix B.1:

   DQUOTE          = %x22
                                          ; (Double Quote)
*)
let is_specials = function
  | '(' | ')'
  | '<' | '>'
  | '[' | ']'
  | ':' | ';'
  | '@' | '\\'
  | ',' | '.'
  | '"' -> true
  | chr -> false

(* See RFC 5322 § 3.6.4:

   msg-id          = [CFWS] "<" id-left "@" id-right ">" [CFWS]
*)
let p_msg_id = p_msg_id

(* See RFC 5322 § 3.2.5 & 4.1:

   phrase          = 1*word / obs-phrase
   obs-phrase      = word *(word / "." / CFWS)
*)
let p_phrase p state =
  (Logs.debug @@ fun m -> m "state: p_phrase");

  let add_fws has_fws element words =
    if has_fws
    then element :: `WSP :: words
    else element :: words
  in

  (* XXX: remove unused FWS, if we don't remove that, the pretty-printer raise
          an error. May be, we fix that in the pretty-printer but I decide to
          fix that in this place. *)
  let rec trim = function
    | `WSP :: r -> trim r
    | r -> r
  in

  let rec obs words state =
    (Logs.debug @@ fun m -> m "state: p_phrase/obs");

    p_cfws (fun has_fws state -> match cur_chr state with
            | '.' ->
              Lexer.junk_chr state; obs (add_fws has_fws `Dot words) state
            | chr when is_atext chr || is_dquote chr ->
              Rfc2047.p_try_rule
                (fun word -> obs (add_fws has_fws word words))
                p_word
                state
              (* XXX: without RFC 2047
                 p_word (fun word -> obs (add_fws has_fws word words)) state *)
            | _ -> p (trim @@ List.rev @@ trim words) state)
      state
  in

  let rec loop words state =
    (Logs.debug @@ fun m -> m "state: p_phrase/loop");

    (* XXX: we catch [p_word] (with its [CFWS] in [p_atom]/[p_quoted_string])
            to determine if we need to switch to [obs] (if we have a '.'),
            or to continue [p_word] *)
    p_cfws (fun has_fws state -> match cur_chr state with
            | chr when is_atext chr || is_dquote chr ->
              Rfc2047.p_try_rule
                (fun word -> loop (add_fws true word words))
                p_word
                state
              (* XXX: without RFC 2047
                 p_word (fun word -> loop (add_fws true word words)) state *)
            | _ -> obs (if has_fws then `WSP :: words else words) state)
            (* XXX: may be it's '.', so we try to switch to obs *)
      state
  in

  p_fws (fun _ _ ->
         Rfc2047.p_try_rule
           (fun word -> loop [word])
           p_word) state

(* See RFC 5322 § 4.1:

   obs-utext       = %d0 / obs-NO-WS-CTL / VCHAR
*)
let is_obs_utext = function
  | '\000' -> true
  | chr -> is_obs_no_ws_ctl chr || is_vchar chr

(* XXX: bon là, j'écris en français parce que c'est vraiment de la merde. En
        gros le [obs-unstruct] ou le [unstructured], c'est de la grosse merde
        pour 3 points:

        * le premier, c'est que depuis la RFC 2047, on peut mettre DES
          [encoded-word] dans un [obs-unstruct] ou un [unstructured]. Il faut
          donc decoder ces fragments premièrement. MAIS il faut bien comprendre
          qu'un (ou plusieurs) espace entre 2 [encoded-word] n'a aucune
          signication - en gros avec: '=utf-8?Q?a=    =utf-8?Q?b=', on obtient
          'ab'. SAUF que dans le cas d'un [encoded-word 1*FWS 1*obs-utext]
          l'espace est significatif et ça moment là, tu te dis WTF! Bien
          entendu, les espaces entre deux [1*obs-utext] est tout autant
          signicatif. DONC OUI C'EST DE LA MERDE.

        * MAIS C'EST PAS FINI! Si on regarde bien la règle, cette pute, elle se
          termine pas. OUAIS OUAIS! En vrai, elle se termine après avoir essayer
          le token [FWS], après avoir essayer [*LF] et [*CR], qu'il y est au
          moins un des deux derniers token existant (donc soit 1*LF ou 1*CR) et
          qu'après avoir essayer à nouveau un [FWS] si on a pas de [obs-utext],
          on regarde si on a bien eu un token [FWS] (d'où la nécessité d'avoir
          [has_wsp] et [has_fws] dans la fonction [p_fws]). DONC (OUAIS C'EST LA
          MERDE), si on a bien un token [FWS], on recommence, SINON on termine.

        * ENFIN LE PIRE HEIN PARCE QUE ENCORE C'EST GENTIL! Comme on ESSAYE
          d'avoir un CR* à la fin, IL PEUT ARRIVER (j'ai bien dit il peut mais
          en vrai ça arrive tout le temps) qu'on consomme le CR du token CRLF
          OBLIGATOIRE à chaque ligne. DONC la fonction compile si tu termines
          par un CR ET SI C'EST LE CAS ON ROLLBACK pour récupérer le CR
          OBLIGATOIRE à la fin de ligne.

        DONC CETTE REGLE, C'EST CARREMENT DE LA MERDE ET VOILA POURQUOI CETTE
        FONCTION EST AUSSI COMPLEXE. Merci de votre attention.
*)
let p_obs_unstruct ?(acc = []) p state =
  let compile rlst state =
    let rec aux ?(previous = `None) acc l = match l, previous with
      | (`Encoded _ as enc) :: r, `LWSP ->
        aux ~previous:`Enc (enc :: `WSP :: acc) r
      | (`Encoded _ as enc) :: r, (`ELWSP | `None) ->
        aux ~previous:`Enc (enc :: acc) r
      | `Encoded _ :: r, (`Atom | `Enc)
      | `Atom _ :: r, `Enc ->
        assert false (* XXX: raise error *)
      | (`Atom _ as txt) :: r, (`LWSP | `ELWSP) ->
        aux ~previous:`Atom (txt :: `WSP :: acc) r
      | (`Atom s as txt) :: r, (`None | `Atom) ->
        aux ~previous:`Atom (txt :: acc) r
      | (`LF | `CR | `WSP | `FWS) :: r1 :: r2, (`ELWSP | `Enc) ->
        aux ~previous:`ELWSP acc (r1 :: r2)
      | (`LF | `CR | `WSP | `FWS) :: r1 :: r2, (`LWSP | `Atom) ->
        aux ~previous:`LWSP acc (r1 :: r2)
      | (`LF | `CR | `WSP | `FWS) :: r1 :: r2, `None ->
        aux ~previous:`None acc (r1 :: r2)
      | [ `CR ], _ ->
        Lexer.roll_back (fun state -> p (List.rev acc) state) "\r" state
      | [ (`LF | `WSP | `FWS) ], _ | [], _ ->
        p (List.rev acc) state
    in

    aux [] (List.rev rlst)
  in

  let rec data acc =
    Lexer.p_try_rule
      (fun (charset, encoding, s) state ->
       let lf = Lexer.p_repeat is_lf state in
       let cr = Lexer.p_repeat is_cr state in

       let acc' =
         match String.length lf, String.length cr with
         | 0, 0 -> `Encoded (charset, encoding, s) :: acc
         | n, 0 -> `Encoded (charset, encoding, s) :: `LF :: acc
         | 0, n -> `Encoded (charset, encoding, s) :: `CR :: acc
         | _    -> `Encoded (charset, encoding, s) :: `CR :: `LF :: acc
       in

       match cur_chr state with
       | chr when is_obs_utext chr -> data acc' state
       | chr -> loop acc' state)
      (fun state ->
       let ts = Lexer.p_while is_obs_utext state in
       let lf = Lexer.p_repeat is_lf state in
       let cr = Lexer.p_repeat is_cr state in

       let acc' =
         match String.length lf, String.length cr with
         | 0, 0 -> `Atom ts :: acc
         | n, 0 -> `Atom ts :: `LF :: acc
         | 0, n -> `Atom ts :: `CR :: acc
         | _    -> `Atom ts :: `CR :: `LF :: acc
       in

       match cur_chr state with
       | chr when is_obs_utext chr -> data acc' state
       | chr -> loop acc' state)
      (Rfc2047.p_encoded_word
         (fun charset encoding s state -> `Ok ((charset, encoding, s), state)))

  and lfcr acc state =
    let lf = Lexer.p_repeat is_lf state in
    let cr = Lexer.p_repeat is_cr state in

    let acc' = match String.length lf, String.length cr with
      | 0, 0 -> acc
      | n, 0 -> `LF :: acc
      | 0, n -> `CR :: acc
      | _    -> `CR :: `LF :: acc
    in

    match cur_chr state with
    | chr when is_obs_utext chr -> data acc state
    | chr when String.length lf > 0 || String.length cr > 0 ->
      p_fws (fun has_wsp has_fws ->
             match has_wsp, has_fws with
             | true, true   -> lfcr (`FWS :: acc')
             | true, false  -> lfcr (`WSP :: acc')
             | false, false -> compile acc'
             | _            -> assert false)
        state
    | _ -> compile acc' state

  and loop acc =
    p_fws (fun has_wsp has_fws ->
      match has_wsp, has_fws with
      | true, true   -> loop (`FWS :: acc)
      | true, false  -> loop (`WSP :: acc)
      | false, false -> lfcr acc
      | false, true  -> assert false)
  in

  loop acc state

let p_unstructured p state =
  let rec loop acc has_wsp has_fws state =
    match has_wsp, has_fws, Lexer.cur_chr state with
    | has_wsp, has_fws, chr when is_vchar chr ->
      let adder x =
        if has_fws && has_wsp
        then x :: `FWS :: acc
        else if has_wsp
        then x :: `WSP :: acc
        else x :: acc
      in
      Lexer.p_try_rule
        (fun (charset, encoding, s) ->
         p_fws (loop (adder (`Encoded (charset, encoding, s)))))
        (fun state ->
         let s = Lexer.p_while is_vchar state in
         p_fws (loop (adder (`Atom s))) state)
        (Rfc2047.p_encoded_word (fun charset encoding s state -> `Ok ((charset, encoding, s), state)))
        state
    | true, true, _   -> p_obs_unstruct ~acc:(`FWS :: acc) p state
    | true, false, _  -> p_obs_unstruct ~acc:(`WSP :: acc) p state
    | false, false, _ -> p_obs_unstruct ~acc p state
    | false, true, _  -> assert false
  in

  p_fws (loop []) state


(* [CFWS] 2DIGIT [CFWS] *)
let p_cfws_2digit_cfws p state =
  (Logs.debug @@ fun m -> m "state: p_cfws_2digit_cfws");

  p_cfws (fun _ state -> let n = Lexer.p_repeat ~a:2 ~b:2 is_digit state in
                       p_cfws (p (int_of_string n)) state) state
(* See RFC 5322 § 4.3:

   obs-hour        = [CFWS] 2DIGIT [CFWS]
   obs-minute      = [CFWS] 2DIGIT [CFWS]
   obs-second      = [CFWS] 2DIGIT [CFWS]
*)
let p_obs_hour p state =
  (Logs.debug @@ fun m -> m "state: p_obs_hour");
  p_cfws_2digit_cfws (fun n _ -> p n) state

let p_obs_minute p state =
  (Logs.debug @@ fun m -> m "state: p_obs_minute");
  p_cfws_2digit_cfws (fun n _ -> p n) state

let p_obs_second p state =
  (Logs.debug @@ fun m -> m "state: p_obs_second");
  p_cfws_2digit_cfws p state

(* See RFC 5322 § 3.3:

   hour            = 2DIGIT / obs-hour
   minute          = 2DIGIT / obs-minute
   second          = 2DIGIT / obs-second
*)
let p_2digit_or_obs p state =
  (Logs.debug @@ fun m -> m "state: p_2digit_or_obs");

  if Lexer.p_try is_digit state = 2
  then let n = Lexer.p_while is_digit state in
       p_cfws (p (int_of_string n)) state
       (* XXX: in this case, it's possible to
               be in [obs] version, so we try
               [CFWS] *)
  else p_cfws_2digit_cfws p state

let p_hour p state =
  (Logs.debug @@ fun m -> m "state: p_hour");
  p_2digit_or_obs (fun n _ -> p n) state

let p_minute p state =
  (Logs.debug @@ fun m -> m "state: p_minute");
  p_2digit_or_obs p state

let p_second p state =
  (Logs.debug @@ fun m -> m "state: p_second");
  p_2digit_or_obs p state

(* See RFC 5322 § 3.3 & 4.3:

   year            = (FWS 4*DIGIT FWS) / obs-year
   obs-year        = [CFWS] 2*DIGIT [CFWS]
*)
let p_obs_year p state =
  (* [CFWS] 2*DIGIT [CFWS] *)
  p_cfws (fun _ state -> let y = Lexer.p_repeat ~a:2 is_digit state in
                         p_cfws (fun _ -> p (int_of_string y)) state) state

let p_year has_already_fws p state =
  (Logs.debug @@ fun m -> m "state: p_year");

  (* (FWS 4*DIGIT FWS) / obs-year *)
  p_fws (fun has_wsp has_fws state ->
    if (has_wsp || has_fws || has_already_fws) && Lexer.p_try is_digit state >= 4
    then let y = Lexer.p_while is_digit state in
         p_fws (fun has_wsp has_fws state ->
                if has_wsp || has_fws
                then p (int_of_string y) state
                else raise (Lexer.Error (Lexer.err_expected ' ' state))) state
    else p_obs_year p state)
  state

(* See RFC 5322 § 3.3 & 4.3:

   day             = ([FWS] 1*2DIGIT FWS) / obs-day
   obs-day         = [CFWS] 1*2DIGIT [CFWS]
*)
let p_obs_day p state =
  (Logs.debug @@ fun m -> m "state: p_obs_day");

  p_cfws (fun _ state -> let d = Lexer.p_repeat ~a:1 ~b:2 is_digit state in
                         p_cfws (fun _ -> p (int_of_string d)) state)
    state

let p_day p state =
  (Logs.debug @@ fun m -> m "state: p_day");

  p_fws (fun _ _ state ->
         if is_digit @@ cur_chr state
         then let d = Lexer.p_repeat ~a:1 ~b:2 is_digit state in
              p_fws (fun has_wsp has_fws ->

                     if has_wsp || has_fws
                     then p (int_of_string d)
                     else raise (Lexer.Error (Lexer.err_expected ' ' state)))
                state
         else p_obs_day p state)
    state

(* See RFC 5322 § 3.3:

   month           = "Jan" / "Feb" / "Mar" / "Apr" /
                     "May" / "Jun" / "Jul" / "Aug" /
                     "Sep" / "Oct" / "Nov" / "Dec"
*)
let p_month p state =
  (Logs.debug @@ fun m -> m "state: p_month");

  let month = Lexer.p_repeat ~a:3 ~b:3 is_alpha state in

  let month = match month with
  | "Jan" -> `Jan
  | "Feb" -> `Feb
  | "Mar" -> `Mar
  | "Apr" -> `Apr
  | "May" -> `May
  | "Jun" -> `Jun
  | "Jul" -> `Jul
  | "Aug" -> `Aug
  | "Sep" -> `Sep
  | "Oct" -> `Oct
  | "Nov" -> `Nov
  | "Dec" -> `Dec
  | str   -> raise (Lexer.Error (Lexer.err_unexpected_str str state)) in

  p month state

(* See RFC 5322 § 3.3:

   day-name        = "Mon" / "Tue" / "Wed" / "Thu" /
                     "Fri" / "Sat" / "Sun"
*)
let p_day_name p state =
  (Logs.debug @@ fun m -> m "state: p_day_name");

  let day = Lexer.p_repeat ~a:3 ~b:3 is_alpha state in

  let day = match day with
  | "Mon" -> `Mon
  | "Tue" -> `Tue
  | "Wed" -> `Wed
  | "Thu" -> `Thu
  | "Fri" -> `Fri
  | "Sat" -> `Sat
  | "Sun" -> `Sun
  | str   -> raise (Lexer.Error (Lexer.err_unexpected_str str state)) in

  p day state

(* See RFC 5322 § 3.3 & 4.3:

   day-of-week     = ([FWS] day-name) / obs-day-of-week
   obs-day-of-week = [CFWS] day-name [CFWS]
*)
let p_day_of_week p =
  (Logs.debug @@ fun m -> m "state: p_day_of_week");

  p_fws
  @@ fun _ _ state ->
     if is_alpha (cur_chr state) then p_day_name p state
     else p_cfws (fun _ -> p_day_name (fun day -> p_cfws (fun _ -> p day)))
            state

(* See RFC 5322 § 3.3;

   date            = day month year
*)
let p_date p =
  (Logs.debug @@ fun m -> m "state: p_date");

  p_day (fun d -> p_month (fun m -> p_year false (fun y -> p (d, m, y))))

(* See RFC 5322 § 3.3:

   time-of-day     = hour ":" minute [ ":" second ]
*)
let p_time_of_day p =
  p_hour
  @@ (fun hh state ->
      Lexer.p_chr ':' state;
      p_minute
      (fun mm has_fws state -> match cur_chr state with
       | ':' -> Lexer.p_chr ':' state;
                p_second (fun ss has_fws -> p has_fws (hh, mm, Some ss)) state
       | chr -> p has_fws (hh, mm, None) state)
      state)

(* See RFC 5322 § 3.3:

   obs-zone        = "UT" / "GMT" /     ; Universal Time
                                        ; North American UT
                                        ; offsets
                     "EST" / "EDT" /    ; Eastern:  - 5/ - 4
                     "CST" / "CDT" /    ; Central:  - 6/ - 5
                     "MST" / "MDT" /    ; Mountain: - 7/ - 6
                     "PST" / "PDT" /    ; Pacific:  - 8/ - 7
                     %d65-73 /          ; Military zones - "A"
                     %d75-90 /          ; through "I" and "K"
                     %d97-105 /         ; through "Z", both
                     %d107-122          ; upper and lower case
*)
let p_obs_zone p state =
  let k x = p x state in
  match cur_chr state with
  | '\065' .. '\073' ->
    let a = cur_chr state in
    Lexer.junk_chr state;

    if a = 'G' || a = 'E' || a = 'C'
       && (cur_chr state = 'M' || cur_chr state = 'S' || cur_chr state = 'D')
    then let next = Lexer.p_repeat ~a:2 ~b:2 is_alpha state in
         match a, next with
         | 'G', "MT" -> k `GMT
         | 'E', "ST" -> k `EST
         | 'E', "DT" -> k `EDT
         | 'C', "ST" -> k `CST
         | 'C', "DT" -> k `CDT
         | chr, str ->
           let str = String.make 1 chr ^ str in
           raise (Lexer.Error (Lexer.err_unexpected_str str state))
    else k (`Military_zone a)
  | '\075' .. '\090' ->
    let a = cur_chr state in
    Lexer.junk_chr state;

    if a = 'U' && (cur_chr state = 'T')
    then (Lexer.p_chr 'T' state; k `UT)
    else if a = 'M' || a = 'P'
            && (cur_chr state = 'S' || cur_chr state = 'D')
    then let next = Lexer.p_repeat ~a:2 ~b:2 is_alpha state in
         match a, next with
         | 'M', "ST" -> k `MST (* maladie sexuellement transmissible *)
         | 'M', "DT" -> k `MDT
         | 'P', "ST" -> k `PST
         | 'P', "DT" -> k `PDT
         | chr, str ->
           let str = String.make 1 chr ^ str in
           raise (Lexer.Error (Lexer.err_unexpected_str str state))
    else k (`Military_zone a)
  | '\097' .. '\105' as a -> Lexer.junk_chr state; k (`Military_zone a)
  | '\107' .. '\122' as a -> Lexer.junk_chr state; k (`Military_zone a)
  | chr -> raise (Lexer.Error (Lexer.err_unexpected chr state))

(* See RFC 5322 § 3.3:

   zone            = (FWS ( "+" / "-" ) 4DIGIT) / obs-zone
*)
let p_zone has_already_fws p state =
  (Logs.debug @@ fun m -> m "state: p_zone %b" has_already_fws);

  p_fws (fun has_wsp has_fws state ->
         match has_already_fws || has_wsp || has_fws, cur_chr state with
         | true, '+' ->
           Lexer.p_chr '+' state;
           let tz = Lexer.p_repeat ~a:4 ~b:4 is_digit state in
           p (`TZ (int_of_string tz)) state
         | true, '-' ->
           Lexer.p_chr '-' state;
           let tz = Lexer.p_repeat ~a:4 ~b:4 is_digit state in
           p (`TZ (- (int_of_string tz))) state
         | true, chr when is_digit chr ->
           let tz = Lexer.p_repeat ~a:4 ~b:4 is_digit state in
           p (`TZ (int_of_string tz)) state
         | _ -> p_obs_zone p state)
    state

(* See RFC 5322 § 3.3:

   time            = time-of-day zone
*)
let p_time p state =
  (Logs.debug @@ fun m -> m "state: p_time");

  p_time_of_day
    (fun has_fws (hh, mm, dd) ->
     p_zone has_fws (fun tz -> p ((hh, mm, dd), tz)))
    state

(* See RFC 5322 § 3.3:

   date-time       = [ day-of-week "," ] date time [CFWS]
*)
let p_date_time p state =
  (Logs.debug @@ fun m -> m "state: p_date_time");

  let aux ?day state =
    (Logs.debug @@ fun m -> m "state: p_date_time/aux");

    p_date
      (fun (d, m, y) ->
       p_time (fun ((hh, mm, ss), tz) ->
               p_cfws (fun _ ->
                       (Logs.debug @@ fun m -> m "state: p_date_time/end");
                       p (day, (d, m, y), (hh, mm, ss), tz))))
    state
  in

  p_fws (fun _ _ state ->
         if is_alpha @@ cur_chr state
         then p_day_of_week
                (fun day state ->
                 Lexer.p_chr ',' state;
                 aux ~day state) state
         else aux state)
    state

(* See RFC 5322 § 3.4.1 & 4.4:

   dtext           = %d33-90 /            ; Printable US-ASCII
                     %d94-126 /           ;  characters not including
                     obs-dtext            ;  "[", "]", or %x5C
   obs-dtext       = obs-NO-WS-CTL / quoted-pair
*)
let is_dtext = function
  | '\033' .. '\090'
  | '\094' .. '\126' -> true
  | chr -> is_obs_no_ws_ctl chr

let p_dtext p state =
  let rec loop acc state =
    match cur_chr state with
    | '\033' .. '\090'
    | '\094' .. '\126' ->
      let s = Lexer.p_while is_dtext state in
      loop (s :: acc) state
    | chr when is_obs_no_ws_ctl chr ->
      let s = Lexer.p_while is_dtext state in
      loop (s :: acc) state
    | '\\' ->
      p_quoted_pair
        (fun chr state -> loop (String.make 1 chr :: acc) state) state
    | chr -> p (List.rev acc |> String.concat "") state
  in

  loop [] state

(* See RFC 5322 § 4.4:

   obs-domain      = atom *("." atom)
*)
let p_obs_domain p =
  let rec loop acc state =
    match cur_chr state with
    | '.' -> Lexer.junk_chr state; p_atom (fun o -> loop (`Atom o :: acc)) state
    | chr -> p (List.rev acc) state
  in

  p_atom (fun first -> loop [`Atom first])

(* See RFC 5322 § 4.4:

   obs-group-list  = 1*([CFWS] ",") [CFWS]
*)
let p_obs_group_list p state =
  let rec loop state =
    match cur_chr state with
    | ',' -> Lexer.junk_chr state; p_cfws (fun _ -> loop) state
    | chr -> p_cfws (fun _ -> p) state
  in

  p_cfws (fun _ state -> match cur_chr state with
          | ',' -> Lexer.junk_chr state; p_cfws (fun _ -> loop) state
          | chr -> raise (Lexer.Error (Lexer.err_expected ',' state)))
    state

(* See RFC 5322 § 3.4.1:

  domain-literal   = [CFWS] "[" *([FWS] dtext) [FWS] "]" [CFWS]
*)
let p_domain_literal p =
  let rec loop acc state =
    match cur_chr state with
    | ']' ->
      Lexer.p_chr ']' state;
      p_cfws (fun _ -> p (List.rev acc |> String.concat "")) state
    | chr when is_dtext chr || chr = '\\' ->
      p_dtext (fun s -> p_fws (fun _ _ -> loop (s :: acc))) state
    | chr -> raise (Lexer.Error (Lexer.err_unexpected chr state))
  in

  p_cfws (fun _ state ->
          match cur_chr state with
          | '[' -> Lexer.p_chr '[' state; p_fws (fun _ _ -> loop []) state
          | chr -> raise (Lexer.Error (Lexer.err_expected '[' state)))

(* See RFC 5322 § 3.4.1:

   domain          = dot-atom / domain-literal / obs-domain
*)
let p_domain p =
  let p_obs_domain' p =
    let rec loop acc state =
      match cur_chr state with
      | '.' ->
        Lexer.junk_chr state;
        p_atom (fun o -> loop (`Atom o :: acc)) state
      | chr -> p (List.rev acc) state
    in

    p_cfws (fun _ -> loop [])
  in

  (* XXX: dot-atom, domain-literal or obs-domain start with [CFWS] *)
  p_cfws (fun _ state ->
    match cur_chr state with
    (* it's domain-literal *)
    | '[' -> p_domain_literal (fun s -> p (`Literal s)) state
    (* it's dot-atom or obs-domain *)
    | chr ->
      p_dot_atom   (* may be we are [CFWS] allowed by obs-domain *)
        (function
         (* if we have an empty list, we need at least one atom *)
         | [] -> p_obs_domain (fun domain -> p (`Domain domain))
         (* in other case, we have at least one atom *)
         | l1 -> p_obs_domain' (fun l2 -> p (`Domain (l1 @ l2)))) state)

(* See RFC 5322 § 3.4.1:

   addr-spec       = local-part "@" domain
*)
let p_addr_spec p state =
  (Logs.debug @@ fun m -> m "state: p_addr_spec");

  p_local_part (fun local_part state ->
                Lexer.p_chr '@' state;
                p_domain (fun domain -> p (local_part, domain)) state)
    state

(* See RFC 5322 § 4.4:

   obs-domain-list = *(CFWS / ",") "@" domain
                     *("," [CFWS] ["@" domain])
*)
let p_obs_domain_list p state =
  (* *("," [CFWS] ["@" domain]) *)
  let rec loop1 acc state =
    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;
      p_cfws
        (fun _ state -> match cur_chr state with
         | '@' ->
           Lexer.junk_chr state;
           p_domain (fun domain -> loop1 (domain :: acc)) state
         | chr -> p (List.rev acc) state)
        state
    | chr -> p (List.rev acc) state
  in

  (* *(CFWS / ",") "@" domain *)
  let rec loop0 state =
    match cur_chr state with
    | ',' -> Lexer.junk_chr state; p_cfws (fun _ -> loop0) state
    | '@' -> Lexer.junk_chr state; p_domain (fun domain -> loop1 [domain]) state
    (* XXX: may be raise an error *)
    | chr -> raise (Lexer.Error (Lexer.err_unexpected chr state))
  in

  p_cfws (fun _ -> loop0) state

let p_obs_route p =
  p_obs_domain_list
    (fun domains state -> Lexer.p_chr ':' state;
                          p domains state)

(* See RFC 5322 § 4.4:

   obs-angle-addr  = [CFWS] "<" obs-route addr-spec ">" [CFWS]
*)
let p_obs_angle_addr p state =
  (Logs.debug @@ fun m -> m "state: p_obs_angle_addr");

  p_cfws                                                 (* [CFWS] *)
    (fun _ state ->
      Lexer.p_chr '<' state;                             (* "<" *)
      p_obs_route                                        (* obs-route *)
        (fun domains ->
          p_addr_spec                                    (* addr-spec *)
            (fun (local_part, domain) state ->
              Lexer.p_chr '>' state;                     (* ">" *)
              p_cfws                                     (* [CFWS] *)
                (fun _ ->
                  p (local_part, domain :: domains)) state))
        state)
    state

(* See RFC 5322 § 3.4:

   angle-addr      = [CFWS] "<" addr-spec ">" [CFWS] /
                     obs-angle-addr
   ---------------------------------------------------
   obs-route       = obs-domain-list ":"
                   = *(CFWS / ",") "@" domain
                     *("," [CFWS] ["@" domain]) ":"
   ---------------------------------------------------
   angle-addr      = [CFWS] "<"
                     ├ *(CFWS / ",") "@" domain
                     │ *("," [CFWS] ["@" domain]) ":"
                     └ local-part "@" domain

                   = [CFWS] "<"
                     ├ *(CFWS / ",") "@" domain
                     │ *("," [CFWS] ["@" domain]) ":"
                     └ (dot-atom / quoted-string /
                        obs-local-part) "@" domain

                   = [CFWS] "<"
                     ├ *(CFWS / ",") "@" domain
                     │ *("," [CFWS] ["@" domain]) ":"
                     └ ('"' / atext) … "@" domain
   --------------------------------------------------
   [CFWS] "<"
   ├ if "," / "@" ─── *(CFWS / ",") ┐
   └ if '"' / atext ─ local-part    ┤
                                    │
   ┌──────────────────── "@" domain ┘
   ├ if we start with local-part    → ">" [CFWS]
   └ if we start with *(CFWS / ",") → *("," [CFWS] ["@" domain]) ":"
                                      addr-spec ">" [CFWS]
   --------------------------------------------------
   And, we have [p_try_rule] to try [addr-spec] firstly and 
   [obs-angle-addr] secondly.

   So, FUCK OFF EMAIL!
*)

let p_angle_addr p state =
  (Logs.debug @@ fun m -> m "state: p_angle_addr");

  let first p state =
    p_cfws
    (fun _ state ->
       Lexer.p_chr '<' state;
       p_addr_spec
       (fun (local_part, domain) state ->
          Lexer.p_chr '>' state;
          p_cfws (fun _ -> p (local_part, [domain])) state)
       state)
    state
  in

  Lexer.p_try_rule p (p_obs_angle_addr p)
    (first (fun data state -> `Ok (data, state)))
    state

(* See RFC 5322 § 3.4:

   display-name    = phrase

   XXX: Updated by RFC 2047
*)
let p_display_name p state =
  (Logs.debug @@ fun m -> m "state: p_display_name");
  p_phrase p state

(* See RFC 5322 § 3.4:

   name-addr       = [display-name] angle-addr
*)
let p_name_addr p state =
  (Logs.debug @@ fun m -> m "state: p_name_addr");

  p_cfws (fun _ state -> match cur_chr state with
    | '<' -> p_angle_addr (fun addr -> p (None, addr)) state
    | chr ->
      p_display_name
        (fun name -> p_angle_addr (fun addr -> p (Some name, addr)))
        state)
    state

(* See RFC 5322 § 3.4:

   mailbox         = name-addr / addr-spec
*)
let p_mailbox p state =
  (Logs.debug @@ fun m -> m "state: p_mailbox");

  Lexer.p_try_rule p
    (p_addr_spec (fun (local_part, domain) -> p (None, (local_part, [domain]))))
    (p_name_addr (fun name_addr state -> `Ok (name_addr, state)))
    state

(* See RFC 5322 § 4.4:

   obs-mbox-list   = *([CFWS] ",") mailbox *("," [mailbox / CFWS])
*)
let p_obs_mbox_list p state =
  (Logs.debug @@ fun m -> m "state: p_obs_mbox_list");

  (* *("," [mailbox / CFWS]) *)
  let rec loop1 acc state =
    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;

      Lexer.p_try_rule
        (fun mailbox state -> loop1 (mailbox :: acc) state)
        (fun state -> p_cfws (fun _ -> loop1 acc) state)
        (fun state -> p_mailbox (fun data state -> `Ok (data, state)) state)
        state
    | chr -> p (List.rev acc) state
  in

  (* *([CFWS] ",") *)
  let rec loop0 state =
    match cur_chr state with
    | ',' -> Lexer.junk_chr state; p_cfws (fun _ -> loop0) state
    | chr -> p_mailbox (fun mailbox -> loop1 [mailbox]) state (* mailbox *)
  in

  p_cfws (fun _ -> loop0) state

(* See RFC 5322 § 3.4:

   mailbox-list    = (mailbox *("," mailbox)) / obs-mbox-list
*)
let p_mailbox_list p state =
  (Logs.debug @@ fun m -> m "state: p_mailbox_list");

  (* *("," [mailbox / CFWS]) *)
  let rec obs acc state =
    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;

      Lexer.p_try_rule
        (fun mailbox -> obs (mailbox :: acc))
        (p_cfws (fun _ -> obs acc))
        (p_mailbox (fun data state -> `Ok (data, state)))
        state
    | chr -> p (List.rev acc) state
  in

  (* *("," mailbox) *)
  let rec loop acc state =
    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;
      p_mailbox (fun mailbox -> loop (mailbox :: acc)) state
    | chr -> p_cfws (fun _ -> obs acc) state
  in

  p_cfws (fun _ state -> match cur_chr state with
          | ',' -> p_obs_mbox_list p state (* obs-mbox-list *)
          | chr ->
            p_mailbox
              (fun mailbox state -> match cur_chr state with
               | ',' -> loop [mailbox] state
               | chr -> p_cfws (fun _ -> obs [mailbox]) state)
              state)
    state

(* See RFC 5322 § 3.4:

   group-list      = mailbox-list / CFWS / obs-group-list
*)
let p_group_list p state =
  Lexer.p_try_rule
    (fun data -> p data)
    (Lexer.p_try_rule
       (fun () -> p [])
       (p_cfws (fun _ -> p []))
       (p_obs_group_list (fun state -> `Ok ((), state))))
    (p_mailbox_list (fun data state -> `Ok (data, state)))
    state

(* See RFC 5322 § 3.4:

   group           = display-name ":" [group-list] ";" [CFWS]
*)
let p_group p state =
  (Logs.debug @@ fun m -> m "state: p_group");

  p_display_name
    (fun display_name state ->
      Lexer.p_chr ':' state;

      (Logs.debug @@ fun m -> m "state: p_group (consume display name)");

      match cur_chr state with
      | ';' ->
        Lexer.p_chr ';' state;
        p_cfws (fun _ -> p (display_name, [])) state
      | chr ->
        p_group_list (fun group ->
          p_cfws (fun _ state ->
            Lexer.p_chr ';' state;
            p (display_name, group) state))
        state)
    state

(* See RFC 5322 § 3.4:

   address         = mailbox / group
*)
let p_address p state =
  (Logs.debug @@ fun m -> m "state: p_address");

  Lexer.p_try_rule
    (fun group state -> p (`Group group) state)
    (p_mailbox (fun mailbox -> p (`Person mailbox)))
    (p_group (fun data state -> `Ok (data, state)))
    state

(* See RFC 5322 § 4.4:

   obs-addr-list   = *([CFWS] ",") address *("," [address / CFWS])
*)
let p_obs_addr_list p state =
  (Logs.debug @@ fun m -> m "state: p_obs_addr");

  (* *("," [address / CFWS]) *)
  let rec loop1 acc state =
    (Logs.debug @@ fun m -> m "state: p_obs_addr/loop1");

    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;

      Lexer.p_try_rule
        (fun address -> loop1 (address :: acc))
        (p_cfws (fun _ -> loop1 acc))
        (p_address (fun data state -> `Ok (data, state)))
        state
    | chr -> p (List.rev acc) state
  in

  (* *([CFWS] ",") *)
  let rec loop0 state =
    (Logs.debug @@ fun m -> m "state: p_obs_addr/loop0");

    match cur_chr state with
    | ',' -> Lexer.junk_chr state; p_address (fun adress -> loop0) state
    | chr -> p_address (fun address -> loop1 [address]) state (* address *)
  in

  p_cfws (fun _ -> loop0) state

(* See RFC 5322 § 3.4:

   address-list    = (address *("," address)) / obs-addr-list
*)
let p_address_list p state =
  (Logs.debug @@ fun m -> m "state: p_address_list");

  (* *("," [address / CFWS]) *)
  let rec obs acc state =
    (Logs.debug @@ fun m -> m "state: p_address_list/obs");

    match cur_chr state with
    | ',' ->
      Lexer.junk_chr state;

      Lexer.p_try_rule
        (fun address -> obs (address :: acc))
        (p_cfws (fun _ -> obs acc))
        (p_address (fun data state -> `Ok (data, state)))
        state
    | chr -> p (List.rev acc) state
  in

  (* *("," address) *)
  let rec loop acc state =
    (Logs.debug @@ fun m -> m "state: p_address_list/loop");

    match cur_chr state with
    | ',' -> Lexer.junk_chr state;
      Lexer.p_try_rule
        (fun address -> loop (address :: acc))
        (p_cfws (fun _ -> obs acc))
        (p_address (fun address state -> `Ok (address, state)))
        state
      (* p_address (fun address -> loop (address :: acc)) state *)
    | chr -> p_cfws (fun _ -> obs acc) state
  in

  p_cfws (fun _ state -> match cur_chr state with
          | ',' -> p_obs_addr_list p state (* obs-addr-list *)
          | chr ->
            p_address
              (fun address state -> match cur_chr state with
               | ',' -> loop [address] state
               | chr -> p_cfws (fun _ -> obs [address]) state)
              state)
    state

let p_crlf p state =
  (Logs.debug @@ fun m -> m "state: p_crlf");

  Lexer.p_chr '\r' state;
  Lexer.p_chr '\n' state;
  p state

(* See RFC 5322 § 3.6.8:

   ftext           = %d33-57 /          ; Printable US-ASCII
                     %d59-126           ;  characters not including
                                          ;  ":".
*)
let is_ftext = function
  | '\033' .. '\057'
  | '\059' .. '\126' -> true
  | chr -> false

(* See RFC 5322 § 3.6.8:

   field-name      = 1*ftext
*)
let p_field_name = Lexer.p_repeat ~a:1 is_ftext

(* See RFC 5322 § 4.5.3:

   obs-bcc         = "Bcc" *WSP ":"
                     (address-list / ( *([CFWS] ",") [CFWS])) CRLF
*)
let p_obs_bcc p state =
  (Logs.debug @@ fun m -> m "state: p_obs_bcc");


  let rec aux state =
    p_cfws (fun _ state ->
      (Logs.debug @@ fun m -> m "state: p_obs_bcc/aux [%S]"
       (Bytes.sub state.Lexer.buffer state.Lexer.pos (state.Lexer.len -
       state.Lexer.pos)));

      match cur_chr state with
      | ',' -> aux state
      | chr -> p [] state)
      state
  in

  Lexer.p_try_rule p aux
    (p_address_list (fun l state -> `Ok (l, state))) state

(* See RFC 5322 § 3.6.3:

   bcc             = "Bcc:" [address-list / CFWS] CRLF
*)
let p_bcc p state =
  (Logs.debug @@ fun m -> m "state: p_bcc");

  Lexer.p_try_rule p
    (p_obs_bcc p)
    (p_address_list (fun l state -> `Ok (l, state))) state

(* phrase / msg-id for:

   references      = "References:" 1*msg-id CRLF
   obs-references  = "References" *WSP ":" *(phrase / msg-id) CRLF
   in-reply-to     = "In-Reply-To:" 1*msg-id CRLF
   obs-in-reply-to = "In-Reply-To" *WSP ":" *(phrase / msg-id) CRLF
*)
let p_phrase_or_msg_id p state =
  let rec loop acc =
    Lexer.p_try_rule
      (fun x -> loop (`MsgID x :: acc))
      (Lexer.p_try_rule
        (fun x -> loop (`Phrase x :: acc))
        (p (List.rev acc))
        (p_phrase (fun data state -> `Ok (data, state))))
      (p_msg_id (fun data state -> `Ok (data, state)))
  in

  loop [] state

(* See RFC 5322 § 3.6.7:

   received-token  = word / angle-addr / addr-spec / domain
*)
let p_received_token p state =
  let rec loop acc =
    Lexer.p_try_rule
      (fun data -> loop (`Domain data :: acc))
      (Lexer.p_try_rule
        (fun data -> loop (`Mailbox data :: acc))
        (Lexer.p_try_rule
          (fun data -> loop (`Mailbox data :: acc))
          (Lexer.p_try_rule
            (fun data -> loop (`Word data :: acc))
            (p (List.rev acc))
            (p_word (fun data state -> `Ok (data, state))))
          (p_addr_spec (fun (local, domain) state ->
                        `Ok ((local, [domain]), state))))
        (p_angle_addr (fun data state -> `Ok (data, state))))
      (p_domain (fun data state -> `Ok (data, state)))
  in

  loop [] state

(* See RFC 5322 § 3.6.7:

   received        = "Received:" *received-token ";" date-time CRLF
   obs-received    = "Received" *WSP ":" *received-token CRLF
*)
let p_received p state =
  p_received_token
    (fun l state -> match cur_chr state with
     | ';' ->
       Lexer.p_chr ';' state;
       p_date_time (fun date_time -> p (l, Some date_time)) state
     | chr -> p (l, None) state)
    state

(* See RFC 5322 § 3.6.7:

   path            = angle-addr / ([CFWS] "<" [CFWS] ">" [CFWS])
*)
let p_path p =
  Lexer.p_try_rule
    (fun addr -> p (Some addr))
    (fun state ->
      p_cfws
        (fun _ state ->
          Lexer.p_chr '<' state;
          p_cfws
            (fun _ state ->
              Lexer.p_chr '>' state;
              p_cfws (fun _ -> p None) state)
            state)
        state)
    (p_angle_addr (fun data state -> `Ok (data, state)))

(* See RFC 5322 § 4.1:

   obs-phrase-list = [phrase / CFWS] *("," [phrase / CFWS])
*)
let p_obs_phrase_list p state =
  let rec loop acc state =
    Lexer.p_try_rule
      (fun s -> loop (s :: acc))
      (p_cfws (fun _ state ->
       match cur_chr state with
       | ',' -> Lexer.p_chr ',' state; loop acc state
       | chr -> p (List.rev acc) state))
      (fun state ->
       Lexer.p_chr ',' state;
       p_phrase (fun s state -> `Ok (s, state)) state)
      state
  in

  p_cfws (fun _ -> p_phrase (fun s -> loop [s])) state

(* See RFC 5322 § 3.6.5:

   keywords        = "Keywords:" phrase *("," phrase) CRLF
   obs-keywords    = "Keywords" *WSP ":" obs-phrase-list CRLF
*)
let p_keywords p state =
  let rec loop p acc =
    p_phrase (fun s state ->
      match cur_chr state with
      | ',' -> Lexer.p_chr ',' state; loop p (s :: acc) state
      | chr -> p_obs_phrase_list (fun l -> p (List.rev acc @ l)) state)
  in

  Lexer.p_try_rule
    (fun l -> p l)
    (p_obs_phrase_list p)
    (p_phrase (fun s -> loop (fun s state -> `Ok (s, state)) [s]))
    state

(* See RFC 5322 § 3.6.8:

   optional-field  = field-name ":" unstructured CRLF
   obs-optional    = field-name *WSP ":" unstructured CRLF
*)
let p_field p state =
  let field = p_field_name state in
  let _     = Lexer.p_repeat is_wsp state in

  Lexer.p_chr ':' state;

  (Logs.debug @@ fun m -> m "state: p_field (with: %s)" field);

  let rule = match String.lowercase field with
    | "from"              ->
      p_mailbox_list     (fun l -> p_crlf @@ p (`From l))
    | "sender"            ->
      p_mailbox          (fun m -> p_crlf @@ p (`Sender m))
    | "reply-to"          ->
      p_address_list     (fun l -> p_crlf @@ p (`ReplyTo l))
    | "to"                ->
      p_address_list     (fun l -> p_crlf @@ p (`To l))
    | "cc"                ->
      p_address_list     (fun l -> p_crlf @@ p (`Cc l))
    | "bcc"               ->
      p_bcc              (fun l -> p_crlf @@ p (`Bcc l))
    | "date"              ->
      p_date_time        (fun d -> p_crlf @@ p (`Date d))
    | "message-id"        ->
      p_msg_id           (fun m -> p_crlf @@ p (`MessageID m))
    | "subject"           ->
      p_unstructured     (fun s -> p_crlf @@ p (`Subject s))
    | "comments"          ->
      p_unstructured     (fun s -> p_crlf @@ p (`Comments s))
    | "keywords"          ->
      p_keywords         (fun l -> p_crlf @@ p (`Keywords l))
    | "in-reply-to"       ->
      p_phrase_or_msg_id (fun l -> p_crlf @@ p (`InReplyTo l))
    | "resent-date"       ->
      p_date_time        (fun d -> p_crlf @@ p (`ResentDate d))
    | "resent-from"       ->
      p_mailbox_list     (fun l -> p_crlf @@ p (`ResentFrom l))
    | "resent-sender"     ->
      p_mailbox          (fun m -> p_crlf @@ p (`ResentSender m))
    | "resent-to"         ->
      p_address_list     (fun l -> p_crlf @@ p (`ResentTo l))
    | "resent-cc"         ->
      p_address_list     (fun l -> p_crlf @@ p (`ResentCc l))
    | "resent-bcc"        ->
      p_bcc              (fun l -> p_crlf @@ p (`ResentBcc l))
    | "resent-message-id" ->
      p_msg_id           (fun m -> p_crlf @@ p (`ResentMessageID m))
    | "references"        ->
      p_phrase_or_msg_id (fun l -> p_crlf @@ p (`References l))
    | "received"          ->
      p_received         (fun r -> p_crlf @@ p (`Received r))
    | "return-path"       ->
      p_path             (fun a -> p_crlf @@ p (`ReturnPath a))
    | "content-type"      ->
      Rfc2045.p_content  (fun c -> p_crlf @@ p (`ContentType c))
    | "mime-version"      ->
      Rfc2045.p_version  (fun v -> p_crlf @@ p (`MIMEVersion v))
    | "content-encoding"  ->
      Rfc2045.p_encoding (fun e -> p_crlf @@ p (`ContentEncoding e))
    | field               ->
      p_unstructured @@ (fun data -> p_crlf @@ (p (`Field (field, data))))
  in

  rule state

let p_header p state =
  let rec loop acc state =
    Lexer.p_try_rule
      (fun field -> loop (field :: acc)) (p (List.rev acc))
      (p_field (fun data state -> `Ok (data, state)))
      state
  in

  loop [] state
