///|
pub(all) struct RiskChange {
  status : String
  before : Finding?
  after : Finding?
  match_basis : String?
}

///|
pub(all) struct RiskReview {
  changes : Array[RiskChange]
  matches : MatchResult
}

///|
fn finding_cell(f : Finding, cell_count : Int) -> Int? {
  let parts = f.path.split("/").collect()
  if parts.length() < 3 || parts[1].to_owned() != "cells" {
    return None
  }
  let index = @string.parse_int(parts[2]) catch { _ => -1 }
  if index < 0 || index >= cell_count {
    None
  } else {
    Some(index)
  }
}

///|
fn finding_key(
  f : Finding,
  owner : Int?,
  source_owner : Int?,
  notebook : Notebook,
) -> String {
  let scope = match owner {
    Some(index) => "cell/" + index.to_string()
    None => "document/" + f.path
  }
  let detail = match f.code {
    "ATT001" | "FMT002" => f.message
    "OUT001" =>
      match source_owner {
        Some(index) => {
          let parts = f.path.split("/").collect()
          if parts.length() < 5 || parts[3].to_owned() != "outputs" {
            f.message
          } else {
            let output_index = @string.parse_int(parts[4]) catch { _ => -1 }
            match field(notebook.cells[index].raw, "outputs") {
              Array(outputs) =>
                if output_index >= 0 && output_index < outputs.length() {
                  let output = outputs[output_index]
                  field(output, "ename").stringify() +
                  "\u0000" +
                  field(output, "evalue").stringify()
                } else {
                  f.message
                }
              _ => f.message
            }
          }
        }
        None => f.message
      }
    _ => ""
  }
  scope + "\u0000" + f.code + "\u0000" + f.severity + "\u0000" + detail
}

///|
/// Compare publication findings across two supported Notebook versions.
/// Unmatched cells of the same kind are uncertain rather than assumed new or gone.
pub fn review_risks(
  before : Notebook,
  after : Notebook,
  max_candidates? : Int = 1000000,
) -> RiskReview raise InputError {
  if !before.compatible || !after.compatible {
    raise Invalid("unverified Notebook minor version")
  }
  let matches = match_cells(before, after, max_candidates~)
  let old_findings = check(before)
  let new_findings = check(after)
  let old_to_new = Array::make(before.cells.length(), -1)
  let new_to_old = Array::make(after.cells.length(), -1)
  let basis = Array::make(after.cells.length(), "")
  for pair in matches.pairs {
    old_to_new[pair.before] = pair.after
    new_to_old[pair.after] = pair.before
    basis[pair.after] = pair.basis
  }

  let unmatched_old : Map[String, Bool] = Map([])
  let unmatched_new : Map[String, Bool] = Map([])
  for i, cell in before.cells {
    if old_to_new[i] < 0 {
      unmatched_old[cell.kind] = true
    }
  }
  for i, cell in after.cells {
    if new_to_old[i] < 0 {
      unmatched_new[cell.kind] = true
    }
  }

  let old_owners = old_findings.map(fn(f) {
    finding_cell(f, before.cells.length())
  })
  let new_owners = new_findings.map(fn(f) {
    finding_cell(f, after.cells.length())
  })
  let buckets : Map[String, Array[Int]] = Map([])
  for i, f in old_findings {
    let key = finding_key(f, old_owners[i], old_owners[i], before)
    match buckets.get(key) {
      Some(indices) => {
        indices.push(i)
        buckets[key] = indices
      }
      None => buckets[key] = [i]
    }
  }

  let consumed = Array::make(old_findings.length(), false)
  let cursors : Map[String, Int] = Map([])
  let changes : Array[RiskChange] = []
  for i, f in new_findings {
    let mapped_owner = match new_owners[i] {
      Some(index) => Some(new_to_old[index])
      None => None
    }
    let key = finding_key(f, mapped_owner, new_owners[i], after)
    let mut prior = -1
    match buckets.get(key) {
      Some(indices) => {
        let cursor = cursors.get(key).unwrap_or(0)
        if cursor < indices.length() {
          prior = indices[cursor]
          cursors[key] = cursor + 1
        }
      }
      None => ()
    }
    let match_basis = match new_owners[i] {
      Some(index) =>
        if new_to_old[index] >= 0 {
          Some(basis[index])
        } else {
          None
        }
      None => None
    }
    if prior >= 0 {
      consumed[prior] = true
      changes.push({
        status: "existing",
        before: Some(old_findings[prior]),
        after: Some(f),
        match_basis,
      })
    } else {
      let uncertain = match new_owners[i] {
        Some(index) =>
          new_to_old[index] < 0 &&
          unmatched_old.contains(after.cells[index].kind)
        None => false
      }
      changes.push({
        status: if uncertain {
          "uncertain"
        } else {
          "introduced"
        },
        before: None,
        after: Some(f),
        match_basis,
      })
    }
  }
  for i, f in old_findings {
    if !consumed[i] {
      let uncertain = match old_owners[i] {
        Some(index) =>
          old_to_new[index] < 0 &&
          unmatched_new.contains(before.cells[index].kind)
        None => false
      }
      changes.push({
        status: if uncertain {
          "uncertain"
        } else {
          "resolved"
        },
        before: Some(f),
        after: None,
        match_basis: None,
      })
    }
  }
  { changes, matches, }
}
