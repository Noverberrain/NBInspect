///|
test "batch aggregates passing blocked failed and unsupported files" {
  let passed = batch_file("a.ipynb", { "status": "passed", "findings": [] })
  let blocked = batch_file("b.ipynb", {
    "status": "blocked",
    "findings": [
      { "severity": "error" },
      { "severity": "warning" },
      { "severity": "info" },
    ],
  })
  let failed = batch_error("broken.ipynb", "invalid input")
  let unsupported = batch_file("future.ipynb", {
    "status": "unsupported",
    "findings": [],
  })
  let report = batch_report(".", [passed, blocked, failed, unsupported], [], [])
  assert_eq(field(report, "status"), Json::string("incomplete"))
  assert_eq(field(report, "complete"), Json::boolean(false))
  let summary = field(report, "summary")
  for
    key in [
      "passed", "blocked", "errors", "unsupported", "error_findings", "warning_findings",
      "info_findings",
    ] {
    assert_eq(field(summary, key), Json::number(1))
  }
  assert_eq(field(summary, "files"), Json::number(4))
  assert_true(text_report(report).contains("broken.ipynb"))
}

///|
test "batch discovery errors take precedence and skipped entries remain visible" {
  let clean = batch_file("clean.ipynb", { "status": "passed", "findings": [] })
  let report = batch_report(
    ".",
    [clean],
    [{ "path": "too-many", "error": "limit exceeded" }],
    [{ "path": ".git", "reason": "excluded directory" }],
    recursive=true,
  )
  assert_eq(field(report, "status"), Json::string("incomplete"))
  assert_eq(field(field(report, "summary"), "scan_errors"), Json::number(1))
  assert_true(html_report(report).contains("limit exceeded"))
  assert_true(html_report(report).contains("excluded directory"))
}

///|
test "batch threshold result and empty scan summary are explicit" {
  let blocked = batch_file("a.ipynb", { "status": "blocked", "findings": [] })
  assert_eq(
    field(batch_report(".", [blocked], [], []), "status"),
    Json::string("blocked"),
  )
  let empty = batch_report(".", [], [], [])
  assert_eq(field(empty, "status"), Json::string("passed"))
  assert_true(html_report(empty).contains("No notebooks found."))
  assert_eq(field(field(empty, "summary"), "files"), Json::number(0))
}

///|
test "batch HTML escapes hostile filenames diagnostics and findings" {
  let file = batch_file("<script>.ipynb", {
    "status": "passed",
    "findings": [
      {
        "code": "OUT001",
        "severity": "warning",
        "path": "/cells/0",
        "message": "<img onerror=alert(1)>",
      },
    ],
  })
  let report = batch_report(
    "<root>",
    [file, batch_error("bad", "<script>alert(1)</script>")],
    [],
    [],
  )
  let html = html_report(report)
  assert_true(html.contains("&lt;script&gt;.ipynb"))
  assert_true(html.contains("&lt;root&gt;"))
  assert_true(html.contains("&lt;img onerror"))
  assert_true(!html.contains("<script>"))
  assert_true(!html.contains("<img "))
  assert_true(html.contains("href='#file-0'"))
  assert_true(html.contains("id='file-0'"))
}
