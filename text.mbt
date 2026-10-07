///|
fn report_string(value : Json) -> String {
  match value {
    String(s) => s
    _ => value.stringify()
  }
}

///|
pub fn text_report(report : Json) -> String {
  let b = StringBuilder()
  let kind = report_string(field(report, "kind"))
  b.write_string(
    "NBInspect " +
    kind +
    " — " +
    report_string(field(report, "status")) +
    "\n",
  )
  if kind == "check" {
    match field(report, "findings") {
      Array(items) =>
        for item in items {
          b.write_string(
            field(item, "severity").stringify() +
            " " +
            field(item, "code").stringify() +
            " " +
            field(item, "path").stringify() +
            ": " +
            field(item, "message").stringify() +
            "\n",
          )
        }
      _ => ()
    }
  } else if kind == "review" {
    let summary = field(report, "summary")
    b.write_string(
      "Introduced: " +
      field(summary, "introduced").stringify() +
      "; existing: " +
      field(summary, "existing").stringify() +
      "; resolved: " +
      field(summary, "resolved").stringify() +
      "; uncertain: " +
      field(summary, "uncertain").stringify() +
      "\n",
    )
    match field(report, "changes") {
      Array(items) =>
        for item in items {
          let before = field(item, "before")
          let after = field(item, "after")
          let finding = if after == Json::null() { before } else { after }
          b.write_string(
            report_string(field(item, "status")) +
            " " +
            report_string(field(finding, "severity")) +
            " " +
            report_string(field(finding, "code")) +
            " " +
            report_string(field(finding, "path")) +
            ": " +
            report_string(field(finding, "message")),
          )
          if before != Json::null() &&
            after != Json::null() &&
            field(before, "path") != field(after, "path") {
            b.write_string(
              " (path " +
              report_string(field(before, "path")) +
              " -> " +
              report_string(field(after, "path")) +
              ")",
            )
          }
          if field(item, "match_basis") != Json::null() {
            b.write_string(
              " [matched by " + report_string(field(item, "match_basis")) + "]",
            )
          }
          b.write_string("\n")
        }
      _ => ()
    }
  } else {
    b.write_string(
      "All changes: " +
      field(report, "total_changes").stringify() +
      "; visible: " +
      field(report, "visible_changes").stringify() +
      "\n",
    )
    match field(report, "changes") {
      Array(items) =>
        for item in items {
          b.write_string(
            "Cell " +
            field(item, "before").stringify() +
            " -> " +
            field(item, "after").stringify() +
            ": " +
            field(item, "category").stringify() +
            "\n",
          )
          match field(item, "lines") {
            Array(lines) =>
              for line in lines {
                let value = match field(line, "text") {
                  String(s) => s
                  _ => ""
                }
                let preview = if value.length() > 200 {
                  value[:200].to_owned() + "…"
                } else {
                  value
                }
                b.write_string(
                  field(line, "operation").stringify() + ": " + preview + "\n",
                )
              }
            _ => ()
          }
        }
      _ => ()
    }
    b.write_string(
      "Added: " +
      field(report, "added").stringify() +
      "\nDeleted: " +
      field(report, "deleted").stringify() +
      "\n",
    )
  }
  b.to_string()
}
