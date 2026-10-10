///|
/// Analyze one Notebook for publication, or compare it with another Notebook.
/// An empty second input selects publication checks.
#export_name("nbinspect_analyze")
pub fn nbinspect_analyze(
  before : String,
  after : String,
  view : String,
) -> String {
  nbinspect_analyze_with_policy(before, after, view, "")
}

///|
/// Apply a schema-v1 policy to checks. Diff intentionally ignores the policy.
#export_name("nbinspect_analyze_with_policy")
pub fn nbinspect_analyze_with_policy(
  before : String,
  after : String,
  view : String,
  input : String,
) -> String {
  let result : Json = try {
    let first = @nb.parse(before, max_bytes=10485760)
    if after == "" {
      let policy = if input == "" {
        @nb.default_policy()
      } else {
        @nb.parse_policy(input)
      }
      @nb.check_report(first, policy~)
    } else {
      let second = @nb.parse(after, max_bytes=10485760)
      @nb.diff_report(first, second, view~)
    }
  } catch {
    @nb.Invalid(message) => { "error": message }
  }
  result.stringify()
}

///|
/// Turn a structured report into the same escaped, standalone HTML as the CLI.
#export_name("nbinspect_render_report")
pub fn nbinspect_render_report(input : String) -> String {
  let report = @json.parse(input) catch { _ => Json::null() }
  @nb.html_report(report)
}

///|
/// Compare publication risks. The default blocking threshold is error.
#export_name("nbinspect_review")
pub fn nbinspect_review(before : String, after : String) -> String {
  nbinspect_review_with_policy(before, after, "")
}

///|
/// Use one validated policy for both versions and the blocking threshold.
#export_name("nbinspect_review_with_policy")
pub fn nbinspect_review_with_policy(
  before : String,
  after : String,
  input : String,
) -> String {
  let result : Json = try {
    let first = @nb.parse(before, max_bytes=10485760)
    let second = @nb.parse(after, max_bytes=10485760)
    let policy = if input == "" {
      @nb.default_policy()
    } else {
      @nb.parse_policy(input)
    }
    @nb.review_report(first, second, policy~)
  } catch {
    @nb.Invalid(message) => { "error": message }
  }
  result.stringify()
}

///|
/// Filter only the HTML display; the original review JSON stays complete.
#export_name("nbinspect_render_review")
pub fn nbinspect_render_review(input : String, status : String) -> String {
  let report = @json.parse(input) catch { _ => Json::null() }
  @nb.html_report(report, risk_status=status)
}

///|
/// Validate an imported configuration and expose all effective settings.
#export_name("nbinspect_parse_policy")
pub fn nbinspect_parse_policy(input : String) -> String {
  let result : Json = @nb.policy_json(@nb.parse_policy(input)) catch {
    @nb.Invalid(message) => { "error": message }
  }
  result.stringify()
}

///|
/// Profile one Notebook locally, independently of publication policy.
/// Use the same compact JSON UTF-8 measurement as the native CLI.
#export_name("nbinspect_profile")
pub fn nbinspect_profile(input : String) -> String {
  let result : Json = @nb.profile_report(@nb.parse(input, max_bytes=10485760)) catch {
    @nb.Invalid(message) => { "error": message }
  }
  result.stringify()
}
