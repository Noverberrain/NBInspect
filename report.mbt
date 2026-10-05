///|
fn finding_json(f : Finding) -> Json {
  {
    "code": f.code,
    "severity": f.severity,
    "path": f.path,
    "message": f.message,
  }
}

///|
pub fn check_report(
  n : Notebook,
  fail_on? : String = "error",
) -> Json raise InputError {
  let findings = check(n)
  let blocked = blocks(findings, fail_on~)
  {
    "schema_version": 1,
    "kind": "check",
    "status": if !n.compatible {
      "unsupported"
    } else if blocked {
      "blocked"
    } else {
      "passed"
    },
    "nbformat_minor": n.minor,
    "cell_count": n.cells.length(),
    "findings": findings.map(finding_json),
  }
}

///|
pub fn diff_report(
  a : Notebook,
  b : Notebook,
  view? : String = "all",
) -> Json raise InputError {
  let d = diff(a, b)
  let visible = visible_changes(d, view~)
  let include_cell = fn(c : Cell) {
    view == "all" ||
    c.kind == "code" ||
    (view == "content" && (c.kind == "markdown" || c.kind == "raw"))
  }
  let added = d.matches.added.filter(fn(i) { include_cell(b.cells[i]) })
  let deleted = d.matches.deleted.filter(fn(i) { include_cell(a.cells[i]) })
  let moves = d.matches.pairs.filter(fn(p) {
    p.moved &&
    (include_cell(a.cells[p.before]) || include_cell(b.cells[p.after]))
  })
  let changes = visible.map(fn(c) {
    let lines : Array[Json] = c.lines.map(fn(l) {
      let j : Json = { "operation": l.operation, "text": l.text }
      j
    })
    let j : Json = {
      "before": c.before,
      "after": c.after,
      "category": c.category,
      "old": c.old_value,
      "new": c.new_value,
      "lines": lines,
    }
    j
  })
  let pairs = d.matches.pairs.map(fn(p) {
    let j : Json = {
      "before": p.before,
      "after": p.after,
      "basis": p.basis,
      "score": p.score,
      "moved": p.moved,
    }
    j
  })
  let additions = added.map(fn(i) {
    let j : Json = { "index": i, "cell": b.cells[i].raw }
    j
  })
  let deletions = deleted.map(fn(i) {
    let j : Json = { "index": i, "cell": a.cells[i].raw }
    j
  })
  let total = d.changes.length() +
    d.matches.added.length() +
    d.matches.deleted.length() +
    d.matches.pairs.filter(fn(p) { p.moved }).length() +
    (if d.notebook_changed { 1 } else { 0 })
  let count = visible.length() +
    added.length() +
    deleted.length() +
    moves.length() +
    (if view == "all" && d.notebook_changed { 1 } else { 0 })
  {
    "schema_version": 1,
    "kind": "diff",
    "status": "complete",
    "view": view,
    "total_changes": total,
    "visible_changes": count,
    "matches": pairs,
    "ambiguous_before": d.matches.ambiguous,
    "added": additions,
    "deleted": deletions,
    "changes": changes,
    "notebook": if view == "all" && d.notebook_changed {
      Json::object({ "old": d.old_metadata, "new": d.new_metadata })
    } else {
      Json::null()
    },
  }
}
