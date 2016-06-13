type t

module D :
sig
  val of_lexer   : Rfc5322.date_time -> t
  val of_decoder : Decoder.t -> t
end

module E :
sig
  val to_buffer  : t -> Encoder.t -> Buffer.t
  val w          : (t, 'r Encoder.partial) Wrap.k1
end

val of_string : string -> t
val to_string : t -> string

val equal     : t -> t -> bool
val pp        : Format.formatter -> t -> unit
