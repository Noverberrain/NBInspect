///|
fn escape_html(s : String) -> String {
  let b = StringBuilder()
  for c in s.iter() {
    match c {
      '&' => b.write_string("&amp;")
      '<' => b.write_string("&lt;")
      '>' => b.write_string("&gt;")
      '"' => b.write_string("&quot;")
      '\'' => b.write_string("&#39;")
      _ => b.write_char(c)
    }
  }
  b.to_string()
}

///|
fn preview(v : Json) -> String {
  let s = match v {
    String(s) => s
    _ => v.stringify(indent=2)
  }
  if s.length() > 4096 {
    s[:4096].to_owned() + "\n[…display truncated; comparison is complete]"
  } else {
    s
  }
}

///|
fn html_section(b : StringBuilder, title : String, items : Json) -> Unit {
  b.write_string("<section><h2>" + title + "</h2>")
  match items {
    Array(a) =>
      if a.length() == 0 {
        b.write_string("<p class='muted'>No entries.</p>")
      } else {
        for item in a {
          b.write_string("<article>")
          let category = field(item, "category")
          if category != Json::null() {
            b.write_string(
              "<h3>Cell " +
              escape_html(field(item, "before").stringify()) +
              " → " +
              escape_html(field(item, "after").stringify()) +
              " · " +
              escape_html(preview(category)) +
              "</h3>",
            )
          }
          match field(item, "lines") {
            Array(lines) =>
              if lines.length() > 0 {
                b.write_string("<pre class='lines'>")
                for line in lines {
                  let op = match field(line, "operation") {
                    String(s) => s
                    _ => "equal"
                  }
                  b.write_string(
                    "<span class='" +
                    escape_html(op) +
                    "'>" +
                    escape_html(op) +
                    "  " +
                    escape_html(preview(field(line, "text"))) +
                    "</span>\n",
                  )
                }
                b.write_string("</pre>")
              } else {
                b.write_string(
                  "<details><summary>Inspect data change</summary><div class='columns'><pre>" +
                  escape_html(preview(field(item, "old"))) +
                  "</pre><pre>" +
                  escape_html(preview(field(item, "new"))) +
                  "</pre></div></details>",
                )
              }
            _ => b.write_string("<pre>" + escape_html(preview(item)) + "</pre>")
          }
          b.write_string("</article>")
        }
      }
    _ => b.write_string("<pre>" + escape_html(preview(items)) + "</pre>")
  }
  b.write_string("</section>")
}

///|
fn html_risks(b : StringBuilder, items : Array[Json]) -> Unit {
  b.write_string("<section><h2>Risk changes</h2>")
  if items.is_empty() {
    b.write_string("<p class='muted'>No risks in this view.</p>")
  }
  for item in items {
    b.write_string(
      "<article><h3>" +
      escape_html(preview(field(item, "status"))) +
      "</h3><div class='columns'>",
    )
    for side in ["before", "after"] {
      let finding = field(item, side)
      b.write_string("<div><h4>" + side + "</h4>")
      if finding == Json::null() {
        b.write_string("<p class='muted'>No finding.</p>")
      } else {
        b.write_string(
          "<p><strong>" +
          escape_html(preview(field(finding, "code"))) +
          "</strong> · " +
          escape_html(preview(field(finding, "severity"))) +
          "</p><pre>" +
          escape_html(preview(field(finding, "path"))) +
          "\n" +
          escape_html(preview(field(finding, "message"))) +
          "</pre>",
        )
      }
      b.write_string("</div>")
    }
    b.write_string(
      "</div><p class='muted'>Match basis: " +
      escape_html(preview(field(item, "match_basis"))) +
      "</p></article>",
    )
  }
  b.write_string("</section>")
}

///|
/// Standalone report. Notebook payloads are escaped text; no remote resources.
pub fn html_report(report : Json, risk_status? : String = "all") -> String {
  let selected = match risk_status {
    "introduced" | "existing" | "resolved" | "uncertain" => risk_status
    _ => "all"
  }
  let risks = match field(report, "changes") {
    Array(items) =>
      items.filter(fn(item) {
        selected == "all" || field(item, "status") == Json::string(selected)
      })
    _ => []
  }
  let b = StringBuilder()
  b.write_string(
    "<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; script-src 'none'\"><title>NBInspect report</title>",
  )
  b.write_string(
    "<style>body{margin:0;background:#f3f1e9;color:#172e2a;font:16px Georgia,serif}main{max-width:1100px;margin:auto;padding:48px 24px}header{border-top:8px solid #174f42;border-bottom:1px solid #9faea6;padding:28px 0}h1{font-size:54px;letter-spacing:-2px;margin:12px 0}h2{font-size:26px}h3,summary{font:15px Consolas,monospace}nav a{color:#174f42;margin-right:20px}section{margin:32px 0}article{border-top:1px solid #ccd4ce;padding:16px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.7 Consolas,monospace;background:#fffdf7;padding:16px;max-height:420px;overflow:auto}.columns{display:grid;grid-template-columns:1fr 1fr;gap:12px}.delete{display:block;background:#fae1d9;color:#853524}.insert{display:block;background:#dceede;color:#285b37}.muted{color:#5f7268}.stats{font:18px Consolas,monospace}summary{cursor:pointer;padding:12px;border:1px solid #ccd4ce}footer{border-top:1px solid #9faea6;padding:20px 0}@media(max-width:700px){.columns{grid-template-columns:1fr}h1{font-size:38px}}</style><main>",
  )
  b.write_string(
    "<header><p>NOTEBOOK REVIEW / OFFLINE REPORT</p><h1>NBInspect</h1><p class='stats'>" +
    escape_html(preview(field(report, "kind"))) +
    " · " +
    escape_html(preview(field(report, "status"))) +
    "</p>",
  )
  if field(report, "kind") == Json::string("diff") {
    b.write_string(
      "<p>All changes: " +
      escape_html(field(report, "total_changes").stringify()) +
      " · Visible: " +
      escape_html(field(report, "visible_changes").stringify()) +
      " · View: " +
      escape_html(preview(field(report, "view"))) +
      "</p>",
    )
  }
  if field(report, "kind") == Json::string("review") {
    let summary = field(report, "summary")
    b.write_string(
      "<p>Introduced: " +
      escape_html(field(summary, "introduced").stringify()) +
      " · Existing: " +
      escape_html(field(summary, "existing").stringify()) +
      " · Resolved: " +
      escape_html(field(summary, "resolved").stringify()) +
      " · Uncertain: " +
      escape_html(field(summary, "uncertain").stringify()) +
      "</p>",
    )
    b.write_string(
      "<p>Risk filter: " +
      escape_html(selected) +
      " · Visible risks: " +
      risks.length().to_string() +
      "</p><p class='muted'>Only introduced findings at the blocking threshold affect status. Existing and uncertain risks still need review.</p>",
    )
  }
  b.write_string(
    "</header><nav><a href='#content'>Changes</a><a href='#evidence'>Evidence</a></nav><div id='content'>",
  )
  if field(report, "kind") == Json::string("check") {
    html_section(b, "Publication checks", field(report, "findings"))
  } else if field(report, "kind") == Json::string("review") {
    html_risks(b, risks)
  } else {
    html_section(b, "Cell changes", field(report, "changes"))
    html_section(b, "Added cells", field(report, "added"))
    html_section(b, "Deleted cells", field(report, "deleted"))
    if field(report, "notebook") != Json::null() {
      html_section(b, "Notebook metadata", field(report, "notebook"))
    }
  }
  b.write_string("</div><div id='evidence'>")
  if field(report, "kind") == Json::string("diff") ||
    field(report, "kind") == Json::string("review") {
    html_section(b, "Matching evidence", field(report, "matches"))
    html_section(
      b,
      "Unresolved matching ambiguity",
      field(report, "ambiguous_before"),
    )
  }
  b.write_string(
    "</div><footer>Static analysis. Execution records do not prove reproducibility. Large data previews are shortened for display; reported counts use the complete comparison.</footer></main></html>",
  )
  b.to_string()
}
