///|
/// Analyze one Notebook for publication, or compare it with another Notebook.
/// An empty second input selects publication checks.
#export_name("nbinspect_analyze")
pub fn nbinspect_analyze(
  before : String,
  after : String,
  view : String,
) -> String {
  let result : Json = try {
    let first = @nb.parse(before, max_bytes=10485760)
    if after == "" {
      @nb.check_report(first)
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
  let result : Json = try {
    let first = @nb.parse(before, max_bytes=10485760)
    let second = @nb.parse(after, max_bytes=10485760)
    @nb.review_report(first, second)
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
