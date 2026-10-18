///|
#export_name("nbinspect_python_syntax")
pub fn nbinspect_python_syntax(input : String) -> String {
  let result : Json = @syntax.read_transport(input).to_json() catch {
    @syntax.Invalid(message) => { "error": message }
  }
  result.stringify()
}
