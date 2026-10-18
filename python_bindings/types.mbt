///|
/// A syntactic write, versioned per ASCII name in this one modeled module.
pub(all) struct Definition {
  id : Int
  order : Int
  name : String
  version : Int
  node : Int
  statement : Int
  kind : String
  scalar : Bool
  start : @syntax.Position
  end : @syntax.Position
} derive(ToJson)

///|
/// Bound refers to a preceding modeled Definition, never a verified runtime value.
pub(all) struct Reference {
  order : Int
  name : String
  node : Int
  context : String
  resolution : String
  definition : Int?
  start : @syntax.Position
  end : @syntax.Position
} derive(ToJson)

///|
/// Unsupported/dynamic constructs invalidate the current prefix environment.
pub(all) struct Uncertainty {
  order : Int
  node : Int
  reason : String
  start : @syntax.Position
  end : @syntax.Position
} derive(ToJson)

///|
pub(all) struct BindingReport {
  schema_version : Int
  kind : String
  status : String
  assumption : String
  parser : String
  source : String
  definitions : Array[Definition]
  references : Array[Reference]
  uncertainties : Array[Uncertainty]
  syntax_diagnostics : Array[@syntax.Diagnostic]
} derive(ToJson)

///|
pub extend Definition with ToJson::{to_json}

///|
pub extend Reference with ToJson::{to_json}

///|
pub extend Uncertainty with ToJson::{to_json}

///|
pub extend BindingReport with ToJson::{to_json}
