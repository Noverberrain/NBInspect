///|
fn raw_git(status : String, path : String, target? : String = "") -> String {
  let old_mode = if status == "A" { "000000" } else { "100644" }
  let new_mode = if status == "D" { "000000" } else { "100644" }
  let old_id = if status == "A" {
    "0000000000000000000000000000000000000000"
  } else {
    "1111111111111111111111111111111111111111"
  }
  let new_id = if status == "D" {
    "0000000000000000000000000000000000000000"
  } else {
    "2222222222222222222222222222222222222222"
  }
  ":" +
  old_mode +
  " " +
  new_mode +
  " " +
  old_id +
  " " +
  new_id +
  " " +
  status +
  "\u0000" +
  path +
  "\u0000" +
  (if target == "" { "" } else { target + "\u0000" })
}

///|
test "Git raw manifests preserve path bytes and classify changes" {
  let raw = raw_git("A", "课程 space\t\n'&.IPYNB") +
    raw_git("M", "m.ipynb") +
    raw_git("D", "d.ipynb") +
    raw_git("R100", "old.ipynb", target="new.ipynb") +
    raw_git("M", "README.md")
  let changes = parse_git_changes(raw)
  assert_eq(changes.length(), 4)
  assert_eq(changes.map(fn(c) { c.kind }), [
    "added", "modified", "deleted", "renamed",
  ])
  assert_eq(changes[0].path, "课程 space\t\n'&.IPYNB")
  assert_eq(changes[3].old_path, "old.ipynb")
  assert_eq(changes[3].path, "new.ipynb")
}

///|
test "Git rename scope crossings are additions and removals" {
  let changes = parse_git_changes(
    raw_git("R100", "a.txt", target="a.ipynb") +
    raw_git("R100", "b.ipynb", target="b.txt") +
    raw_git("C100", "c.ipynb", target="copy.ipynb"),
  )
  assert_eq(changes.map(fn(c) { c.kind }), ["added", "deleted", "added"])
  assert_eq(parse_git_changes("").length(), 0)
}

///|
test "Git manifests reject malformed records and resource overflow" {
  let valid = raw_git("M", "a.ipynb")
  for
    raw in [
      "x",
      "\u0000",
      valid[:valid.length() - 1].to_owned(),
      valid.replace(old="100644", new="999999"),
      valid.replace(old=" M\u0000", new=" U\u0000"),
      raw_git("R100", "a.ipynb"),
      raw_git("R999", "a.ipynb", target="b.ipynb"),
      valid.replace(old=" M\u0000", new=" A\u0000"),
      raw_git("A", ""),
      valid.replace(old="1111111111111111111111111111111111111111", new="noid"),
    ] {
    try parse_git_changes(raw) catch {
      Invalid(_) => ()
    } noraise {
      _ => fail("malformed manifest accepted")
    }
  }
  try parse_git_changes(valid + valid, max_files=1) catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("file cap ignored")
  }
  try parse_git_changes("", max_files=0) catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("invalid cap ignored")
  }
}

///|
test "Git aggregate counts risks without blocking on existing findings" {
  let before = book([("a", "![missing](attachment:x)")])
  let modified = parse_git_changes(raw_git("M", "m.ipynb"))[0]
  let added = parse_git_changes(raw_git("A", "a.ipynb"))[0]
  let deleted = parse_git_changes(raw_git("D", "d.ipynb"))[0]
  let policy = parse_policy("{\"fail_on\":\"warning\"}")
  let existing = git_review_file(
    modified,
    review_report(before, before, policy~),
  )
  let removed = git_review_file(deleted, { "status": "deleted" })
  let report = git_review_report(
    "base",
    "head",
    "a",
    "b",
    [existing, removed],
    policy~,
  )
  assert_eq(field(report, "status"), Json::string("passed"))
  assert_eq(field(field(report, "summary"), "introduced"), Json::number(0))
  assert_eq(field(field(report, "summary"), "existing"), Json::number(2))
  assert_eq(field(field(report, "summary"), "deleted"), Json::number(1))
  let blocking = git_review_file(added, check_report(before, policy~))
  let report = git_review_report(
    "base",
    "head",
    "a",
    "b",
    [existing, blocking, removed],
    policy~,
  )
  assert_eq(field(report, "status"), Json::string("blocked"))
  assert_eq(field(field(report, "summary"), "introduced"), Json::number(2))
  assert_eq(field(report, "policy"), policy_json(policy))
}

///|
test "Git per-file errors preserve other results and mark incomplete" {
  let change = parse_git_changes(raw_git("A", "a.ipynb"))[0]
  let passed = git_review_file(change, check_report(book([])))
  let failed = git_review_error(change, "invalid notebook")
  let unsupported = git_review_file(change, { "status": "unsupported" })
  let report = git_review_report("b", "h", "a", "z", [
    passed, failed, unsupported,
  ])
  assert_eq(field(report, "complete"), Json::boolean(false))
  assert_eq(field(report, "status"), Json::string("incomplete"))
  assert_eq(field(field(report, "summary"), "passed"), Json::number(1))
  assert_eq(field(field(report, "summary"), "errors"), Json::number(1))
  assert_eq(field(field(report, "summary"), "unsupported"), Json::number(1))
}

///|
test "Git reports escape every path and error and expose matching evidence" {
  let change = parse_git_changes(raw_git("M", "<img src=x>.ipynb"))[0]
  let nested = review_report(book([("a", "x")]), book([("a", "y")]))
  let report = git_review_report("b", "h", "a", "z", [
    git_review_file(change, nested),
    git_review_error(change, "<script>alert(1)</script>"),
  ])
  let html = html_report(report)
  assert_true(html.contains("&lt;img src=x&gt;.ipynb"))
  assert_true(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
  assert_false(html.contains("<script>"))
  assert_true(html.contains("Matching evidence"))
  assert_true(html.contains("href='#git-file-0'"))
  assert_true(text_report(report).contains("Commits: a -> z"))
  let empty = git_review_report("b", "h", "a", "z", [])
  assert_eq(field(empty, "status"), Json::string("passed"))
  assert_true(html_report(empty).contains("No changed notebooks."))
}
