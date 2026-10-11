///|
fn size_diff_cell(id : String?, source : String, text : String) -> Json {
  let fields : Map[String, Json] = {
    "cell_type": "code",
    "source": source.to_json(),
    "metadata": {},
    "execution_count": null,
    "outputs": [{ "output_type": "stream", "name": "stdout", "text": text }],
  }
  if id is Some(s) {
    fields["id"] = s.to_json()
  }
  Json::object(fields)
}

///|
fn size_diff_number(report : Json, key : String) -> Double raise {
  match profile_get(report, key) {
    Number(n, ..) => n
    _ => fail("missing numeric field: " + key)
  }
}

///|
test "profile diff positive and negative output changes partition totals" {
  let before = profile_book([
    size_diff_cell(Some("a"), "x", "short"),
    size_diff_cell(Some("b"), "y", "longer saved output"),
  ])
  let after = profile_book([
    size_diff_cell(Some("a"), "x", "longer saved output"),
    size_diff_cell(Some("b"), "y", "short"),
  ])
  let r = @nbinspect.profile_diff_report(before, after)
  assert_eq(profile_get(r, "kind"), Json::string("profile-diff"))
  assert_eq(profile_get(r, "measurement"), Json::string("compact-json-utf8"))
  assert_eq(profile_get(r, "matched_count"), Json::number(2))
  let rows = profile_rows(r, "cells")
  assert_true(size_diff_number(rows[0], "delta_bytes") > 0.0)
  assert_true(size_diff_number(rows[1], "delta_bytes") < 0.0)
  let mut cell_delta = 0.0
  for row in rows {
    assert_eq(
      size_diff_number(row, "delta_bytes"),
      size_diff_number(row, "source_delta_bytes") +
      size_diff_number(row, "output_delta_bytes") +
      size_diff_number(row, "attachment_delta_bytes") +
      size_diff_number(row, "other_delta_bytes"),
    )
    cell_delta += size_diff_number(row, "delta_bytes")
    assert_eq(profile_get(row, "basis"), Json::string("id"))
  }
  let summary = profile_get(r, "summary")
  let delta = profile_get(summary, "delta")
  assert_eq(size_diff_number(delta, "notebook_bytes"), 0.0)
  assert_eq(
    size_diff_number(delta, "notebook_bytes"),
    cell_delta + size_diff_number(r, "container_delta_bytes"),
  )
  for
    key in [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ] {
    assert_eq(
      size_diff_number(delta, key),
      size_diff_number(profile_get(summary, "after"), key) -
      size_diff_number(profile_get(summary, "before"), key),
    )
  }
}

///|
test "profile diff insertion offsets do not become moves and all cells are accounted" {
  let before = profile_book([
    size_diff_cell(Some("a"), "a", "a"),
    size_diff_cell(Some("b"), "b", "b"),
  ])
  let after = profile_book([
    size_diff_cell(Some("new"), "new", "large new output"),
    size_diff_cell(Some("a"), "a", "a"),
    size_diff_cell(Some("b"), "b", "b"),
  ])
  let r = @nbinspect.profile_diff_report(before, after)
  assert_eq(profile_get(r, "unmatched_after_count"), Json::number(1))
  assert_eq(profile_get(r, "matched_count"), Json::number(2))
  let rows = profile_rows(r, "cells")
  assert_eq(rows.length(), 3)
  assert_eq(profile_get(rows[0], "kind"), Json::string("unmatched_after"))
  assert_eq(profile_get(rows[0], "before"), Json::null())
  for
    row in rows.filter(fn(row) {
      profile_get(row, "kind") == Json::string("matched")
    }) {
    assert_eq(profile_get(row, "moved"), Json::boolean(false))
    assert_eq(size_diff_number(row, "delta_bytes"), 0.0)
  }
  let reverse = @nbinspect.profile_diff_report(after, before)
  assert_eq(profile_get(reverse, "unmatched_before_count"), Json::number(1))
  assert_true(
    size_diff_number(profile_rows(reverse, "cells")[0], "delta_bytes") < 0.0,
  )
}

///|
test "profile diff moves with edits and ID-free exact/similarity matches" {
  let a = size_diff_cell(Some("a"), "alpha", "small")
  let b = size_diff_cell(Some("b"), "beta", "small")
  let r = @nbinspect.profile_diff_report(
    profile_book([a, b]),
    profile_book([
      size_diff_cell(Some("b"), "beta changed", "larger output value"),
      a,
    ]),
  )
  let rows = profile_rows(r, "cells")
  assert_true(
    rows.any(fn(row) { profile_get(row, "moved") == Json::boolean(true) }),
  )
  assert_true(
    rows.any(row => size_diff_number(row, "output_delta_bytes") > 0.0),
  )
  let no_id = size_diff_cell(None, "one\ntwo\nthree\nfour", "old")
  let exact = @nbinspect.profile_diff_report(
    profile_book([no_id]),
    profile_book([size_diff_cell(None, "one\ntwo\nthree\nfour", "new longer")]),
  )
  assert_eq(
    profile_get(profile_rows(exact, "cells")[0], "basis"),
    Json::string("exact"),
  )
  let similar = @nbinspect.profile_diff_report(
    profile_book([no_id]),
    profile_book([size_diff_cell(None, "one\ntwo\nthree\nfour\nfive", "new")]),
  )
  assert_eq(
    profile_get(profile_rows(similar, "cells")[0], "basis"),
    Json::string("similarity"),
  )
}

///|
test "profile diff repeated content remains unmatched with ambiguity and valid totals" {
  let duplicate = size_diff_cell(None, "same", "output")
  let r = @nbinspect.profile_diff_report(
    profile_book([duplicate, duplicate]),
    profile_book([duplicate, duplicate]),
  )
  assert_eq(profile_get(r, "matched_count"), Json::number(0))
  assert_eq(profile_get(r, "unmatched_before_count"), Json::number(2))
  assert_eq(profile_get(r, "unmatched_after_count"), Json::number(2))
  assert_eq(
    profile_get(r, "ambiguous_before"),
    Json::array([Json::number(0), Json::number(1)]),
  )
  let rows = profile_rows(r, "cells")
  assert_eq(rows.length(), 4)
  for row in rows {
    assert_eq(profile_get(row, "basis"), Json::null())
  }
  assert_eq(
    size_diff_number(
      profile_get(profile_get(r, "summary"), "delta"),
      "notebook_bytes",
    ),
    0.0,
  )
}

///|
test "profile diff MIME unions attachment growth and notebook metadata changes" {
  let old : Json = {
    "cell_type": "markdown",
    "id": "m",
    "source": "same",
    "metadata": {},
    "attachments": { "a": { "image/png": "AAAA" } },
  }
  let new : Json = {
    "cell_type": "markdown",
    "id": "m",
    "source": "same",
    "metadata": {},
    "attachments": { "a": { "image/svg+xml": "<svg>larger</svg>" } },
  }
  let r = @nbinspect.profile_diff_report(
    profile_book([old]),
    profile_book([new]),
  )
  assert_true(
    size_diff_number(profile_rows(r, "cells")[0], "attachment_delta_bytes") >
    0.0,
  )
  let mimes = profile_rows(r, "mime_types")
  assert_eq(mimes.length(), 2)
  let png = mimes.filter(fn(row) {
      profile_get(row, "mime") == Json::string("image/png")
    })[0]
  assert_eq(size_diff_number(png, "delta_bytes"), -6.0)
  assert_eq(size_diff_number(png, "delta_count"), -1.0)
  let svg = mimes.filter(fn(row) {
      profile_get(row, "mime") == Json::string("image/svg+xml")
    })[0]
  assert_true(size_diff_number(svg, "delta_bytes") > 0.0)
  let a = @nbinspect.parse(
    "{\"nbformat\":4,\"nbformat_minor\":5,\"metadata\":{},\"cells\":[]}",
  )
  let b = @nbinspect.parse(
    "{\"nbformat\":4,\"nbformat_minor\":5,\"metadata\":{\"extra\":\"中文\"},\"cells\":[],\"extension\":true}",
  )
  let meta = @nbinspect.profile_diff_report(a, b)
  assert_eq(profile_rows(meta, "cells").length(), 0)
  assert_true(size_diff_number(meta, "container_delta_bytes") > 0.0)
  assert_eq(
    size_diff_number(meta, "container_delta_bytes"),
    size_diff_number(
      profile_get(profile_get(meta, "summary"), "delta"),
      "notebook_bytes",
    ),
  )
}

///|
test "profile diff empty inputs limits unsupported versions and escaped reports" {
  let empty = profile_book([])
  let r = @nbinspect.profile_diff_report(empty, empty)
  assert_eq(profile_rows(r, "cells").length(), 0)
  assert_eq(size_diff_number(r, "container_delta_bytes"), 0.0)
  assert_true(
    @nbinspect.text_report(r).contains("Cells by absolute size change"),
  )
  let hostile : Json = {
    "cell_type": "markdown",
    "id": "<img>",
    "source": "private-source",
    "metadata": {},
    "attachments": { "x": { "<script>": "private-payload" } },
  }
  let html = @nbinspect.html_report(
    @nbinspect.profile_diff_report(empty, profile_book([hostile])),
  )
  assert_true(html.contains("&lt;script&gt;"))
  assert_true(html.contains("&lt;img&gt;"))
  assert_false(html.contains("<script>"))
  assert_false(html.contains("private-payload"))
  assert_false(html.contains("private-source"))
  assert_true(html.contains("script-src 'none'"))
  try @nbinspect.profile_diff_report(empty, profile_book([], minor=6)) catch {
    @nbinspect.Invalid(_) => ()
  } noraise {
    _ => fail("unsupported accepted")
  }
  let n = profile_book([
    size_diff_cell(None, "x", "y"),
    size_diff_cell(None, "z", "w"),
  ])
  try @nbinspect.profile_diff_report(n, n, max_candidates=1) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("candidate budget"))
  } noraise {
    _ => fail("matching limit ignored")
  }
}

///|
test "profile diff resource cap and equal-sized text remain explicit" {
  let empty = profile_book([])
  let outputs = Array::make(
    10001,
    Json::object({ "output_type": "stream", "name": "stdout", "text": "" }),
  )
  let cell : Json = {
    "cell_type": "code",
    "id": "a",
    "source": "",
    "metadata": {},
    "execution_count": null,
    "outputs": outputs,
  }
  try @nbinspect.profile_diff_report(empty, profile_book([cell])) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("resource limit"))
  } noraise {
    _ => fail("resource cap ignored")
  }
  let before = profile_book([size_diff_cell(Some("a"), "x=1", "one")])
  let after = profile_book([size_diff_cell(Some("a"), "x=2", "two")])
  let r = @nbinspect.profile_diff_report(before, after)
  assert_eq(
    size_diff_number(
      profile_get(profile_get(r, "summary"), "delta"),
      "notebook_bytes",
    ),
    0.0,
  )
  assert_eq(profile_rows(r, "cells").length(), 1)
  assert_eq(profile_get(r, "status"), Json::string("complete"))
  assert_false(r.stringify().contains("x=1"))
  assert_true(
    @nbinspect.html_report(r).contains("Equal sizes do not imply equal content"),
  )
}

///|
test "profile diff equal deltas sort by numeric indexes" {
  let cells = Array::makei(12, fn(i) {
    size_diff_cell(Some("cell-" + i.to_string()), "same", "same")
  })
  let n = profile_book(cells)
  let rows = profile_rows(@nbinspect.profile_diff_report(n, n), "cells")
  for i, row in rows {
    assert_eq(profile_get(row, "before_index"), Json::number(i.to_double()))
  }
}
