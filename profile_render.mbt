///|
fn profile_text(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "Compact JSON UTF-8 bytes (not original file size or decoded media).\n",
  )
  let summary = field(report, "summary")
  for
    key in [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ] {
    b.write_string(key + ": " + field(summary, key).stringify() + "\n")
  }
  b.write_string("Cells by size (zero-based indexes):\n")
  match field(report, "cells") {
    Array(rows) =>
      for row in rows {
        b.write_string(
          "Cell " +
          field(row, "index").stringify() +
          " [" +
          field(row, "cell_type").stringify() +
          "]: " +
          field(row, "bytes").stringify() +
          " bytes; source " +
          field(row, "source_bytes").stringify() +
          "; outputs " +
          field(row, "output_bytes").stringify() +
          "; attachments " +
          field(row, "attachment_bytes").stringify() +
          "\n",
        )
      }
    _ => ()
  }
  for
    (title, key) in [
      ("MIME payloads", "mime_types"),
      ("Stored resources", "resources"),
    ] {
    b.write_string(title + ":\n")
    match field(report, key) {
      Array(rows) =>
        for row in rows {
          // JSON quoting keeps arbitrary names/control characters on one line.
          b.write_string(row.stringify() + "\n")
        }
      _ => ()
    }
  }
}

///|
fn profile_table(
  b : StringBuilder,
  title : String,
  rows : Json,
  keys : Array[String],
) -> Unit {
  b.write_string(
    "<section><h2>" +
    title +
    "</h2><div style='overflow:auto'><table><thead><tr>",
  )
  for key in keys {
    b.write_string(
      "<th scope='col' style='padding:8px;text-align:left'>" + key + "</th>",
    )
  }
  b.write_string("</tr></thead><tbody>")
  match rows {
    Array(items) =>
      for row in items {
        b.write_string("<tr>")
        for key in keys {
          b.write_string(
            "<td style='padding:8px;border-top:1px solid #ccd4ce;overflow-wrap:anywhere'>" +
            escape_html(report_string(field(row, key))) +
            "</td>",
          )
        }
        b.write_string("</tr>")
      }
    _ => ()
  }
  b.write_string("</tbody></table></div></section>")
}

///|
fn profile_html(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "<section><h2>Notebook size profile</h2><p>Compact JSON UTF-8 bytes, including JSON quoting and escaping. Original whitespace and decoded media sizes are not measured. Cell indexes are zero-based.</p><p>Summary categories partition the notebook size. MIME totals cover stored display/result and attachment values, excluding enclosing keys/separators; stream text and complete error objects appear only in resources. No payload is rendered or decoded.</p></section>",
  )
  profile_table(
    b,
    "Size breakdown (bytes)",
    Json::array([field(report, "summary")]),
    [
      "notebook_bytes", "source_bytes", "output_bytes", "attachment_bytes", "other_bytes",
    ],
  )
  profile_table(b, "Cells by size", field(report, "cells"), [
    "index", "id", "cell_type", "bytes", "source_bytes", "output_bytes", "attachment_bytes",
    "other_bytes",
  ])
  profile_table(b, "MIME payloads", field(report, "mime_types"), [
    "mime", "count", "bytes",
  ])
  profile_table(b, "Stored resources by size", field(report, "resources"), [
    "path", "kind", "mime", "bytes",
  ])
}
