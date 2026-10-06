///|
pub(all) struct LineChange {
  operation : String
  text : String
}

///|
pub(all) struct CellChange {
  before : Int
  after : Int
  category : String
  old_value : Json
  new_value : Json
  lines : Array[LineChange]
}

///|
pub(all) struct NotebookDiff {
  matches : MatchResult
  changes : Array[CellChange]
  notebook_changed : Bool
  old_metadata : Json
  new_metadata : Json
}

///|
fn without(value : Json, excluded : Array[String]) -> Json {
  match value {
    Object(o) => {
      let result : Map[String, Json] = Map([])
      for k, v in o {
        if !excluded.contains(k) {
          result[k] = v
        }
      }
      Json::object(result)
    }
    _ => value
  }
}

///|
fn normalize_output(v : Json) -> Json {
  match v {
    Array(a) => Json::array(a.map(normalize_output))
    Object(o) => {
      let result : Map[String, Json] = Map([])
      for key, value in o {
        if key == "text" ||
          key == "traceback" ||
          key.has_prefix("text/") ||
          key.has_prefix("image/") {
          result[key] = match value {
            String(_) | Array(_) =>
              Json::string(text_at(value, key) catch { _ => value.stringify() })
            _ => normalize_output(value)
          }
        } else {
          result[key] = normalize_output(value)
        }
      }
      Json::object(result)
    }
    _ => v
  }
}

///|
pub fn line_diff(
  a : String,
  b : String,
  max_work? : Int = 1000000,
) -> Array[LineChange] raise InputError {
  if max_work <= 0 {
    raise Invalid("text budget must be positive")
  }
  let aa = a.split("\n").map(fn(s) { s.to_owned() }).collect()
  let bb = b.split("\n").map(fn(s) { s.to_owned() }).collect()
  if aa.length() > 10000 ||
    bb.length() > 10000 ||
    (aa.length() + 1).to_int64() * (bb.length() + 1).to_int64() >
    max_work.to_int64() {
    raise Invalid("text diff budget exceeded")
  }
  let table = Array::make(aa.length() + 1, 0).map(fn(_) {
    Array::make(bb.length() + 1, 0)
  })
  for i = aa.length() - 1; i >= 0; i = i - 1 {
    for j = bb.length() - 1; j >= 0; j = j - 1 {
      table[i][j] = if aa[i] == bb[j] {
        table[i + 1][j + 1] + 1
      } else {
        Int::max(table[i + 1][j], table[i][j + 1])
      }
    }
  }
  let result : Array[LineChange] = []
  let mut i = 0
  let mut j = 0
  while i < aa.length() || j < bb.length() {
    if i < aa.length() && j < bb.length() && aa[i] == bb[j] {
      result.push({ operation: "equal", text: aa[i], })
      i += 1
      j += 1
    } else if i < aa.length() &&
      (j == bb.length() || table[i + 1][j] >= table[i][j + 1]) {
      result.push({ operation: "delete", text: aa[i], })
      i += 1
    } else {
      result.push({ operation: "insert", text: bb[j], })
      j += 1
    }
  }
  result
}

///|
pub fn diff(
  a : Notebook,
  b : Notebook,
  max_text_work? : Int = 1000000,
) -> NotebookDiff raise InputError {
  if !a.compatible || !b.compatible {
    raise Invalid("unverified Notebook minor version")
  }
  if a.findings.length() > 0 || b.findings.length() > 0 {
    raise Invalid("fix structural ID errors before comparing")
  }
  let matches = match_cells(a, b)
  let changes : Array[CellChange] = []
  let mut remaining = max_text_work
  for p in matches.pairs {
    let c = a.cells[p.before]
    let d = b.cells[p.after]
    for
      key in [
        "source", "cell_type", "outputs", "attachments", "execution_count", "metadata",
      ] {
      let x = if key == "source" {
        Json::string(c.source)
      } else if key == "outputs" {
        normalize_output(field(c.raw, key))
      } else {
        field(c.raw, key)
      }
      let y = if key == "source" {
        Json::string(d.source)
      } else if key == "outputs" {
        normalize_output(field(d.raw, key))
      } else {
        field(d.raw, key)
      }
      if x != y {
        let lines = if key == "source" {
          let work = (c.source.split("\n").length() + 1).to_int64() *
            (d.source.split("\n").length() + 1).to_int64()
          if work > remaining.to_int64() {
            raise Invalid("aggregate text diff budget exceeded")
          }
          remaining -= work.to_int()
          line_diff(c.source, d.source, max_work=work.to_int())
        } else {
          []
        }
        changes.push({
          before: p.before,
          after: p.after,
          category: if key == "source" {
            c.kind
          } else {
            key
          },
          old_value: x,
          new_value: y,
          lines,
        })
      }
    }
    let excluded = [
      "source", "cell_type", "outputs", "attachments", "execution_count", "metadata",
      "id",
    ]
    let x = without(c.raw, excluded)
    let y = without(d.raw, excluded)
    if x != y {
      changes.push({
        before: p.before,
        after: p.after,
        category: "extensions",
        old_value: x,
        new_value: y,
        lines: [],
      })
    }
    if c.id != d.id {
      changes.push({
        before: p.before,
        after: p.after,
        category: "id",
        old_value: field(c.raw, "id"),
        new_value: field(d.raw, "id"),
        lines: [],
      })
    }
  }
  let old_metadata = without(a.raw, ["cells"])
  let new_metadata = without(b.raw, ["cells"])
  {
    matches,
    changes,
    notebook_changed: old_metadata != new_metadata,
    old_metadata,
    new_metadata,
  }
}

///|
pub fn visible_changes(
  d : NotebookDiff,
  view? : String = "all",
) -> Array[CellChange] raise InputError {
  if view != "all" && view != "code" && view != "content" {
    raise Invalid("view must be all, code or content")
  }
  d.changes.filter(fn(c) {
    view == "all" ||
    c.category == "code" ||
    (view == "content" && (c.category == "markdown" || c.category == "raw"))
  })
}
