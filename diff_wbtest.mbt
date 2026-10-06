///|
test "line diff preserves code whitespace" {
  let r = line_diff("x = 1\nend", "x = 2\nend")
  assert_eq(r.filter(fn(x) { x.operation == "delete" })[0].text, "x = 1")
  assert_eq(r.filter(fn(x) { x.operation == "insert" })[0].text, "x = 2")
}

///|
test "text representations compare identically" {
  let d = diff(parse(fixture("a\nb")), parse(fixture(["a\n", "b"])))
  assert_eq(d.changes.length(), 0)
}

///|
test "classification and filtering" {
  let d = diff(book([("a", "before")]), book([("a", "after")]))
  assert_eq(d.changes[0].category, "markdown")
  assert_eq(visible_changes(d, view="code").length(), 0)
  assert_eq(visible_changes(d, view="content").length(), 1)
}

///|
test "object key order is semantic and resource errors are explicit" {
  let a = parse(
    "{\"nbformat\":4,\"nbformat_minor\":5,\"metadata\":{\"a\":1,\"b\":2},\"cells\":[]}",
  )
  let b = parse(
    "{\"cells\":[],\"metadata\":{\"b\":2,\"a\":1},\"nbformat_minor\":5,\"nbformat\":4}",
  )
  assert_eq(diff(a, b).notebook_changed, false)
  try line_diff("a\nb", "c\nd", max_work=2) catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("expected limit failure")
  }
}
