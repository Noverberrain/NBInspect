///|
fn budget_status(
  before : @nbinspect.Notebook,
  after : @nbinspect.Notebook,
  config : String,
) -> Json raise {
  profile_get(
    @nbinspect.budget_report(
      before,
      after,
      @nbinspect.parse_size_budget(config),
    ),
    "status",
  )
}

///|
test "budget exact boundary zero and shrinkage" {
  let before = profile_book([size_diff_cell(Some("a"), "x", "short")])
  let after = profile_book([size_diff_cell(Some("a"), "x", "short123")])
  let exact = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":3,\"max_output_growth_bytes\":3}}",
  )
  let r = @nbinspect.budget_report(before, after, exact)
  assert_eq(profile_get(r, "status"), Json::string("passed"))
  assert_eq(profile_get(r, "kind"), Json::string("budget"))
  assert_eq(profile_get(r, "measurement"), Json::string("compact-json-utf8"))
  assert_eq(profile_rows(r, "checks").length(), 2)
  let blocked = @nbinspect.budget_report(
    before,
    after,
    @nbinspect.parse_size_budget("{\"limits\":{\"max_output_growth_bytes\":2}}"),
  )
  assert_eq(profile_get(blocked, "status"), Json::string("blocked"))
  assert_eq(profile_get(blocked, "exceeded_count"), Json::number(1))
  assert_eq(
    profile_get(profile_rows(blocked, "checks")[0], "excess_bytes"),
    Json::number(1),
  )
  let zero = "{\"limits\":{\"max_notebook_growth_bytes\":0,\"max_output_growth_bytes\":0}}"
  assert_eq(budget_status(before, before, zero), Json::string("passed"))
  assert_eq(budget_status(after, before, zero), Json::string("passed"))
  assert_eq(budget_status(before, after, zero), Json::string("blocked"))
  assert_eq(
    profile_get(r, "comparison"),
    @nbinspect.profile_diff_report(before, after),
  )
}

///|
test "budget category growth cannot hide behind other category shrinkage" {
  let before = profile_book([size_diff_cell(Some("a"), "long source text", "a")])
  let after = profile_book([size_diff_cell(Some("a"), "x", "abc")])
  let r = @nbinspect.budget_report(
    before,
    after,
    @nbinspect.parse_size_budget(
      "{\"limits\":{\"max_notebook_growth_bytes\":0,\"max_output_growth_bytes\":0}}",
    ),
  )
  let checks = profile_rows(r, "checks")
  assert_eq(profile_get(checks[0], "status"), Json::string("passed"))
  assert_eq(profile_get(checks[1], "status"), Json::string("blocked"))
  assert_eq(profile_get(r, "exceeded_count"), Json::number(1))
  let ignored = @nbinspect.budget_report(
    before,
    after,
    @nbinspect.parse_size_budget(
      "{\"limits\":{\"max_notebook_growth_bytes\":0}}",
    ),
  )
  assert_eq(profile_get(ignored, "status"), Json::string("passed"))
  assert_eq(profile_rows(ignored, "checks").length(), 1)
}

///|
test "budget attachment growth and all limits deterministic order" {
  let before = profile_book([
    {
      "cell_type": "markdown",
      "id": "note",
      "source": "a",
      "metadata": {},
      "attachments": { "a": { "image/png": "AAAA" } },
    },
  ])
  let after = profile_book([
    {
      "cell_type": "markdown",
      "id": "note",
      "source": "a",
      "metadata": {},
      "attachments": { "a": { "image/png": "AAAAAAAA" } },
    },
  ])
  let r = @nbinspect.budget_report(
    before,
    after,
    @nbinspect.parse_size_budget(
      "{\"limits\":{\"max_attachment_growth_bytes\":3,\"max_output_growth_bytes\":0,\"max_notebook_growth_bytes\":3}}",
    ),
  )
  let rows = profile_rows(r, "checks")
  assert_eq(profile_get(r, "exceeded_count"), Json::number(2))
  assert_eq(profile_get(rows[0], "metric"), Json::string("notebook_bytes"))
  assert_eq(profile_get(rows[1], "metric"), Json::string("output_bytes"))
  assert_eq(profile_get(rows[2], "metric"), Json::string("attachment_bytes"))
  assert_eq(profile_get(rows[2], "delta_bytes"), Json::number(4))
}

///|
test "budget ambiguity and insertion totals remain visible without identity claims" {
  let n = profile_book([
    size_diff_cell(None, "same", ""),
    size_diff_cell(None, "same", ""),
  ])
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":0}}",
  )
  let r = @nbinspect.budget_report(n, n, budget)
  assert_eq(profile_get(r, "status"), Json::string("passed"))
  let comparison = profile_get(r, "comparison")
  assert_eq(
    profile_get(comparison, "ambiguous_before"),
    Json::array([Json::number(0), Json::number(1)]),
  )
  assert_eq(profile_rows(comparison, "cells").length(), 4)
  let empty = profile_book([])
  assert_eq(
    profile_get(@nbinspect.budget_report(empty, n, budget), "status"),
    Json::string("blocked"),
  )
  assert_eq(
    profile_get(@nbinspect.budget_report(n, empty, budget), "status"),
    Json::string("passed"),
  )
}

///|
test "budget rejects malformed unknown and noninteger configurations" {
  for
    input in [
      "", "{", "[]", "{}", "{\"limits\":{}}", "{\"schema_version\":2,\"limits\":{\"max_output_growth_bytes\":0}}",
      "{\"fail_on\":\"warning\",\"limits\":{\"max_output_growth_bytes\":0}}", "{\"limits\":{\"max_total_output_bytes\":1}}",
      "{\"limits\":{\"max_output_growth_bytes\":-1}}", "{\"limits\":{\"max_output_growth_bytes\":0.5}}",
      "{\"limits\":{\"max_output_growth_bytes\":2147483648}}", "{\"limits\":{\"max_output_growth_bytes\":\"1\"}}",
      "{\"limits\":{\"max_output_growth_bytes\":null}}", "{\"limits\":{\"max_output_growth_bytes\":true}}",
    ] {
    try @nbinspect.parse_size_budget(input) catch {
      @nbinspect.Invalid(message) => assert_true(message.length() > 0)
    } noraise {
      _ => fail("invalid budget accepted: " + input)
    }
  }
  let n = profile_book([])
  let max = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":2147483647}}",
  )
  let row = profile_rows(@nbinspect.budget_report(n, n, max), "checks")[0]
  assert_eq(
    profile_get(row, "allowed_growth_bytes"),
    Json::number(2147483647.0),
  )
  for huge in [" ".repeat(1048577), "😀".repeat(262145)] {
    try @nbinspect.parse_size_budget(huge) catch {
      @nbinspect.Invalid(message) => assert_true(message.contains("1 MiB"))
    } noraise {
      _ => fail("budget byte limit ignored")
    }
  }
}

///|
test "budget forwards input compatibility matching and resource errors" {
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_output_growth_bytes\":0}}",
  )
  let n = profile_book([size_diff_cell(None, "abc", "")])
  let unsupported = profile_book([], minor=6)
  for (first, second) in [(unsupported, n), (n, unsupported)] {
    try @nbinspect.budget_report(first, second, budget) catch {
      @nbinspect.Invalid(_) => ()
    } noraise {
      _ => fail("unsupported accepted")
    }
  }
  let distinct = profile_book([
    size_diff_cell(None, "different", ""),
    size_diff_cell(None, "another", ""),
  ])
  try @nbinspect.budget_report(n, distinct, budget, max_candidates=1) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("candidate budget"))
  } noraise {
    _ => fail("candidate cap ignored")
  }
  let outputs : Array[Json] = []
  for _ in 0..<10001 {
    outputs.push({ "output_type": "stream", "name": "stdout", "text": "" })
  }
  let huge = profile_book([
    {
      "cell_type": "code",
      "source": "",
      "metadata": {},
      "execution_count": null,
      "outputs": Json::array(outputs),
    },
  ])
  for (first, second) in [(huge, n), (n, huge)] {
    try @nbinspect.budget_report(first, second, budget) catch {
      @nbinspect.Invalid(message) =>
        assert_true(message.contains("resource limit"))
    } noraise {
      _ => fail("resource cap ignored")
    }
  }
}

///|
test "budget renders complete escaped evidence and effective allowances" {
  let n = profile_book([
    size_diff_cell(
      Some("<img src=x>"),
      "secret source",
      "<script>secret</script>",
    ),
  ])
  let r = @nbinspect.budget_report(
    n,
    n,
    @nbinspect.parse_size_budget("{\"limits\":{\"max_output_growth_bytes\":0}}"),
  )
  let html = @nbinspect.html_report(r)
  let text = @nbinspect.text_report(r)
  assert_true(html.contains("Growth allowance results"))
  assert_true(html.contains("Effective size budget"))
  assert_true(html.contains("Cell measurements and matching evidence"))
  assert_true(html.contains("&lt;img src=x&gt;"))
  assert_true(!html.contains("<img src=x>"))
  assert_true(!html.contains("secret source"))
  assert_true(!html.contains("<script>secret"))
  assert_true(
    text.contains("output_bytes: delta 0; allowance 0; excess 0 bytes; passed"),
  )
  assert_true(text.contains("Cells by absolute size change"))
}

///|
test "budget UTF-8 and notebook metadata contribute to global allowance" {
  let before : Json = {
    "nbformat": 4,
    "nbformat_minor": 5,
    "metadata": {},
    "cells": [],
  }
  let after : Json = {
    "nbformat": 4,
    "nbformat_minor": 5,
    "metadata": { "标题": "你好😀" },
    "cells": [],
  }
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":0,\"max_output_growth_bytes\":0,\"max_attachment_growth_bytes\":0}}",
  )
  let r = @nbinspect.budget_report(
    @nbinspect.parse(before.stringify()),
    @nbinspect.parse(after.stringify()),
    budget,
  )
  let rows = profile_rows(r, "checks")
  assert_eq(
    profile_get(rows[0], "delta_bytes"),
    Json::number(
      (@utf8.encode(after.stringify()).length() -
      @utf8.encode(before.stringify()).length()).to_double(),
    ),
  )
  assert_eq(profile_get(r, "exceeded_count"), Json::number(1))
  assert_eq(profile_get(rows[1], "status"), Json::string("passed"))
  assert_eq(profile_get(rows[2], "status"), Json::string("passed"))
  assert_eq(
    profile_get(profile_get(r, "comparison"), "container_delta_bytes"),
    profile_get(rows[0], "delta_bytes"),
  )
}
