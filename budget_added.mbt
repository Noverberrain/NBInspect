///|
/// Budget a newly added Notebook from zero stored bytes, including its container.
/// An absent version is distinct from a serialized empty Notebook.
pub fn budget_added_report(
  after : Notebook,
  budget : SizeBudget,
) -> Json raise InputError {
  let profile = profile_report(after)
  let zero : Json = {
    "notebook_bytes": 0,
    "source_bytes": 0,
    "output_bytes": 0,
    "attachment_bytes": 0,
    "other_bytes": 0,
  }
  let rows : Array[Json] = []
  let mut cell_bytes = 0.0
  if field(profile, "cells") is Array(cells) {
    for cell in cells {
      rows.push(profile_diff_row(Json::null(), cell, None))
      cell_bytes += profile_diff_value(cell, "bytes")
    }
  }
  profile_diff_sort(rows, "before_index")
  let mimes : Array[Json] = []
  if field(profile, "mime_types") is Array(values) {
    for item in values {
      mimes.push({
        "mime": field(item, "mime"),
        "before_bytes": 0,
        "after_bytes": field(item, "bytes"),
        "delta_bytes": field(item, "bytes"),
        "before_count": 0,
        "after_count": field(item, "count"),
        "delta_count": field(item, "count"),
      })
    }
  }
  profile_diff_sort(mimes, "mime")
  let summary = field(profile, "summary")
  budget_evaluate(
    {
      "schema_version": 1,
      "kind": "profile-diff",
      "status": "complete",
      "measurement": "compact-json-utf8",
      "before_absent": true,
      "before_cell_count": 0,
      "after_cell_count": after.cells.length(),
      "matched_count": 0,
      "unmatched_before_count": 0,
      "unmatched_after_count": after.cells.length(),
      "ambiguous_before": [],
      "summary": { "before": zero, "after": summary, "delta": summary },
      "container_delta_bytes": Json::number(
        profile_diff_value(summary, "notebook_bytes") - cell_bytes,
      ),
      "cells": rows,
      "mime_types": mimes,
    },
    budget,
  )
}
