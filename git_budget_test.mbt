///|
fn budget_git_change(kind : String, path : String) -> @nbinspect.GitChange {
  {
    kind,
    path,
    old_path: path,
    old_mode: "100644",
    new_mode: "100644",
    before_blob: "1".repeat(40),
    after_blob: "2".repeat(40),
  }
}

///|
test "added budget starts at absent zero including empty notebook container" {
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":0}}",
  )
  let empty = profile_book([])
  let r = @nbinspect.budget_added_report(empty, budget)
  assert_eq(profile_get(r, "status"), Json::string("blocked"))
  let c = profile_get(r, "comparison")
  assert_eq(profile_get(c, "before_absent"), Json::boolean(true))
  assert_eq(
    profile_get(
      profile_get(profile_get(c, "summary"), "before"),
      "notebook_bytes",
    ),
    Json::number(0),
  )
  let total = profile_get(
    profile_get(@nbinspect.profile_report(empty), "summary"),
    "notebook_bytes",
  )
  assert_eq(profile_get(profile_rows(r, "checks")[0], "delta_bytes"), total)
  assert_eq(profile_get(c, "container_delta_bytes"), total)
}

///|
test "added budget partitions all bytes and MIME values without identity guesses" {
  let n = profile_book([size_diff_cell(Some("a"), "你好", "stored text")])
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_output_growth_bytes\":0}}",
  )
  let r = @nbinspect.budget_added_report(n, budget)
  let c = profile_get(r, "comparison")
  let p = @nbinspect.profile_report(n)
  assert_eq(
    profile_get(profile_get(c, "summary"), "delta"),
    profile_get(p, "summary"),
  )
  let rows = profile_rows(c, "cells")
  assert_eq(profile_get(rows[0], "kind"), Json::string("unmatched_after"))
  assert_eq(profile_get(rows[0], "before_bytes"), Json::number(0))
  assert_eq(
    size_diff_number(rows[0], "delta_bytes") +
    size_diff_number(c, "container_delta_bytes"),
    size_diff_number(profile_get(p, "summary"), "notebook_bytes"),
  )
  assert_eq(
    profile_get(profile_rows(r, "checks")[0], "delta_bytes"),
    profile_get(profile_get(p, "summary"), "output_bytes"),
  )
}

///|
test "Git budget aggregates independent decisions and errors take precedence" {
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_output_growth_bytes\":0}}",
  )
  let first = profile_book([size_diff_cell(Some("a"), "x", "short")])
  let larger = profile_book([size_diff_cell(Some("a"), "x", "longer")])
  let files = [
    @nbinspect.git_review_file(
      budget_git_change("modified", "growth.ipynb"),
      @nbinspect.budget_report(first, larger, budget),
    ),
    @nbinspect.git_review_file(
      budget_git_change("modified", "shrink.ipynb"),
      @nbinspect.budget_report(larger, first, budget),
    ),
    @nbinspect.git_review_file(budget_git_change("deleted", "removed.ipynb"), {
      "status": "deleted",
    }),
  ]
  let r = @nbinspect.git_budget_report(
    "base",
    "head",
    "1".repeat(40),
    "2".repeat(40),
    files,
    budget,
  )
  assert_eq(profile_get(r, "status"), Json::string("blocked"))
  assert_eq(profile_get(r, "scope"), Json::string("per-changed-notebook"))
  let summary = profile_get(r, "summary")
  assert_eq(profile_get(summary, "files"), Json::number(3))
  assert_eq(profile_get(summary, "blocked"), Json::number(1))
  assert_eq(profile_get(summary, "passed"), Json::number(1))
  assert_eq(profile_get(summary, "deleted"), Json::number(1))
  files.push(
    @nbinspect.git_review_error(
      budget_git_change("added", "broken.ipynb"),
      "cannot read",
    ),
  )
  let failed = @nbinspect.git_budget_report(
    "base", "head", "1", "2", files, budget,
  )
  assert_eq(profile_get(failed, "status"), Json::string("incomplete"))
  assert_eq(profile_get(failed, "complete"), Json::boolean(false))
  assert_eq(
    profile_get(profile_get(failed, "summary"), "blocked"),
    Json::number(1),
  )
}

///|
test "Git budget records staged first commit source and escaped paths" {
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_notebook_growth_bytes\":10000}}",
  )
  let n = profile_book([size_diff_cell(Some("a"), "x", "")])
  let files = [
    @nbinspect.git_review_file(
      budget_git_change("added", "<img>.ipynb"),
      @nbinspect.budget_added_report(n, budget),
    ),
  ]
  let r = @nbinspect.git_budget_report(
    "HEAD",
    "INDEX",
    "",
    "",
    files,
    budget,
    staged=true,
  )
  assert_eq(profile_get(r, "source"), Json::string("index"))
  assert_eq(profile_get(r, "base_commit"), Json::null())
  assert_eq(profile_get(r, "head_commit"), Json::null())
  let html = @nbinspect.html_report(r)
  assert_true(html.contains("Git growth budget"))
  assert_true(html.contains("Growth allowance results"))
  assert_true(html.contains("&lt;img&gt;.ipynb"))
  assert_true(!html.contains("<img>"))
  assert_true(
    @nbinspect.text_report(r).contains("empty tree (first commit) -> INDEX"),
  )
  let empty = @nbinspect.git_budget_report("a", "b", "1", "2", [], budget)
  assert_eq(profile_get(empty, "status"), Json::string("passed"))
  assert_true(@nbinspect.html_report(empty).contains("No changed notebooks"))
}

///|
test "added budget rejects unsupported formats and resource overflow" {
  let budget = @nbinspect.parse_size_budget(
    "{\"limits\":{\"max_output_growth_bytes\":0}}",
  )
  try @nbinspect.budget_added_report(profile_book([], minor=6), budget) catch {
    @nbinspect.Invalid(_) => ()
  } noraise {
    _ => fail("unsupported added notebook accepted")
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
  try @nbinspect.budget_added_report(huge, budget) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("resource limit"))
  } noraise {
    _ => fail("resource cap ignored")
  }
}
