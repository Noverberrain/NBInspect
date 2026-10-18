///|
fn get(value : Json, key : String) -> Json raise SyntaxError {
  match value {
    Object(obj) =>
      match obj.get(key) {
        Some(v) => v
        None => raise Invalid("missing field: " + key)
      }
    _ => raise Invalid("expected object")
  }
}

///|
fn shape(value : Json, count : Int) -> Unit raise SyntaxError {
  match value {
    Object(obj) =>
      if obj.length() != count {
        raise Invalid("unexpected fields")
      }
    _ => raise Invalid("expected object")
  }
}

///|
fn integer(value : Json) -> Int raise SyntaxError {
  match value {
    Number(n, ..) => {
      if n < 0.0 || n > 2147483647.0 {
        raise Invalid("integer out of range")
      }
      let i = n.to_int()
      if i.to_double() != n {
        raise Invalid("expected integer")
      }
      i
    }
    _ => raise Invalid("expected integer")
  }
}

///|
fn text(value : Json) -> String raise SyntaxError {
  match value {
    String(s) => s
    _ => raise Invalid("expected string")
  }
}

///|
fn boolean(value : Json) -> Bool raise SyntaxError {
  match value {
    True => true
    False => false
    _ => raise Invalid("expected boolean")
  }
}

///|
fn optional_text(value : Json) -> String? raise SyntaxError {
  if value == Json::null() {
    return None
  }
  let s = text(value)
  if s == "" || s.length() > 128 {
    raise Invalid("invalid field name")
  }
  Some(s)
}

///|
fn position(
  value : Json,
  bytes : Bytes,
  lines : Array[Int],
) -> Position raise SyntaxError {
  shape(value, 3)
  let offset = integer(get(value, "byte_offset"))
  let line = integer(get(value, "line"))
  let column = integer(get(value, "column"))
  if offset > bytes.length() || line >= lines.length() {
    raise Invalid("position out of range")
  }
  if offset < bytes.length() && (bytes[offset].to_int() & 192) == 128 {
    raise Invalid("position splits UTF-8 character")
  }
  let mut low = 0
  let mut high = lines.length()
  while low + 1 < high {
    let mid = low + (high - low) / 2
    if lines[mid] <= offset {
      low = mid
    } else {
      high = mid
    }
  }
  if line != low || column != offset - lines[low] {
    raise Invalid("inconsistent line or byte column")
  }
  { byte_offset: offset, line, column, }
}

///|
/// Validate an adapter transport, not Python grammar independently. Requires the
/// pinned Tree-sitter WASM adapter; source and full CST are retained in the result.
/// Limits: 1 MiB source, 16 MiB transport, 50,000 nodes, 256 edges of nesting.
pub fn read_transport(input : String) -> Document raise SyntaxError {
  if @utf8.encode(input).length() > 16777216 {
    raise Invalid("transport exceeds 16 MiB")
  }
  let raw = @json.parse(input) catch {
    _ => raise Invalid("invalid transport JSON")
  }
  shape(raw, 5)
  if get(raw, "schema_version") != Json::number(1) ||
    get(raw, "parser") !=
    Json::string("tree-sitter-python@0.25.0/web-tree-sitter@0.25.10") {
    raise Invalid("unsupported syntax transport or parser version")
  }
  let source = text(get(raw, "source"))
  let bytes = @utf8.encode(source)
  if bytes.length() > 1048576 {
    raise Invalid("source exceeds 1 MiB")
  }
  let lines = [0]
  for i, b in bytes {
    if b == b'\n' {
      lines.push(i + 1)
    }
  }
  let rows = match get(raw, "nodes") {
    Array(rows) => rows
    _ => raise Invalid("expected node array")
  }
  if rows.is_empty() || rows.length() > 50000 {
    raise Invalid("node count must be 1..50000")
  }
  let root_error = boolean(get(raw, "root_has_error"))
  let nodes : Array[SyntaxNode] = []
  let diagnostics : Array[Diagnostic] = []
  let ancestors : Array[Int] = []
  let last_end : Array[Int] = []
  for i, row in rows {
    shape(row, 7)
    let kind = text(get(row, "kind"))
    if kind == "" || kind.length() > 128 {
      raise Invalid("invalid node kind")
    }
    let field_name = optional_text(get(row, "field_name"))
    let named = boolean(get(row, "named"))
    let missing = boolean(get(row, "missing"))
    let start = position(get(row, "start"), bytes, lines)
    let end = position(get(row, "end"), bytes, lines)
    if start.byte_offset > end.byte_offset {
      raise Invalid("reversed node range")
    }
    let parent = if get(row, "parent") == Json::null() {
      None
    } else {
      Some(integer(get(row, "parent")))
    }
    if i == 0 {
      if parent != None || field_name != None || kind != "module" || !named {
        raise Invalid("expected module root")
      }
    } else {
      let p = match parent {
        Some(p) if p < i => p
        _ => raise Invalid("invalid parent index")
      }
      while !ancestors.is_empty() && ancestors[ancestors.length() - 1] != p {
        ignore(ancestors.pop())
      }
      if ancestors.is_empty() {
        raise Invalid("nodes must be in preorder")
      }
      if ancestors.length() > 256 {
        raise Invalid("syntax depth exceeds 256")
      }
      let owner = nodes[p]
      if start.byte_offset < owner.start.byte_offset ||
        end.byte_offset > owner.end.byte_offset ||
        start.byte_offset < last_end[p] {
        raise Invalid("child outside parent or overlapping siblings")
      }
      last_end[p] = end.byte_offset
    }
    nodes.push({
      index: i,
      parent,
      kind,
      field_name,
      named,
      missing,
      start,
      end,
    })
    last_end.push(start.byte_offset)
    ancestors.push(i)
    if kind == "ERROR" || missing {
      diagnostics.push({
        node: i,
        kind: if missing {
          "missing"
        } else {
          "error"
        },
        start,
        end,
      })
    }
  }
  if root_error != !diagnostics.is_empty() {
    raise Invalid("inconsistent parser diagnostics")
  }
  {
    schema_version: 1,
    kind: "python-syntax",
    status: if root_error {
      "parse-errors"
    } else {
      "parsed"
    },
    parser: "tree-sitter-python@0.25.0/web-tree-sitter@0.25.10",
    coordinates: "zero-based-utf8-lf",
    source,
    nodes,
    diagnostics,
  }
}
