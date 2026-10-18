///|
fn fixture(source : String, error? : Bool = false) -> String {
  let point = fn(n : Int) -> Json {
    { "byte_offset": n, "line": 0, "column": n }
  }
  let node = fn(
    kind : String,
    parent : Json,
    field : Json,
    start : Int,
    end : Int,
    named : Bool,
  ) -> Json {
    {
      "kind": kind,
      "parent": parent,
      "field_name": field,
      "named": named,
      "missing": false,
      "start": point(start),
      "end": point(end),
    }
  }
  let nodes = [
    node("module", Json::null(), Json::null(), 0, source.length(), true),
  ]
  if error {
    nodes.push(
      node("ERROR", Json::number(0), Json::null(), 0, source.length(), true),
    )
  } else if source == "x=x" {
    nodes.push(
      node("expression_statement", Json::number(0), Json::null(), 0, 3, true),
    )
    nodes.push(node("assignment", Json::number(1), Json::null(), 0, 3, true))
    nodes.push(
      node("identifier", Json::number(2), Json::string("left"), 0, 1, true),
    )
    nodes.push(node("=", Json::number(2), Json::null(), 1, 2, false))
    nodes.push(
      node("identifier", Json::number(2), Json::string("right"), 2, 3, true),
    )
  }
  let raw : Json = {
    "schema_version": 1,
    "parser": "tree-sitter-python@0.25.0/web-tree-sitter@0.25.10",
    "source": source,
    "root_has_error": error,
    "nodes": nodes,
  }
  raw.stringify()
}

///|
test "empty module has no fabricated bindings" {
  let report = @python_bindings.analyze(fixture(""))
  assert_eq(report.status, "modeled")
  assert_eq(report.definitions.length(), 0)
  assert_eq(report.references.length(), 0)
}

///|
test "assignment reads before its first write" {
  let report = @python_bindings.analyze(fixture("x=x"))
  assert_eq(report.definitions.length(), 1)
  assert_eq(report.definitions[0].version, 1)
  assert_eq(report.references[0].resolution, "external")
  assert_true(report.references[0].order < report.definitions[0].order)
  assert_eq(report.references[0].start.byte_offset, 2)
}

///|
test "recovery nodes cannot produce apparently complete bindings" {
  let report = @python_bindings.analyze(fixture("?", error=true))
  assert_eq(report.status, "incomplete")
  assert_eq(report.definitions.length(), 0)
  assert_eq(report.references.length(), 0)
  assert_eq(report.uncertainties[0].reason, "syntax-errors-no-binding-analysis")
}

///|
test "malformed transport remains a typed input failure" {
  let message = try {
    ignore(@python_bindings.analyze("{"))
    "accepted"
  } catch {
    @syntax.Invalid(s) => s
  }
  assert_true(message.contains("invalid transport JSON"))
}
