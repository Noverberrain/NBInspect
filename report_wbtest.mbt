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

///|
test "review report exposes risk states and selected blocking severity" {
  let before = book([("a", "plain")])
  let after = book([("a", "![missing](attachment:x.png)")])
  let passed = review_report(before, after)
  assert_eq(field(passed, "kind"), Json::string("review"))
  assert_eq(field(passed, "status"), Json::string("passed"))
  assert_eq(field(field(passed, "summary"), "introduced"), Json::number(1))
  let blocked = review_report(before, after, fail_on="warning")
  assert_eq(field(blocked, "status"), Json::string("blocked"))
  let text = text_report(blocked)
  assert_true(text.contains("introduced warning ATT001"))
  assert_true(text.contains("Introduced: 1"))
  let html = html_report(blocked)
  assert_true(html.contains("Risk changes"))
  assert_true(html.contains("Matching evidence"))
}

///|
test "review HTML escapes finding text" {
  let before = book([("a", "plain")])
  let after = book([("a", "![x](attachment:<img)")])
  let html = html_report(review_report(before, after))
  assert_true(html.contains("&lt;img"))
  assert_false(html.contains("<img"))
}
