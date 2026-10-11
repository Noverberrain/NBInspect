///|
fn profile_diff_value(value : Json, key : String) -> Double {
  match field(value, key) {
    Number(n, ..) => n
    _ => 0.0
  }
}

///|
fn profile_diff_delta(before : Json, after : Json, key : String) -> Json {
  Json::number(profile_diff_value(after, key) - profile_diff_value(before, key))
}

///|
fn profile_diff_index(report : Json, key : String) -> Map[String, Json] {
  let rows : Map[String, Json] = Map([])
  match field(report, key) {
    Array(items) =>
      for item in items {
        rows[report_string(
          field(item, if key == "cells" { "index" } else { "mime" }),
        )] = item
      }
    _ => ()
  }
  rows
}

///|
fn profile_diff_row(before : Json, after : Json, pair : CellMatch?) -> Json {
  {
    "kind": if pair is Some(_) {
      "matched"
    } else if before == Json::null() {
      "unmatched_after"
    } else {
      "unmatched_before"
    },
    "before_index": field(before, "index"),
    "after_index": field(after, "index"),
    "before": before,
    "after": after,
    "basis": match pair {
      Some(p) => Json::string(p.basis)
      None => Json::null()
    },
    "score": match pair {
      Some(p) => Json::number(p.score)
      None => Json::null()
    },
    "moved": match pair {
      Some(p) => Json::boolean(p.moved)
      None => Json::null()
    },
    "before_bytes": Json::number(profile_diff_value(before, "bytes")),
    "after_bytes": Json::number(profile_diff_value(after, "bytes")),
    "delta_bytes": profile_diff_delta(before, after, "bytes"),
    "source_delta_bytes": profile_diff_delta(before, after, "source_bytes"),
    "output_delta_bytes": profile_diff_delta(before, after, "output_bytes"),
    "attachment_delta_bytes": profile_diff_delta(
      before, after, "attachment_bytes",
    ),
    "other_delta_bytes": profile_diff_delta(before, after, "other_bytes"),
  }
}

///|
fn profile_diff_position(row : Json, key : String) -> Double {
  match field(row, key) {
    Number(n, ..) => n
    _ => -1.0
  }
}

///|
fn profile_diff_sort(rows : Array[Json], key : String) -> Unit {
  rows.sort_by(fn(a, b) {
    let aa = profile_diff_value(a, "delta_bytes")
    let bb = profile_diff_value(b, "delta_bytes")
    if aa.abs() != bb.abs() {
      return bb.abs().compare(aa.abs())
    }
    if aa != bb {
      return bb.compare(aa)
    }
    if key == "mime" {
      report_string(field(a, key)).compare(report_string(field(b, key)))
    } else {
      let first = profile_diff_position(a, "before_index").compare(
        profile_diff_position(b, "before_index"),
      )
      if first != 0 {
        first
      } else {
        profile_diff_position(a, "after_index").compare(
          profile_diff_position(b, "after_index"),
        )
      }
    }
  })
}

///|
/// Compare compact JSON UTF-8 storage sizes using existing cell matching.
/// Unpaired cells are one-sided contributions, not proof of insertion/deletion.
/// All cells are included, ordered by absolute byte delta; positive ties first.
/// No media decoding, notebook execution or publication policy is involved.
pub fn profile_diff_report(
  before : Notebook,
  after : Notebook,
  max_candidates? : Int = 1000000,
) -> Json raise InputError {
  let left = profile_report(before)
  let right = profile_report(after)
  let matches = match_cells(before, after, max_candidates~)
  let old_cells = profile_diff_index(left, "cells")
  let new_cells = profile_diff_index(right, "cells")
  let rows : Array[Json] = []
  for pair in matches.pairs {
    rows.push(
      profile_diff_row(
        old_cells[pair.before.to_string()],
        new_cells[pair.after.to_string()],
        Some(pair),
      ),
    )
  }
  for i in matches.deleted {
    rows.push(profile_diff_row(old_cells[i.to_string()], Json::null(), None))
  }
  for i in matches.added {
    rows.push(profile_diff_row(Json::null(), new_cells[i.to_string()], None))
  }
  let mut cell_delta = 0.0
  for row in rows {
    cell_delta += profile_diff_value(row, "delta_bytes")
  }
  profile_diff_sort(rows, "before_index")
  let old_mimes = profile_diff_index(left, "mime_types")
  let new_mimes = profile_diff_index(right, "mime_types")
  let all_mimes : Map[String, Bool] = Map([])
  for key, _ in old_mimes {
    all_mimes[key] = true
  }
  for key, _ in new_mimes {
    all_mimes[key] = true
  }
  let mime_rows : Array[Json] = []
  for mime, _ in all_mimes {
    let old = old_mimes.get(mime).unwrap_or(Json::null())
    let new = new_mimes.get(mime).unwrap_or(Json::null())
    mime_rows.push({
      "mime": mime,
      "before_bytes": Json::number(profile_diff_value(old, "bytes")),
      "after_bytes": Json::number(profile_diff_value(new, "bytes")),
      "delta_bytes": profile_diff_delta(old, new, "bytes"),
      "before_count": Json::number(profile_diff_value(old, "count")),
      "after_count": Json::number(profile_diff_value(new, "count")),
      "delta_count": profile_diff_delta(old, new, "count"),
    })
  }
  profile_diff_sort(mime_rows, "mime")
  let old_summary = field(left, "summary")
  let new_summary = field(right, "summary")
  let delta : Map[String, Json] = Map([])
  for
    key in [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ] {
    delta[key] = profile_diff_delta(old_summary, new_summary, key)
  }
  {
    "schema_version": 1,
    "kind": "profile-diff",
    "status": "complete",
    "measurement": "compact-json-utf8",
    "before_cell_count": before.cells.length(),
    "after_cell_count": after.cells.length(),
    "matched_count": matches.pairs.length(),
    "unmatched_before_count": matches.deleted.length(),
    "unmatched_after_count": matches.added.length(),
    "ambiguous_before": matches.ambiguous,
    "summary": {
      "before": old_summary,
      "after": new_summary,
      "delta": Json::object(delta),
    },
    "container_delta_bytes": Json::number(
      profile_diff_value(new_summary, "notebook_bytes") -
      profile_diff_value(old_summary, "notebook_bytes") -
      cell_delta,
    ),
    "cells": rows,
    "mime_types": mime_rows,
  }
}
