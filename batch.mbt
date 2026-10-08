///|
/// Wrap a successful per-file check for batch reporting.
pub fn batch_file(path : String, report : Json) -> Json {
  {
    "path": path,
    "status": field(report, "status"),
    "report": report,
    "error": Json::null(),
  }
}

///|
/// Keep one failed input without discarding the rest of the batch.
pub fn batch_error(path : String, message : String) -> Json {
  { "path": path, "status": "error", "report": Json::null(), "error": message }
}

///|
/// Aggregate checked files and discovery issues; incomplete scans never pass.
pub fn batch_report(
  root : String,
  files : Array[Json],
  issues : Array[Json],
  skipped : Array[Json],
  recursive? : Bool = false,
  fail_on? : String = "error",
) -> Json {
  let count = fn(status) {
    files.filter(fn(f) { field(f, "status") == Json::string(status) }).length()
  }
  let errors = count("error")
  let unsupported = count("unsupported")
  let blocked = count("blocked")
  let complete = errors == 0 && unsupported == 0 && issues.is_empty()
  let mut warnings = 0
  let mut finding_errors = 0
  let mut infos = 0
  for file in files {
    match field(field(file, "report"), "findings") {
      Array(findings) =>
        for finding in findings {
          match field(finding, "severity") {
            String("error") => finding_errors += 1
            String("warning") => warnings += 1
            String("info") => infos += 1
            _ => ()
          }
        }
      _ => ()
    }
  }
  {
    "schema_version": 1,
    "kind": "batch",
    "status": if !complete {
      "incomplete"
    } else if blocked > 0 {
      "blocked"
    } else {
      "passed"
    },
    "root": root,
    "recursive": recursive,
    "fail_on": fail_on,
    "complete": complete,
    "summary": {
      "files": files.length(),
      "passed": count("passed"),
      "blocked": blocked,
      "errors": errors,
      "unsupported": unsupported,
      "scan_errors": issues.length(),
      "skipped": skipped.length(),
      "error_findings": finding_errors,
      "warning_findings": warnings,
      "info_findings": infos,
    },
    "files": files,
    "scan_errors": issues,
    "skipped": skipped,
  }
}

///|
fn batch_text(report : Json) -> String {
  let b = StringBuilder()
  let summary = field(report, "summary")
  b.write_string(
    "Root: " +
    field(report, "root").stringify() +
    "\nRecursive: " +
    field(report, "recursive").stringify() +
    "; fail-on: " +
    report_string(field(report, "fail_on")) +
    "\n",
  )
  for
    key in [
      "files", "passed", "blocked", "errors", "unsupported", "scan_errors", "skipped",
    ] {
    b.write_string(key + ": " + field(summary, key).stringify() + "  ")
  }
  b.write_string("\n")
  match field(report, "files") {
    Array(files) =>
      for file in files {
        b.write_string(
          "\nFile: " +
          field(file, "path").stringify() +
          " — " +
          report_string(field(file, "status")) +
          "\n",
        )
        if field(file, "report") != Json::null() {
          b.write_string(text_report(field(file, "report")))
        } else {
          b.write_string("Error: " + field(file, "error").stringify() + "\n")
        }
      }
    _ => ()
  }
  b.write_string(
    "\nScan errors: " +
    field(report, "scan_errors").stringify() +
    "\nSkipped: " +
    field(report, "skipped").stringify() +
    "\n",
  )
  b.to_string()
}

///|
fn batch_html(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "<section><h2>Batch summary</h2><p>Root: " +
    escape_html(preview(field(report, "root"))) +
    "</p><pre>" +
    escape_html(preview(field(report, "summary"))) +
    "</pre>",
  )
  b.write_string(
    "<p>Recursive: " +
    escape_html(preview(field(report, "recursive"))) +
    " · Fail-on: " +
    escape_html(preview(field(report, "fail_on"))) +
    "</p>",
  )
  match field(report, "files") {
    Array(files) =>
      if files.is_empty() {
        b.write_string("<p class='muted'>No notebooks found.</p>")
      } else {
        b.write_string("<nav>")
        for i, file in files {
          b.write_string(
            "<a href='#file-" +
            i.to_string() +
            "'>" +
            escape_html(preview(field(file, "path"))) +
            "</a>",
          )
        }
        b.write_string("</nav>")
        for i, file in files {
          b.write_string(
            "<article id='file-" +
            i.to_string() +
            "'><h3>" +
            escape_html(preview(field(file, "path"))) +
            " · " +
            escape_html(preview(field(file, "status"))) +
            "</h3>",
          )
          if field(file, "report") != Json::null() {
            html_section(
              b,
              "Publication checks",
              field(field(file, "report"), "findings"),
            )
          } else {
            b.write_string(
              "<pre>" + escape_html(preview(field(file, "error"))) + "</pre>",
            )
          }
          b.write_string("</article>")
        }
      }
    _ => ()
  }
  b.write_string("</section>")
  html_section(b, "Scan errors", field(report, "scan_errors"))
  html_section(b, "Skipped entries", field(report, "skipped"))
}
