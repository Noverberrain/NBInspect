///|
fn finding(
  code : String,
  severity : String,
  path : String,
  message : String,
) -> Finding {
  { code, severity, path, message, }
}

///|
/// Check publication risks. Execution counters are evidence, not proof of correctness.
/// A supplied policy takes precedence over the legacy limits and enabled options.
pub fn check(
  n : Notebook,
  max_cell_output? : Int = 1048576,
  max_total_output? : Int = 10485760,
  policy? : CheckPolicy,
  enabled? : Array[String] = [
    "FMT001", "FMT002", "OUT001", "EXE001", "EXE002", "ATT001", "SIZE001", "META001",
  ],
) -> Array[Finding] raise InputError {
  if policy is Some(p) {
    validate_policy(p)
    return check(
      n,
      max_cell_output=p.max_cell_output,
      max_total_output=p.max_total_output,
      enabled=p.enabled,
    ).map(fn(f) {
      {
        code: f.code,
        severity: p.severities[f.code],
        path: f.path,
        message: f.message,
      }
    })
  }
  if max_cell_output <= 0 || max_total_output <= 0 {
    raise Invalid("output thresholds must be positive")
  }
  let known = [
    "FMT001", "FMT002", "OUT001", "EXE001", "EXE002", "ATT001", "SIZE001", "META001",
  ]
  for rule in enabled {
    if !known.contains(rule) {
      raise Invalid("unknown rule: " + rule)
    }
  }
  let all = n.findings.copy()
  if !n.compatible {
    all.push(
      finding(
        "FMT001", "error", "/nbformat_minor", "minor version is not verified",
      ),
    )
  }
  let meta = field(n.raw, "metadata")
  if field(meta, "kernelspec") == Json::null() ||
    field(meta, "language_info") == Json::null() {
    all.push(
      finding(
        "META001", "info", "/metadata", "kernel or language metadata is absent",
      ),
    )
  }
  let counts : Map[Int, Bool] = Map([])
  let mut previous = -1
  let mut total : Int64 = 0
  for c in n.cells {
    let path = "/cells/" + c.index.to_string()
    if c.kind == "code" {
      let count = match field(c.raw, "execution_count") {
        Number(v, ..) => v.to_int()
        _ => -1
      }
      if count >= 0 {
        if count < previous || counts.contains(count) {
          all.push(
            finding(
              "EXE002",
              "info",
              path + "/execution_count",
              "execution order is reversed or repeated; review evidence",
            ),
          )
        }
        counts[count] = true
        previous = count
      }
      let outputs = array_at(field(c.raw, "outputs"), path + "/outputs")
      for i, o in outputs {
        let op = path + "/outputs/" + i.to_string()
        if field(o, "output_type") == Json::string("error") {
          all.push(
            finding(
              "OUT001", "warning", op, "saved exception output; may be intentional",
            ),
          )
        }
        if field(o, "output_type") == Json::string("execute_result") &&
          field(o, "execution_count") != field(c.raw, "execution_count") {
          all.push(
            finding(
              "EXE001",
              "warning",
              op + "/execution_count",
              "result counter differs from cell counter",
            ),
          )
        }
      }
      let bytes = @utf8.encode(field(c.raw, "outputs").stringify()).length()
      total += bytes.to_int64()
      if bytes > max_cell_output {
        all.push(
          finding(
            "SIZE001",
            "warning",
            path + "/outputs",
            "encoded output exceeds per-cell threshold",
          ),
        )
      }
    }
    // Literal inline attachment destinations. This is not a full Markdown parser.
    if c.kind == "markdown" || c.kind == "raw" {
      let chunks = c.source.split("attachment:").collect()
      for i = 1; i < chunks.length(); i = i + 1 {
        let b = StringBuilder()
        for ch in chunks[i].iter() {
          if ch == ')' ||
            ch == '>' ||
            ch == '"' ||
            ch == ' ' ||
            ch == '\n' ||
            ch == '\r' {
            break
          }
          b.write_char(ch)
        }
        let name = b.to_string()
        if name != "" {
          let exists = match field(c.raw, "attachments") {
            Object(o) => o.contains(name)
            _ => false
          }
          if !exists {
            all.push(
              finding(
                "ATT001",
                "warning",
                path + "/source",
                "missing literal attachment: " + name,
              ),
            )
          }
        }
      }
    }
  }
  if total > max_total_output.to_int64() {
    all.push(
      finding(
        "SIZE001", "warning", "/cells", "encoded output exceeds total threshold",
      ),
    )
  }
  all.filter(fn(f) { enabled.contains(f.code) })
}

///|
pub fn blocks(
  findings : Array[Finding],
  fail_on? : String = "error",
) -> Bool raise InputError {
  if !["error", "warning", "info"].contains(fail_on) {
    raise Invalid("fail-on must be error, warning or info")
  }
  findings.any(fn(f) {
    f.severity == "error" ||
    (fail_on != "error" && f.severity == "warning") ||
    (fail_on == "info" && f.severity == "info")
  })
}
