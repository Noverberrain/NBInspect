///|
/// One changed notebook from Git raw -z output. Blobs are full object IDs.
pub(all) struct GitChange {
  kind : String
  path : String
  old_path : String
  old_mode : String
  new_mode : String
  before_blob : String
  after_blob : String
}

///|
fn git_object_id(s : String) -> Bool {
  (s.length() == 40 || s.length() == 64) &&
  s.iter().all(fn(c) { ('0' <= c && c <= '9') || ('a' <= c && c <= 'f') })
}

///|
/// Parse the complete raw -z manifest; refuse malformed or over-limit input.
pub fn parse_git_changes(
  raw : String,
  max_files? : Int = 1000,
) -> Array[GitChange] raise InputError {
  if max_files <= 0 || @utf8.encode(raw).length() > 16777216 {
    raise Invalid("Git manifest limit exceeded or invalid file limit")
  }
  if raw == "" {
    return []
  }
  if !raw.has_suffix("\u0000") {
    raise Invalid("Git manifest is not NUL terminated")
  }
  let parts = raw.split("\u0000")
  let changes : Array[GitChange] = []
  let mut next = parts.next()
  while next is Some(header_view) {
    if header_view == "" {
      if parts.next() != None {
        raise Invalid("unexpected empty Git header")
      }
      break
    }
    let header = header_view.split(" ").map(fn(s) { s.to_owned() }).to_array()
    if header.length() != 5 ||
      !header[0].has_prefix(":") ||
      header[0].length() != 7 ||
      header[1].length() != 6 ||
      !git_object_id(header[2]) ||
      !git_object_id(header[3]) {
      raise Invalid("malformed Git raw header")
    }
    let old_mode = header[0][1:].to_owned()
    let new_mode = header[1]
    for mode in [old_mode, new_mode] {
      if !["000000", "100644", "100755", "120000", "160000", "040000"].contains(
          mode,
        ) {
        raise Invalid("unknown Git file mode")
      }
    }
    let status = header[4]
    let renamed = status.has_prefix("R") || status.has_prefix("C")
    if !(["A", "D", "M", "T"].contains(status) ||
      (
        renamed &&
        status.length() > 1 &&
        status.length() <= 4 &&
        status[1:].iter().all(fn(c) { '0' <= c && c <= '9' })
      )) {
      raise Invalid("unsupported Git change status")
    }
    if renamed {
      let mut score = 0
      for digit in status[1:].iter() {
        score = score * 10 + digit.to_int() - '0'.to_int()
      }
      if score > 100 {
        raise Invalid("invalid Git similarity score")
      }
    }
    if (old_mode == "000000") != (status == "A") ||
      (new_mode == "000000") != (status == "D") ||
      header[2].iter().all(fn(c) { c == '0' }) != (status == "A") ||
      header[3].iter().all(fn(c) { c == '0' }) != (status == "D") ||
      header[2].length() != header[3].length() {
      raise Invalid("inconsistent Git file mode or object ID")
    }
    let old_path = match parts.next() {
      Some(path) if path != "" => path.to_owned()
      _ => raise Invalid("missing Git path")
    }
    let path = if renamed {
      match parts.next() {
        Some(path) if path != "" => path.to_owned()
        _ => raise Invalid("missing Git rename destination")
      }
    } else {
      old_path
    }
    let before_notebook = status != "A" &&
      old_path.to_lower().has_suffix(".ipynb")
    let after_notebook = status != "D" && path.to_lower().has_suffix(".ipynb")
    if before_notebook || after_notebook {
      if changes.length() >= max_files {
        raise Invalid("Git notebook count exceeds limit")
      }
      let kind = if !after_notebook {
        "deleted"
      } else if !before_notebook || status.has_prefix("C") {
        "added"
      } else if renamed {
        "renamed"
      } else {
        "modified"
      }
      changes.push({
        kind,
        path,
        old_path,
        old_mode,
        new_mode,
        before_blob: header[2],
        after_blob: header[3],
      })
    }
    next = parts.next()
  }
  changes
}

///|
pub fn git_review_file(change : GitChange, report : Json) -> Json {
  git_entry(change, field(report, "status"), report, Json::null())
}

///|
pub fn git_review_error(change : GitChange, message : String) -> Json {
  git_entry(change, Json::string("error"), Json::null(), Json::string(message))
}

///|
fn git_entry(
  change : GitChange,
  status : Json,
  report : Json,
  error : Json,
) -> Json {
  {
    "change": change.kind,
    "path": change.path,
    "old_path": change.old_path,
    "before_blob": change.before_blob,
    "after_blob": change.after_blob,
    "status": status,
    "report": report,
    "error": error,
  }
}

///|
/// Aggregate per-file decisions; deleted files are recorded without checking old content.
pub fn git_review_report(
  base_ref : String,
  head_ref : String,
  base_commit : String,
  head_commit : String,
  files : Array[Json],
  policy? : CheckPolicy = default_policy(),
) -> Json raise InputError {
  validate_policy(policy)
  let count = fn(key, value) {
    files.filter(fn(f) { field(f, key) == Json::string(value) }).length()
  }
  let errors = count("status", "error")
  let unsupported = count("status", "unsupported")
  let blocked = count("status", "blocked")
  let complete = errors == 0 && unsupported == 0
  let totals : Map[String, Int] = {
    "introduced": 0,
    "existing": 0,
    "resolved": 0,
    "uncertain": 0,
  }
  for file in files {
    let report = field(file, "report")
    if field(report, "kind") == Json::string("review") {
      for key in ["introduced", "existing", "resolved", "uncertain"] {
        if field(field(report, "summary"), key) is Number(n, ..) {
          totals[key] = totals[key] + n.to_int()
        }
      }
    } else if field(report, "kind") == Json::string("check") {
      if field(report, "findings") is Array(a) {
        totals["introduced"] = totals["introduced"] + a.length()
      }
    }
  }
  {
    "schema_version": 1,
    "kind": "git-review",
    "status": if !complete {
      "incomplete"
    } else if blocked > 0 {
      "blocked"
    } else {
      "passed"
    },
    "complete": complete,
    "base_ref": base_ref,
    "head_ref": head_ref,
    "base_commit": base_commit,
    "head_commit": head_commit,
    "policy": policy_json(policy),
    "summary": {
      "files": files.length(),
      "added": count("change", "added"),
      "modified": count("change", "modified"),
      "renamed": count("change", "renamed"),
      "deleted": count("change", "deleted"),
      "passed": count("status", "passed"),
      "blocked": blocked,
      "errors": errors,
      "unsupported": unsupported,
      "introduced": totals["introduced"],
      "existing": totals["existing"],
      "resolved": totals["resolved"],
      "uncertain": totals["uncertain"],
    },
    "files": files,
  }
}

///|
fn git_review_text(report : Json) -> String {
  let b = StringBuilder()
  b.write_string(
    "Commits: " +
    report_string(field(report, "base_commit")) +
    " -> " +
    report_string(field(report, "head_commit")) +
    "\nSummary: " +
    field(report, "summary").stringify() +
    "\n",
  )
  if field(report, "files") is Array(files) {
    for file in files {
      b.write_string(
        "\n" +
        report_string(field(file, "change")) +
        " " +
        field(file, "old_path").stringify() +
        " -> " +
        field(file, "path").stringify() +
        " — " +
        report_string(field(file, "status")) +
        "\n",
      )
      if field(file, "error") != Json::null() {
        b.write_string("Error: " + field(file, "error").stringify() + "\n")
      } else if field(file, "status") == Json::string("deleted") {
        b.write_string(
          "Removed from notebook scope; old content is not checked.\n",
        )
      } else {
        b.write_string(text_report(field(file, "report")))
      }
    }
  }
  b.to_string()
}

///|
fn git_review_html(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "<section><h2>Git review</h2><p>Commits: " +
    escape_html(preview(field(report, "base_commit"))) +
    " → " +
    escape_html(preview(field(report, "head_commit"))) +
    "</p><pre>" +
    escape_html(preview(field(report, "summary"))) +
    "</pre><nav>",
  )
  if field(report, "files") is Array(files) {
    for i, file in files {
      b.write_string(
        "<a href='#git-file-" +
        i.to_string() +
        "'>" +
        escape_html(preview(field(file, "path"))) +
        "</a>",
      )
    }
    b.write_string("</nav>")
    if files.is_empty() {
      b.write_string("<p>No changed notebooks.</p>")
    }
    for i, file in files {
      b.write_string(
        "<article id='git-file-" +
        i.to_string() +
        "'><h3>" +
        escape_html(preview(field(file, "change"))) +
        " · " +
        escape_html(preview(field(file, "path"))) +
        " · " +
        escape_html(preview(field(file, "status"))) +
        "</h3><p>Before: " +
        escape_html(preview(field(file, "old_path"))) +
        "</p>",
      )
      let nested = field(file, "report")
      if field(file, "error") != Json::null() {
        b.write_string(
          "<pre>" + escape_html(preview(field(file, "error"))) + "</pre>",
        )
      } else if field(file, "status") == Json::string("deleted") {
        b.write_string(
          "<p>Removed from notebook scope; old content is not checked.</p>",
        )
      } else if field(nested, "kind") == Json::string("review") {
        let risks = match field(nested, "changes") {
          Array(a) => a
          _ => []
        }
        html_risks(b, risks)
        html_section(b, "Matching evidence", field(nested, "matches"))
        html_section(
          b,
          "Unresolved matching ambiguity",
          field(nested, "ambiguous_before"),
        )
      } else {
        html_section(b, "Publication checks", field(nested, "findings"))
      }
      b.write_string("</article>")
    }
  }
  b.write_string("</section>")
}
