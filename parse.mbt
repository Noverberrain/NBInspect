///|
fn field(value : Json, key : String) -> Json {
  match value {
    Object(obj) => obj.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn object_at(value : Json, path : String) -> Unit raise InputError {
  match value {
    Object(_) => ()
    _ => raise Invalid(path + ": expected object")
  }
}

///|
fn array_at(value : Json, path : String) -> Array[Json] raise InputError {
  match value {
    Array(a) => a
    _ => raise Invalid(path + ": expected array")
  }
}

///|
fn text_at(value : Json, path : String) -> String raise InputError {
  match value {
    String(s) => s
    Array(a) => {
      let b = StringBuilder()
      for item in a {
        match item {
          String(s) => b.write_string(s)
          _ => raise Invalid(path + ": expected string array")
        }
      }
      b.to_string()
    }
    _ => raise Invalid(path + ": expected text")
  }
}

///|
fn number_at(value : Json, path : String) -> Int raise InputError {
  match value {
    Number(n, ..) => {
      let i = n.to_int()
      if i.to_double() != n || i < 0 {
        raise Invalid(path + ": expected nonnegative integer")
      }
      i
    }
    _ => raise Invalid(path + ": expected integer")
  }
}

///|
fn nullable_count(value : Json, path : String) -> Unit raise InputError {
  if value != Json::null() {
    ignore(number_at(value, path))
  }
}

///|
fn valid_id(id : String) -> Bool {
  id.length() > 0 &&
  id.length() <= 64 &&
  id
  .iter()
  .all(fn(c) {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '-' ||
    c == '_'
  })
}

///|
/// Read supported Notebook structures without executing code or discarding extensions.
pub fn parse(
  input : String,
  max_bytes? : Int = 52428800,
  max_cells? : Int = 10000,
) -> Notebook raise InputError {
  if max_bytes <= 0 || max_cells <= 0 {
    raise Invalid("limits must be positive")
  }
  if @utf8.encode(input).length() > max_bytes {
    raise Invalid("input exceeds byte limit")
  }
  let root = @json.parse(input) catch { _ => raise Invalid("invalid JSON") }
  object_at(root, "")
  if number_at(field(root, "nbformat"), "/nbformat") != 4 {
    raise Invalid("/nbformat: only major version 4 supported")
  }
  let minor = number_at(field(root, "nbformat_minor"), "/nbformat_minor")
  object_at(field(root, "metadata"), "/metadata")
  let values = array_at(field(root, "cells"), "/cells")
  if values.length() > max_cells {
    raise Invalid("/cells: cell limit exceeded")
  }
  let cells : Array[Cell] = []
  let findings : Array[Finding] = []
  let ids : Map[String, Int] = Map([])
  for index, raw in values {
    let path = "/cells/" + index.to_string()
    object_at(raw, path)
    object_at(field(raw, "metadata"), path + "/metadata")
    let kind = match field(raw, "cell_type") {
      String(s) => s
      _ => raise Invalid(path + "/cell_type: expected string")
    }
    if kind != "code" && kind != "markdown" && kind != "raw" {
      raise Invalid(path + "/cell_type: unsupported cell type")
    }
    let source = text_at(field(raw, "source"), path + "/source")
    let id = match field(raw, "id") {
      String(s) => Some(s)
      _ => None
    }
    if minor >= 5 && (id is None || !valid_id(id.unwrap_or(""))) {
      findings.push({
        code: "FMT002",
        severity: "error",
        path: path + "/id",
        message: "missing or invalid cell ID",
      })
    }
    if id is Some(s) {
      if ids.contains(s) {
        findings.push({
          code: "FMT002",
          severity: "error",
          path: path + "/id",
          message: "duplicate cell ID",
        })
      }
      ids[s] = index
    }
    if kind == "code" {
      match raw {
        Object(o) =>
          if !o.contains("execution_count") {
            raise Invalid(path + "/execution_count: required")
          }
        _ => ()
      }
      nullable_count(field(raw, "execution_count"), path + "/execution_count")
      for oi, output in array_at(field(raw, "outputs"), path + "/outputs") {
        let op = path + "/outputs/" + oi.to_string()
        object_at(output, op)
        match field(output, "output_type") {
          String("stream") => {
            ignore(text_at(field(output, "text"), op + "/text"))
            let name = field(output, "name")
            if name != Json::string("stdout") && name != Json::string("stderr") {
              raise Invalid(op + "/name: expected stdout or stderr")
            }
          }
          String("display_data") | String("execute_result") => {
            object_at(field(output, "data"), op + "/data")
            object_at(field(output, "metadata"), op + "/metadata")
            if field(output, "output_type") == Json::string("execute_result") {
              ignore(
                number_at(
                  field(output, "execution_count"),
                  op + "/execution_count",
                ),
              )
            }
          }
          String("error") => {
            for key in ["ename", "evalue"] {
              match field(output, key) {
                String(_) => ()
                _ => raise Invalid(op + "/" + key + ": expected string")
              }
            }
            ignore(text_at(field(output, "traceback"), op + "/traceback"))
          }
          _ => raise Invalid(op + "/output_type: unsupported output")
        }
      }
    }
    match field(raw, "attachments") {
      Null => ()
      attachments => {
        object_at(attachments, path + "/attachments")
        match attachments {
          Object(o) =>
            for name, bundle in o {
              object_at(bundle, path + "/attachments/" + name)
            }
          _ => ()
        }
      }
    }
    cells.push({ index, id, kind, source, raw, })
  }
  { minor, cells, raw: root, findings, compatible: minor <= 5, }
}
