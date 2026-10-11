///|
fn budget_text(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "Growth allowance checks (after - before); equality and shrinkage pass.\n",
  )
  b.write_string(
    "Effective size budget: " + field(report, "budget").stringify() + "\n",
  )
  match field(report, "checks") {
    Array(rows) =>
      for row in rows {
        b.write_string(
          report_string(field(row, "metric")) +
          ": delta " +
          field(row, "delta_bytes").stringify() +
          "; allowance " +
          field(row, "allowed_growth_bytes").stringify() +
          "; excess " +
          field(row, "excess_bytes").stringify() +
          " bytes; " +
          report_string(field(row, "status")) +
          "\n",
        )
      }
    _ => ()
  }
  profile_diff_text(b, field(report, "comparison"))
}

///|
fn budget_html(b : StringBuilder, report : Json) -> Unit {
  b.write_string(
    "<section><h2>Notebook growth budget</h2><p>Each configured allowance checks the total category delta (after minus before). Equality and shrinkage pass. Omitted categories are not checked. This is a size gate, not a publication-risk check; matching ambiguity does not change global byte totals.</p><p>Exceeded allowances: " +
    escape_html(field(report, "exceeded_count").stringify()) +
    "</p></section>",
  )
  html_section(b, "Effective size budget", field(report, "budget"))
  profile_table(b, "Growth allowance results", field(report, "checks"), [
    "metric", "before_bytes", "after_bytes", "delta_bytes", "allowed_growth_bytes",
    "excess_bytes", "status",
  ])
  profile_diff_html(b, field(report, "comparison"))
}
