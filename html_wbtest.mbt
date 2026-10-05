///|
test "malicious notebook output remains escaped text" {
  let d = diff_report(
    book([("a", "old")]),
    book([("a", "<script>alert(1)</script>")]),
  )
  let html = html_report(d)
  assert_true(html.contains("&lt;script&gt;"))
  assert_true(!html.contains("<script>alert"))
  assert_true(html.contains("script-src 'none'"))
}

///|
test "large previews are capped without hiding analysis counts" {
  let html = html_report(check_report(book([])))
  assert_true(html.contains("Publication checks"))
  assert_true(html.contains("NBInspect"))
}
