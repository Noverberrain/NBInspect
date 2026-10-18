///|
#borrow(path, utf8)
extern "C" fn read_bytes(path : String, utf8 : Bytes, limit : Int) -> Bytes = "nb_read"

///|
extern "C" fn exit_process(code : Int) -> Unit = "nb_exit"

///|
fn main {
  let args = @env.args()
  let result : Json = try {
    if args.length() != 2 || args[1].contains("\u0000") {
      raise @syntax.Invalid("expected one transport JSON file")
    }
    let raw = read_bytes(args[1], @utf8.encode(args[1]), 16777216)
    if raw.length() == 0 {
      raise @syntax.Invalid(
        "cannot read, empty file or transport exceeds 16 MiB",
      )
    }
    let text = @utf8.decode(raw) catch {
      _ => raise @syntax.Invalid("transport is not UTF-8")
    }
    @syntax.read_transport(text).to_json()
  } catch {
    @syntax.Invalid(message) => { "error": message }
  }
  println(result.stringify())
  exit_process(
    if result is { "error": _, .. } {
      2
    } else if result is { "status": "parse-errors", .. } {
      1
    } else {
      0
    },
  )
}
