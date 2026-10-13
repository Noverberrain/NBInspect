///|
/// Aggregate independent per-file budgets. Deletions never offset growth.
/// Transport/format failures take precedence over exceeded allowances.
pub fn git_budget_report(
  base_ref : String,
  head_ref : String,
  base_commit : String,
  head_commit : String,
  files : Array[Json],
  budget : SizeBudget,
  staged? : Bool = false,
) -> Json {
  let count = fn(key, value) {
    files.filter(fn(f) { field(f, key) == Json::string(value) }).length()
  }
  let errors = files
    .filter(fn(f) {
      ![
        Json::string("passed"),
        Json::string("blocked"),
        Json::string("deleted"),
      ].contains(field(f, "status"))
    })
    .length()
  let blocked = count("status", "blocked")
  {
    "schema_version": 1,
    "kind": "git-budget",
    "measurement": "compact-json-utf8",
    "scope": "per-changed-notebook",
    "status": if errors > 0 {
      "incomplete"
    } else if blocked > 0 {
      "blocked"
    } else {
      "passed"
    },
    "complete": errors == 0,
    "source": if staged {
      "index"
    } else {
      "commits"
    },
    "base_ref": base_ref,
    "head_ref": head_ref,
    "base_commit": if staged && base_commit == "" {
      Json::null()
    } else {
      Json::string(base_commit)
    },
    "head_commit": if staged {
      Json::null()
    } else {
      Json::string(head_commit)
    },
    "budget": size_budget_json(budget),
    "summary": {
      "files": files.length(),
      "added": count("change", "added"),
      "modified": count("change", "modified"),
      "renamed": count("change", "renamed"),
      "deleted": count("change", "deleted"),
      "passed": count("status", "passed"),
      "blocked": blocked,
      "errors": errors,
    },
    "files": files,
  }
}
