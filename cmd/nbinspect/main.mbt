///|
#borrow(path, utf8)
extern "C" fn read_bytes(path : String, utf8 : Bytes, limit : Int) -> Bytes = "nb_read"

///|
#borrow(path, utf8, bytes)
extern "C" fn write_bytes(path : String, utf8 : Bytes, bytes : Bytes) -> Int = "nb_write"

///|
#borrow(bytes)
extern "C" fn error_bytes(bytes : Bytes) -> Unit = "nb_stderr"

///|
extern "C" fn exit_process(code : Int) -> Unit = "nb_exit"

///|
fn read(path : String) -> String raise @nb.InputError {
  if path.contains("\u0000") {
    raise @nb.Invalid("path contains NUL")
  }
  let raw = read_bytes(path, @utf8.encode(path), 52428800)
  if raw.length() == 0 {
    raise @nb.Invalid(
      "cannot read, empty file or input exceeds 50 MiB: " + path,
    )
  }
  @utf8.decode(raw) catch {
    _ => raise @nb.Invalid("input is not UTF-8: " + path)
  }
}

///|
fn run(args : Array[String]) -> Int raise @nb.InputError {
  if args.length() == 0 || args[0] == "--help" {
    println(
      "NBInspect: check FILE | diff BEFORE AFTER [--format json|text|html] [--output FILE] [--view all|code|content] [--exit-code] | review BEFORE AFTER [--format json|text|html] [--output FILE] [--fail-on error|warning|info]",
    )
    return 0
  }
  let command = args[0]
  if command != "check" && command != "diff" && command != "review" {
    raise @nb.Invalid("expected check, diff or review")
  }
  let positional : Array[String] = []
  let mut format = "text"
  let mut output : String? = None
  let mut view = "all"
  let mut fail_on = "error"
  let mut exit_diff = false
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    if arg == "--exit-code" {
      exit_diff = true
      i += 1
    } else if ["--format", "--output", "--view", "--fail-on"].contains(arg) {
      if i + 1 >= args.length() {
        raise @nb.Invalid("missing option value: " + arg)
      }
      let value = args[i + 1]
      match arg {
        "--format" => format = value
        "--output" => output = Some(value)
        "--view" => view = value
        _ => fail_on = value
      }
      i += 2
    } else if arg.has_prefix("--") {
      raise @nb.Invalid("unknown option: " + arg)
    } else {
      positional.push(arg)
      i += 1
    }
  }
  if !["json", "text", "html"].contains(format) {
    raise @nb.Invalid("format must be json, text or html")
  }
  if !["all", "code", "content"].contains(view) {
    raise @nb.Invalid("unknown view")
  }
  if !["error", "warning", "info"].contains(fail_on) {
    raise @nb.Invalid("unknown fail-on")
  }
  if positional.length() != (if command == "check" { 1 } else { 2 }) {
    raise @nb.Invalid("wrong number of input files")
  }
  if (command == "check" || command == "review") && (exit_diff || view != "all") {
    raise @nb.Invalid("diff options are not valid for check or review")
  }
  if command == "diff" && fail_on != "error" {
    raise @nb.Invalid("fail-on is a check or review option")
  }
  if output is Some(path) && positional.contains(path) {
    raise @nb.Invalid("report cannot overwrite an input file")
  }
  let before = @nb.parse(read(positional[0]))
  let report : Json = if command == "check" {
    @nb.check_report(before, fail_on~)
  } else {
    let after = @nb.parse(read(positional[1]))
    if command == "diff" {
      @nb.diff_report(before, after, view~)
    } else {
      @nb.review_report(before, after, fail_on~)
    }
  }
  let content = if format == "json" {
    report.stringify(indent=2)
  } else if format == "html" {
    @nb.html_report(report)
  } else {
    @nb.text_report(report)
  }
  match output {
    Some(path) => {
      if path.contains("\u0000") {
        raise @nb.Invalid("output contains NUL")
      }
      if write_bytes(path, @utf8.encode(path), @utf8.encode(content)) != 0 {
        raise @nb.Invalid("cannot write report: " + path)
      }
    }
    None => println(content)
  }
  if command == "check" {
    if !before.compatible {
      2
    } else if @nb.blocks(@nb.check(before), fail_on~) {
      1
    } else {
      0
    }
  } else if command == "review" {
    let blocked = match report {
      Object(o) => o.get("status") == Some(Json::string("blocked"))
      _ => false
    }
    if blocked {
      1
    } else {
      0
    }
  } else {
    let count = match report {
      Object(o) =>
        match o.get("visible_changes") {
          Some(Number(n, ..)) => n.to_int()
          _ => 0
        }
      _ => 0
    }
    if exit_diff && count > 0 {
      1
    } else {
      0
    }
  }
}

///|
fn main {
  let args = @env.args()
  let code = run(args[1:].to_owned()) catch {
    @nb.Invalid(message) => {
      error_bytes(@utf8.encode("nbinspect: " + message + "\n"))
      2
    }
  }
  exit_process(code)
}
