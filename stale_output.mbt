///|
// A two-version heuristic, never evidence that execution did or did not occur.
fn stale_output_changes(
  before : Notebook,
  after : Notebook,
  matches : MatchResult,
  policy : CheckPolicy,
) -> Array[RiskChange] {
  let changes : Array[RiskChange] = []
  if !policy.enabled.contains("OUT002") {
    return changes
  }
  for pair in matches.pairs {
    let old = before.cells[pair.before]
    let new = after.cells[pair.after]
    if !stale_saved_outputs(old, new) {
      continue
    }
    changes.push({
      status: if pair.basis == "similarity" {
        "uncertain"
      } else {
        "introduced"
      },
      before: None,
      after: Some(
        finding(
          "OUT002",
          policy.severities["OUT002"],
          "/cells/" + pair.after.to_string() + "/outputs",
          "code text changed while nonempty saved outputs are identical; verify whether the output still matches the code. This does not prove missing execution or incorrect results",
        ),
      ),
      match_basis: Some(pair.basis),
    })
  }
  changes
}

///|
fn stale_output_evidence(
  before : Notebook,
  after : Notebook,
  matches : MatchResult,
) -> Map[Int, Json] {
  let result : Map[Int, Json] = Map([])
  for pair in matches.pairs {
    if !stale_saved_outputs(before.cells[pair.before], after.cells[pair.after]) {
      continue
    }
    let left = "/cells/" + pair.before.to_string()
    let right = "/cells/" + pair.after.to_string()
    result[pair.after] = {
      "before_cell": pair.before,
      "after_cell": pair.after,
      "before_source_path": left + "/source",
      "after_source_path": right + "/source",
      "before_outputs_path": left + "/outputs",
      "after_outputs_path": right + "/outputs",
      "match_basis": pair.basis,
      "match_score": pair.score,
      "moved": pair.moved,
      "before_execution_count": field(
        before.cells[pair.before].raw,
        "execution_count",
      ),
      "after_execution_count": field(
        after.cells[pair.after].raw,
        "execution_count",
      ),
    }
  }
  result
}

///|
fn stale_change_json(
  change : RiskChange,
  evidence : Map[Int, Json],
  cell_count : Int,
) -> Json {
  let value = risk_change_json(change)
  if change.after is Some(f) && f.code == "OUT002" {
    if finding_cell(f, cell_count) is Some(index) {
      match value {
        Object(o) => {
          o["evidence"] = evidence.get(index).unwrap_or(Json::null())
          return Json::object(o)
        }
        _ => ()
      }
    }
  }
  value
}

///|
fn stale_saved_outputs(old : Cell, new : Cell) -> Bool {
  if old.kind != "code" || new.kind != "code" || old.source == new.source {
    return false
  }
  match field(old.raw, "outputs") {
    Array(outputs) =>
      !outputs.is_empty() && Json::array(outputs) == field(new.raw, "outputs")
    _ => false
  }
}
