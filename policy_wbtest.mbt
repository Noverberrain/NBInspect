///|
fn invalid_policy(input : String, location : String) -> Unit raise {
  try parse_policy(input) catch {
    Invalid(message) =>
      if !message.contains(location) {
        fail("expected " + location + "; got " + message)
      }
  } noraise {
    _ => fail("invalid policy was accepted")
  }
}

///|
test "empty policy normalizes defaults and preserves existing checks" {
  let p = parse_policy("{}")
  assert_eq(policy_json(p), policy_json(default_policy()))
  let n = book([("a", "![missing](attachment:x.png)")])
  assert_eq(check(n, policy=p).map(finding_json), check(n).map(finding_json))
  assert_eq(field(check_report(n, policy=p), "status"), Json::string("passed"))
  assert_eq(field(check_report(n), "policy"), policy_json(p))
}

///|
test "configuration reports precise field paths for invalid values" {
  let invalid = [
    ("[]", "/: expected object"),
    ("{\"schema_version\":2}", "/schema_version"),
    ("{\"fail_on\":\"fatal\"}", "/fail_on"),
    ("{\"fail_on\":null}", "/fail_on"),
    ("{\"unexpected\":1}", "/unexpected"),
    ("{\"rules\":null}", "/rules"),
    ("{\"rules\":{\"TYPO\":{}}}", "/rules/TYPO"),
    ("{\"rules\":{\"OUT001\":{\"enable\":false}}}", "/rules/OUT001/enable"),
    (
      "{\"rules\":{\"OUT001\":{\"enabled\":\"false\"}}}", "/rules/OUT001/enabled",
    ),
    (
      "{\"rules\":{\"OUT001\":{\"severity\":\"fatal\"}}}", "/rules/OUT001/severity",
    ),
    ("{\"limits\":{\"unknown\":1}}", "/limits/unknown"),
    (
      "{\"limits\":{\"max_cell_output_bytes\":0}}", "/limits/max_cell_output_bytes",
    ),
    (
      "{\"limits\":{\"max_cell_output_bytes\":1.5}}", "/limits/max_cell_output_bytes",
    ),
    (
      "{\"limits\":{\"max_total_output_bytes\":2147483648}}", "/limits/max_total_output_bytes",
    ),
    (
      "{\"limits\":{\"max_total_output_bytes\":null}}", "/limits/max_total_output_bytes",
    ),
    ("{", "invalid JSON"),
  ]
  for (input, path) in invalid {
    invalid_policy(input, path)
  }
}

///|
test "format checks cannot be disabled or downgraded in policy files" {
  invalid_policy(
    "{\"rules\":{\"FMT001\":{\"enabled\":false}}}", "/rules/FMT001",
  )
  invalid_policy(
    "{\"rules\":{\"FMT002\":{\"severity\":\"warning\"}}}", "/rules/FMT002",
  )
  let n = parse(
    "{\"nbformat\":4,\"nbformat_minor\":6,\"metadata\":{},\"cells\":[]}",
  )
  assert_eq(
    field(check_report(n, policy=parse_policy("{}")), "status"),
    Json::string("unsupported"),
  )
}

///|
test "policy enables severity remapping and optional-rule disabling" {
  let output : Json = {
    "output_type": "error",
    "ename": "Demo",
    "evalue": "demo",
    "traceback": [],
  }
  let n = risk_code_book([output])
  let strict = parse_policy("{\"rules\":{\"OUT001\":{\"severity\":\"error\"}}}")
  assert_eq(
    check(n, policy=strict).filter(fn(f) { f.code == "OUT001" })[0].severity,
    "error",
  )
  assert_eq(
    field(check_report(n, policy=strict), "status"),
    Json::string("blocked"),
  )
  let disabled = parse_policy(
    "{\"rules\":{\"OUT001\":{\"enabled\":false},\"META001\":{\"enabled\":false}}}",
  )
  assert_eq(check(n, policy=disabled).length(), 0)
  assert_eq(
    field(check_report(n, policy=disabled), "status"),
    Json::string("passed"),
  )
}

///|
test "policy output thresholds use serialized UTF8 bytes and affect review" {
  let n = parse(fixture(""))
  let tiny = parse_policy(
    "{\"limits\":{\"max_cell_output_bytes\":1,\"max_total_output_bytes\":1},\"rules\":{\"SIZE001\":{\"severity\":\"error\"}}}",
  )
  assert_eq(
    check(n, policy=tiny).filter(fn(f) { f.code == "SIZE001" }).length(),
    2,
  )
  let review = review_report(n, n, policy=tiny)
  assert_eq(field(field(review, "summary"), "introduced"), Json::number(0))
  assert_eq(field(review, "status"), Json::string("passed"))
}

///|
test "review applies identical policy to both versions and only blocks introduced risks" {
  let a = book([("a", "plain")])
  let b = book([("a", "![missing](attachment:x.png)")])
  let policy = parse_policy("{\"rules\":{\"ATT001\":{\"severity\":\"error\"}}}")
  assert_eq(
    field(review_report(a, b, policy~), "status"),
    Json::string("blocked"),
  )
  assert_eq(
    field(review_report(b, b, policy~), "status"),
    Json::string("passed"),
  )
  assert_eq(
    field(field(review_report(b, b, policy~), "summary"), "existing"),
    Json::number(2),
  )
  let disabled = parse_policy("{\"rules\":{\"ATT001\":{\"enabled\":false}}}")
  assert_eq(
    field(field(review_report(a, b, policy=disabled), "summary"), "introduced"),
    Json::number(0),
  )
}

///|
test "explicit threshold overrides policy and is recorded in every report" {
  let n = book([("a", "![missing](attachment:x.png)")])
  let policy = parse_policy("{\"fail_on\":\"warning\"}")
  assert_eq(field(check_report(n, policy~), "status"), Json::string("blocked"))
  let report = check_report(n, policy~, fail_on="error")
  assert_eq(field(report, "status"), Json::string("passed"))
  assert_eq(field(field(report, "policy"), "fail_on"), Json::string("error"))
  let file = batch_file("a.ipynb", report)
  let batch = batch_report(
    ".",
    [file],
    [],
    [],
    policy=policy.with_fail_on("error"),
  )
  assert_eq(field(batch, "policy"), field(report, "policy"))
  assert_true(text_report(batch).contains("Effective policy:"))
  assert_true(html_report(batch).contains("Effective publication policy"))
}

///|
test "checks reject policies whose shared collections were mutated" {
  let n = book([])
  let policy = default_policy()
  policy.severities["OUT001"] = "fatal"
  try check(n, policy~) catch {
    Invalid(message) => assert_true(message.contains("OUT001"))
  } noraise {
    _ => fail("invalid mutated severity was accepted")
  }
  let policy = default_policy()
  policy.severities["FMT002"] = "info"
  try check(n, policy~) catch {
    Invalid(message) => assert_true(message.contains("FMT002"))
  } noraise {
    _ => fail("format rule was downgraded through a shared map")
  }
}
