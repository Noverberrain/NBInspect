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

///|
test "risk HTML filtering keeps summary and evidence complete and escapes findings" {
  let changes : Array[Json] = []
  for status in ["introduced", "existing", "resolved", "uncertain"] {
    let finding : Json = {
      "code": "OUT001",
      "severity": "warning",
      "path": "<path>",
      "message": status + "<script>alert(1)</script>",
    }
    changes.push({
      "status": status,
      "before": if status == "introduced" {
        Json::null()
      } else {
        finding
      },
      "after": if status == "resolved" {
        Json::null()
      } else {
        finding
      },
      "match_basis": "<basis>",
    })
  }
  let report : Json = {
    "kind": "review",
    "status": "passed",
    "summary": { "introduced": 1, "existing": 1, "resolved": 1, "uncertain": 1 },
    "changes": changes,
    "matches": [{ "basis": "id" }],
    "ambiguous_before": [7],
  }
  let original = report.stringify()
  for selected in ["introduced", "existing", "resolved", "uncertain"] {
    let html = html_report(report, risk_status=selected)
    assert_true(html.contains("Visible risks: 1"))
    assert_true(html.contains("Introduced: 1"))
    assert_true(html.contains("Matching evidence"))
    assert_true(html.contains("&lt;basis&gt;"))
    assert_true(html.contains("&lt;path&gt;"))
    assert_true(!html.contains("<script>"))
    for status in ["introduced", "existing", "resolved", "uncertain"] {
      assert_eq(html.contains(status + "&lt;script&gt;"), selected == status)
    }
    assert_eq(report.stringify(), original)
  }
  assert_true(html_report(report).contains("Visible risks: 4"))
  assert_true(
    html_report(report, risk_status="<unknown>").contains("Risk filter: all"),
  )
  assert_true(html_report(report).contains("No finding."))
}

///|
test "empty filtered review has an explicit empty state" {
  let report : Json = {
    "kind": "review",
    "status": "passed",
    "summary": {},
    "changes": [],
    "matches": [],
    "ambiguous_before": [],
  }
  assert_true(
    html_report(report, risk_status="introduced").contains(
      "No risks in this view.",
    ),
  )
}
