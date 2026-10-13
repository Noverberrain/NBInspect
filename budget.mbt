///|
/// Validated growth allowances in compact JSON UTF-8 bytes.
/// Construct with parse_size_budget; at least one allowance is required.
pub struct SizeBudget {
  limits : Map[String, Int]
}

///|
fn budget_metrics() -> Array[(String, String)] {
  [
    ("max_notebook_growth_bytes", "notebook_bytes"),
    ("max_output_growth_bytes", "output_bytes"),
    ("max_attachment_growth_bytes", "attachment_bytes"),
  ]
}

///|
/// Parse a strict, independent schema-v1 growth budget, at most 1 MiB.
/// Omitted limits are not checked; zero allows no positive growth.
pub fn parse_size_budget(input : String) -> SizeBudget raise InputError {
  if @utf8.encode(input).length() > 1048576 {
    raise Invalid("size budget configuration /: exceeds 1 MiB")
  }
  let value = @json.parse(input) catch {
    error =>
      raise Invalid(
        "size budget configuration /: invalid JSON: " + error.to_string(),
      )
  }
  let root = policy_object(value, "", ["schema_version", "limits"])
  match root.get("schema_version") {
    Some(Number(1, ..)) | None => ()
    _ => raise Invalid("configuration /schema_version: expected 1")
  }
  let known : Array[String] = []
  for (key, _) in budget_metrics() {
    known.push(key)
  }
  let raw = policy_object(
    root.get("limits").unwrap_or(Json::null()),
    "/limits",
    known,
  )
  if raw.is_empty() {
    raise Invalid(
      "configuration /limits: at least one growth allowance is required",
    )
  }
  let limits : Map[String, Int] = Map([])
  for (key, value) in raw {
    match value {
      Number(n, ..) =>
        if n >= 0 && n <= 2147483647.0 && n == n.to_int().to_double() {
          limits[key] = n.to_int()
        } else {
          raise Invalid(
            "configuration /limits/" +
            key +
            ": expected nonnegative 32-bit integer",
          )
        }
      _ =>
        raise Invalid(
          "configuration /limits/" + key + ": expected nonnegative integer",
        )
    }
  }
  { limits, }
}

///|
/// Check total growth independently of cell identity and publication rules.
/// Equality passes. Shrinkage passes a nonnegative allowance. Resource/matching
/// errors raise instead of returning a partially evaluated success report.
pub fn budget_report(
  before : Notebook,
  after : Notebook,
  budget : SizeBudget,
  max_candidates? : Int = 1000000,
) -> Json raise InputError {
  let comparison = profile_diff_report(before, after, max_candidates~)
  budget_evaluate(comparison, budget)
}

///|
fn budget_evaluate(
  comparison : Json,
  budget : SizeBudget,
) -> Json raise InputError {
  let known : Array[String] = []
  for (key, _) in budget_metrics() {
    known.push(key)
  }
  if budget.limits.is_empty() {
    raise Invalid("size budget requires at least one allowance")
  }
  for (key, limit) in budget.limits {
    if !known.contains(key) || limit < 0 {
      raise Invalid("invalid size budget allowance: " + key)
    }
  }
  let summary = field(comparison, "summary")
  let checks : Array[Json] = []
  let mut exceeded = 0
  for (key, metric) in budget_metrics() {
    if budget.limits.get(key) is Some(limit) {
      let delta = profile_diff_value(field(summary, "delta"), metric)
      let blocked = delta > limit.to_double()
      if blocked {
        exceeded += 1
      }
      checks.push({
        "limit": key,
        "metric": metric,
        "before_bytes": field(field(summary, "before"), metric),
        "after_bytes": field(field(summary, "after"), metric),
        "delta_bytes": Json::number(delta),
        "allowed_growth_bytes": Json::number(limit.to_double()),
        "excess_bytes": Json::number(
          if blocked {
            delta - limit.to_double()
          } else {
            0.0
          },
        ),
        "status": if blocked {
          "blocked"
        } else {
          "passed"
        },
      })
    }
  }
  {
    "schema_version": 1,
    "kind": "budget",
    "status": if exceeded > 0 {
      "blocked"
    } else {
      "passed"
    },
    "measurement": "compact-json-utf8",
    "budget": size_budget_json(budget),
    "exceeded_count": exceeded,
    "checks": checks,
    "comparison": comparison,
  }
}

///|
/// Return the effective schema-v1 allowances; omitted metrics stay omitted.
pub fn size_budget_json(budget : SizeBudget) -> Json {
  let limits : Map[String, Json] = Map([])
  for (key, _) in budget_metrics() {
    if budget.limits.get(key) is Some(value) {
      limits[key] = Json::number(value.to_double())
    }
  }
  { "schema_version": 1, "limits": Json::object(limits) }
}
