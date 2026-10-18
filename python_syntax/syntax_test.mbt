///|
fn fixture(source : String, child : Json?, has_error? : Bool = false) -> String {
  let point = fn(n : Int) -> Json {
    { "byte_offset": n, "line": 0, "column": n }
  }
  let count = @utf8.encode(source).length()
  let root : Json = {
    "kind": "module",
    "parent": Json::null(),
    "field_name": Json::null(),
    "named": true,
    "missing": false,
    "start": point(0),
    "end": point(count),
  }
  let nodes = [root]
  if child is Some(value) {
    nodes.push(value)
  }
  let raw : Json = {
    "schema_version": 1,
    "parser": "tree-sitter-python@0.25.0/web-tree-sitter@0.25.10",
    "source": source,
    "root_has_error": has_error,
    "nodes": nodes,
  }
  raw.stringify()
}

///|
fn child(kind : String, start : Int, end : Int, parent? : Int = 0) -> Json {
  {
    "kind": kind,
    "parent": parent,
    "field_name": Json::null(),
    "named": true,
    "missing": false,
    "start": { "byte_offset": start, "line": 0, "column": start },
    "end": { "byte_offset": end, "line": 0, "column": end },
  }
}

///|
fn rejected(input : String, reason : String) -> Unit raise {
  let result = try {
    ignore(@python_syntax.read_transport(input))
    "accepted"
  } catch {
    @python_syntax.Invalid(message) => message
  }
  assert_true(result.contains(reason))
}

///|
test "empty source remains a complete syntax document" {
  let doc = @python_syntax.read_transport(fixture("", None))
  assert_eq(doc.status, "parsed")
  assert_eq(doc.nodes.length(), 1)
  assert_eq(doc.nodes[0].start.byte_offset, 0)
  assert_eq(doc.diagnostics.length(), 0)
}

///|
test "UTF8 node positions are validated independently of UTF16 host indices" {
  let doc = @python_syntax.read_transport(
    fixture("变量", Some(child("identifier", 0, 6))),
  )
  assert_eq(doc.nodes[1].end.byte_offset, 6)
  rejected(fixture("变量", Some(child("identifier", 0, 1))), "splits UTF-8")
  rejected(fixture("x", Some(child("identifier", 0, 2))), "out of range")
}

///|
test "recovered syntax errors stay errors and retain source evidence" {
  let input = fixture("?", Some(child("ERROR", 0, 1)), has_error=true)
  let doc = @python_syntax.read_transport(input)
  assert_eq(doc.status, "parse-errors")
  assert_eq(doc.source, "?")
  assert_eq(doc.diagnostics.length(), 1)
  assert_eq(doc.diagnostics[0].node, 1)
  rejected(
    fixture("?", Some(child("ERROR", 0, 1))),
    "inconsistent parser diagnostics",
  )
}

///|
test "malformed parents and reversed spans are not accepted as evidence" {
  rejected(
    fixture("x", Some(child("identifier", 0, 1, parent=1))),
    "parent index",
  )
  rejected(fixture("x", Some(child("identifier", 1, 0))), "reversed")
  rejected("{", "invalid transport JSON")
}

///|
test "source limits reject instead of producing partial success" {
  let source = String::make(1048577, 'x')
  rejected(fixture(source, None), "source exceeds 1 MiB")
}
