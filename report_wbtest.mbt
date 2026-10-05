///|
test "reports preserve hidden and visible counts" {
  let a = book([("a", "one")])
  let b = book([("a", "two")])
  let r = diff_report(a, b, view="code")
  assert_eq(field(r, "visible_changes"), Json::number(0))
  assert_eq(field(r, "total_changes"), Json::number(1))
}

///|
test "report schema and unknown version status" {
  assert_eq(field(check_report(book([])), "schema_version"), Json::number(1))
  let n = parse(
    "{\"nbformat\":4,\"nbformat_minor\":6,\"metadata\":{},\"cells\":[]}",
  )
  assert_eq(field(check_report(n), "status"), Json::string("unsupported"))
}
