///|
fn stale_test_cell(
  id : String?,
  source : Json,
  outputs : Array[Json],
  count? : Int = 1,
  kind? : String = "code",
) -> Json {
  let fields : Map[String, Json] = {
    "cell_type": kind.to_json(),
    "source": source,
    "metadata": {},
  }
  if id is Some(value) {
    fields["id"] = value.to_json()
  }
  if kind == "code" {
    fields["outputs"] = Json::array(outputs)
    fields["execution_count"] = count.to_json()
  }
  Json::object(fields)
}

///|
fn stale_test_rows(report : Json) -> Array[Json] {
  profile_rows(report, "changes").filter(fn(row) {
    profile_get(profile_get(row, "after"), "code") == Json::string("OUT002")
  })
}

///|
test "stale output hint is introduced info with positions and no copied payload" {
  let outputs : Array[Json] = [
    {
      "output_type": "stream",
      "name": "stdout",
      "text": "private saved output",
    },
  ]
  let a = profile_book([stale_test_cell(Some("a"), "print(1)", outputs)])
  let b = profile_book([stale_test_cell(Some("a"), "print(2)", outputs)])
  let r = @nbinspect.review_report(a, b)
  let row = stale_test_rows(r)[0]
  assert_eq(stale_test_rows(r).length(), 1)
  assert_eq(profile_get(row, "status"), Json::string("introduced"))
  assert_eq(profile_get(row, "before"), Json::null())
  assert_eq(
    profile_get(profile_get(row, "after"), "severity"),
    Json::string("info"),
  )
  assert_eq(profile_get(r, "status"), Json::string("passed"))
  let evidence = profile_get(row, "evidence")
  assert_eq(
    profile_get(evidence, "before_source_path"),
    Json::string("/cells/0/source"),
  )
  assert_eq(
    profile_get(evidence, "after_outputs_path"),
    Json::string("/cells/0/outputs"),
  )
  assert_eq(profile_get(evidence, "match_basis"), Json::string("id"))
  assert_true(!row.stringify().contains("private saved output"))
  assert_true(@nbinspect.html_report(r).contains("Saved output evidence"))
  assert_true(@nbinspect.text_report(r).contains("before_source_path"))
  assert_true(
    profile_get(profile_get(row, "after"), "message")
    .stringify()
    .contains("does not prove"),
  )
}

///|
test "stale output excludes same normalized code changed cleared and empty output" {
  let out : Array[Json] = [
    { "output_type": "stream", "name": "stdout", "text": "same" },
  ]
  let a = profile_book([
    stale_test_cell(
      Some("a"),
      Json::array([Json::string("print(1)"), Json::string("\n")]),
      out,
    ),
  ])
  let same = profile_book([stale_test_cell(Some("a"), "print(1)\n", out)])
  assert_eq(stale_test_rows(@nbinspect.review_report(a, same)).length(), 0)
  let changed : Array[Json] = [
    { "output_type": "stream", "name": "stdout", "text": "different" },
  ]
  for outputs in [changed, []] {
    let b = profile_book([stale_test_cell(Some("a"), "print(2)", outputs)])
    assert_eq(stale_test_rows(@nbinspect.review_report(a, b)).length(), 0)
  }
  let empty = profile_book([stale_test_cell(Some("a"), "print(1)", [])])
  let changedEmpty = profile_book([stale_test_cell(Some("a"), "print(2)", [])])
  assert_eq(
    stale_test_rows(@nbinspect.review_report(empty, changedEmpty)).length(),
    0,
  )
  let md1 = profile_book([
    stale_test_cell(Some("a"), "old", [], kind="markdown"),
  ])
  let md2 = profile_book([
    stale_test_cell(Some("a"), "new", [], kind="markdown"),
  ])
  assert_eq(stale_test_rows(@nbinspect.review_report(md1, md2)).length(), 0)
}

///|
test "stale output policy disables or blocks only introduced hints" {
  let out : Array[Json] = [
    {
      "output_type": "display_data",
      "data": { "text/plain": "same" },
      "metadata": {},
    },
  ]
  let a = profile_book([stale_test_cell(Some("a"), "a", out)])
  let b = profile_book([stale_test_cell(Some("a"), "b", out)])
  let off = @nbinspect.parse_policy(
    "{\"rules\":{\"OUT002\":{\"enabled\":false}}}",
  )
  assert_eq(
    stale_test_rows(@nbinspect.review_report(a, b, policy=off)).length(),
    0,
  )
  let strict = @nbinspect.parse_policy(
    "{\"rules\":{\"OUT002\":{\"severity\":\"error\"}}}",
  )
  assert_eq(
    profile_get(@nbinspect.review_report(a, b, policy=strict), "status"),
    Json::string("blocked"),
  )
  assert_eq(
    stale_test_rows(@nbinspect.review_report(b, b, policy=strict)).length(),
    0,
  )
  assert_true(
    !profile_rows(@nbinspect.check_report(b, policy=strict), "findings").any(fn(
      f,
    ) {
      profile_get(f, "code") == Json::string("OUT002")
    }),
  )
}

///|
test "stale output moved cells and new execution counts retain cautious evidence" {
  let out : Array[Json] = [
    { "output_type": "stream", "name": "stdout", "text": "same" },
  ]
  let a = profile_book([
    stale_test_cell(Some("a"), "a", out),
    stale_test_cell(Some("b"), "b", []),
  ])
  let b = profile_book([
    stale_test_cell(Some("b"), "b", []),
    stale_test_cell(Some("a"), "changed", out, count=2),
  ])
  let row = stale_test_rows(@nbinspect.review_report(a, b))[0]
  let evidence = profile_get(row, "evidence")
  assert_eq(profile_get(evidence, "before_cell"), Json::number(0))
  assert_eq(profile_get(evidence, "after_cell"), Json::number(1))
  assert_eq(profile_get(evidence, "before_execution_count"), Json::number(1))
  assert_eq(profile_get(evidence, "after_execution_count"), Json::number(2))
}

///|
test "stale output similarity is uncertain and ambiguous pairs are not invented" {
  let out : Array[Json] = [
    { "output_type": "stream", "name": "stdout", "text": "same" },
  ]
  let a = profile_book(
    [
      stale_test_cell(
        None,
        "setup\nload\ncompute\ncheck\nprint(value + 1)",
        out,
      ),
    ],
    minor=4,
  )
  let b = profile_book(
    [
      stale_test_cell(
        None,
        "setup\nload\ncompute\ncheck\nprint(value + 2)",
        out,
      ),
    ],
    minor=4,
  )
  let strict = @nbinspect.parse_policy(
    "{\"rules\":{\"OUT002\":{\"severity\":\"error\"}}}",
  )
  let r = @nbinspect.review_report(a, b, policy=strict)
  let row = stale_test_rows(r)[0]
  assert_eq(profile_get(row, "status"), Json::string("uncertain"))
  assert_eq(profile_get(row, "match_basis"), Json::string("similarity"))
  assert_eq(profile_get(r, "status"), Json::string("passed"))
  let duplicate = profile_book(
    [
      stale_test_cell(
        None,
        "setup\nload\ncompute\ncheck\nprint(value + 1)",
        out,
      ),
      stale_test_cell(
        None,
        "setup\nload\ncompute\ncheck\nprint(value + 1)",
        out,
      ),
    ],
    minor=4,
  )
  let ambiguous = @nbinspect.review_report(duplicate, b)
  assert_eq(stale_test_rows(ambiguous).length(), 0)
  assert_true(profile_rows(ambiguous, "ambiguous_before").length() > 0)
}

///|
test "stale output compares full output JSON not only rendered text" {
  let one : Array[Json] = [
    {
      "output_type": "execute_result",
      "execution_count": 1,
      "data": { "text/plain": "same", "text/html": "<script>data</script>" },
      "metadata": {},
    },
  ]
  let two : Array[Json] = [
    {
      "output_type": "execute_result",
      "execution_count": 2,
      "data": { "text/plain": "same", "text/html": "<script>data</script>" },
      "metadata": {},
    },
  ]
  let a = profile_book([stale_test_cell(Some("a"), "a", one)])
  let b = profile_book([stale_test_cell(Some("a"), "b", two)])
  assert_eq(stale_test_rows(@nbinspect.review_report(a, b)).length(), 0)
  let same = profile_book([stale_test_cell(Some("a"), "b", one)])
  let html = @nbinspect.html_report(@nbinspect.review_report(a, same))
  assert_true(!html.contains("<script>data"))
  assert_true(!html.contains("data</script>"))
}
