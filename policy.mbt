///|
/// Validated publication policy. Construct with default_policy or parse_policy.
pub struct CheckPolicy {
  enabled : Array[String]
  severities : Map[String, String]
  max_cell_output : Int
  max_total_output : Int
  fail_on : String
}

///|
fn policy_rules() -> Array[String] {
  [
    "FMT001", "FMT002", "OUT001", "EXE001", "EXE002", "ATT001", "SIZE001", "META001",
  ]
}

///|
pub fn default_policy() -> CheckPolicy {
  {
    enabled: policy_rules(),
    severities: {
      "FMT001": "error",
      "FMT002": "error",
      "OUT001": "warning",
      "EXE001": "warning",
      "EXE002": "info",
      "ATT001": "warning",
      "SIZE001": "warning",
      "META001": "info",
    },
    max_cell_output: 1048576,
    max_total_output: 10485760,
    fail_on: "error",
  }
}

///|
pub fn CheckPolicy::with_fail_on(
  self : CheckPolicy,
  severity : String,
) -> CheckPolicy raise InputError {
  ignore(blocks([], fail_on=severity))
  {
    enabled: self.enabled,
    severities: self.severities,
    max_cell_output: self.max_cell_output,
    max_total_output: self.max_total_output,
    fail_on: severity,
  }
}

///|
fn policy_object(
  value : Json,
  path : String,
  known : Array[String],
) -> Map[String, Json] raise InputError {
  let object = match value {
    Object(o) => o
    _ =>
      raise Invalid(
        "configuration " +
        (if path == "" { "/" } else { path }) +
        ": expected object",
      )
  }
  for (key, _) in object.to_array() {
    if !known.contains(key) {
      raise Invalid("configuration " + path + "/" + key + ": unknown field")
    }
  }
  object
}

///|
fn policy_severity(value : Json, path : String) -> String raise InputError {
  match value {
    String(s) =>
      if ["error", "warning", "info"].contains(s) {
        s
      } else {
        raise Invalid(
          "configuration " + path + ": expected error, warning or info",
        )
      }
    _ => raise Invalid("configuration " + path + ": expected severity string")
  }
}

///|
fn policy_limit(value : Json, path : String) -> Int raise InputError {
  match value {
    Number(n, ..) =>
      if n >= 1 && n <= 2147483647.0 && n == n.to_int().to_double() {
        n.to_int()
      } else {
        raise Invalid(
          "configuration " + path + ": expected positive 32-bit integer",
        )
      }
    _ => raise Invalid("configuration " + path + ": expected positive integer")
  }
}

///|
/// Parse a strict schema-v1 JSON policy; absent fields inherit defaults.
pub fn parse_policy(input : String) -> CheckPolicy raise InputError {
  if @utf8.encode(input).length() > 1048576 {
    raise Invalid("configuration /: exceeds 1 MiB")
  }
  let value = @json.parse(input) catch {
    error =>
      raise Invalid("configuration /: invalid JSON: " + error.to_string())
  }
  let o = policy_object(value, "", [
    "schema_version", "fail_on", "rules", "limits",
  ])
  match o.get("schema_version") {
    Some(Number(1, ..)) | None => ()
    _ => raise Invalid("configuration /schema_version: expected 1")
  }
  let base = default_policy()
  let fail_on = match o.get("fail_on") {
    Some(v) => policy_severity(v, "/fail_on")
    None => base.fail_on
  }
  let enabled : Array[String] = []
  let severities = base.severities.copy()
  let rules = match o.get("rules") {
    Some(v) => policy_object(v, "/rules", policy_rules())
    None => Map([])
  }
  for code in policy_rules() {
    let settings = match rules.get(code) {
      Some(v) => policy_object(v, "/rules/" + code, ["enabled", "severity"])
      None => Map([])
    }
    let active = match settings.get("enabled") {
      Some(True) => true
      Some(False) => false
      None => true
      _ =>
        raise Invalid(
          "configuration /rules/" + code + "/enabled: expected boolean",
        )
    }
    let severity = match settings.get("severity") {
      Some(v) => policy_severity(v, "/rules/" + code + "/severity")
      None => severities[code]
    }
    if (code == "FMT001" || code == "FMT002") &&
      (!active || severity != "error") {
      raise Invalid(
        "configuration /rules/" +
        code +
        ": format checks must remain enabled at error",
      )
    }
    if active {
      enabled.push(code)
    }
    severities[code] = severity
  }
  let limits = match o.get("limits") {
    Some(v) =>
      policy_object(v, "/limits", [
        "max_cell_output_bytes", "max_total_output_bytes",
      ])
    None => Map([])
  }
  let cell = match limits.get("max_cell_output_bytes") {
    Some(v) => policy_limit(v, "/limits/max_cell_output_bytes")
    None => base.max_cell_output
  }
  let total = match limits.get("max_total_output_bytes") {
    Some(v) => policy_limit(v, "/limits/max_total_output_bytes")
    None => base.max_total_output
  }
  {
    enabled,
    severities,
    max_cell_output: cell,
    max_total_output: total,
    fail_on,
  }
}

///|
/// Normalized effective settings, including defaults and disabled rules.
pub fn policy_json(policy : CheckPolicy) -> Json {
  let rules : Map[String, Json] = Map([])
  for code in policy_rules() {
    rules[code] = {
      "enabled": policy.enabled.contains(code),
      "severity": policy.severities[code],
    }
  }
  {
    "schema_version": 1,
    "fail_on": policy.fail_on,
    "rules": Json::object(rules),
    "limits": {
      "max_cell_output_bytes": policy.max_cell_output,
      "max_total_output_bytes": policy.max_total_output,
    },
  }
}

///|
fn validate_policy(policy : CheckPolicy) -> Unit raise InputError {
  ignore(blocks([], fail_on=policy.fail_on))
  if policy.max_cell_output <= 0 || policy.max_total_output <= 0 {
    raise Invalid("policy output thresholds must be positive")
  }
  for code in policy.enabled {
    if !policy_rules().contains(code) {
      raise Invalid("unknown policy rule: " + code)
    }
  }
  for (code, _) in policy.severities.to_array() {
    if !policy_rules().contains(code) {
      raise Invalid("unknown policy severity rule: " + code)
    }
  }
  for code in policy_rules() {
    let severity = policy.severities.get(code).unwrap_or("")
    if !["error", "warning", "info"].contains(severity) {
      raise Invalid("invalid policy severity: " + code)
    }
    if (code == "FMT001" || code == "FMT002") &&
      (!policy.enabled.contains(code) || severity != "error") {
      raise Invalid(
        "policy format checks must remain enabled at error: " + code,
      )
    }
  }
}
