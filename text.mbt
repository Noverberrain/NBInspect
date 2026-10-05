///|
pub fn text_report(report : Json) -> String {
  let b = StringBuilder()
  b.write_string(
    "NBInspect " +
    field(report, "kind").stringify() +
    " — " +
    field(report, "status").stringify() +
    "\n",
  )
  if field(report, "kind") == Json::string("check") {
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
