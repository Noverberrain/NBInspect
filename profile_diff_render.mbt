///|
fn profile_diff_text(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "Compact JSON UTF-8 byte changes: after - before. Unmatched cells are one-sided contributions; identity is unresolved.\n",
  )
  let summary = field(report, "summary")
  for
    key in [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ] {
    b.write_string(
      key +
      ": " +
      field(field(summary, "before"), key).stringify() +
      " -> " +
      field(field(summary, "after"), key).stringify() +
      "; delta " +
      field(field(summary, "delta"), key).stringify() +
      "\n",
    )
  }
  b.write_string(
    "Container delta: " +
    field(report, "container_delta_bytes").stringify() +
    " bytes\nAmbiguous before indexes: " +
    field(report, "ambiguous_before").stringify() +
    "\n",
  )
  for
    (title, key) in [
      ("Cells by absolute size change", "cells"),
      ("MIME size changes", "mime_types"),
    ] {
    b.write_string(title + ":\n")
    match field(report, key) {
      Array(rows) =>
        for row in rows {
          b.write_string(row.stringify() + "\n")
        }
      _ => ()
    }
  }
}

///|
fn profile_diff_html(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "<section><h2>Notebook size changes</h2><p>Compact JSON UTF-8 bytes: delta = after minus before. Original whitespace and decoded media sizes are not measured. Unmatched cells are one-sided contributions, not confirmed insertions or deletions; matching evidence remains available. Zero-based cell indexes.</p><p>Container delta includes notebook metadata, extension fields and outer JSON structure. Cell deltas plus container delta equal the notebook delta. Equal sizes do not imply equal content.</p></section>",
  )
  let summary = field(report, "summary")
  let rows : Array[Json] = []
  for
    key in [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ] {
    rows.push({
      "category": key,
      "before_bytes": field(field(summary, "before"), key),
      "after_bytes": field(field(summary, "after"), key),
      "delta_bytes": field(field(summary, "delta"), key),
    })
  }
  profile_table(b, "Byte changes by category", Json::array(rows), [
    "category", "before_bytes", "after_bytes", "delta_bytes",
  ])
  b.write_string(
    "<p>Container delta: " +
    escape_html(field(report, "container_delta_bytes").stringify()) +
    " bytes · Ambiguous before indexes: " +
    escape_html(field(report, "ambiguous_before").stringify()) +
    "</p>",
  )
  profile_table(b, "Cells by absolute size change", field(report, "cells"), [
    "kind", "before_index", "after_index", "basis", "score", "moved", "before_bytes",
    "after_bytes", "delta_bytes", "source_delta_bytes", "output_delta_bytes", "attachment_delta_bytes",
    "other_delta_bytes",
  ])
  profile_table(b, "MIME size changes", field(report, "mime_types"), [
    "mime", "before_bytes", "after_bytes", "delta_bytes", "before_count", "after_count",
    "delta_count",
  ])
  // The full cell summaries include escaped IDs and both paths; no payloads.
  html_section(
    b,
    "Cell measurements and matching evidence",
    field(report, "cells"),
  )
}
