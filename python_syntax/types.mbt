///|
/// Coordinates are zero-based UTF-8 byte offsets and LF-based line/byte columns.
pub(all) struct Position {
  byte_offset : Int
  line : Int
  column : Int
} derive(ToJson)

///|
/// A concrete syntax node. Parent indices refer to the same preorder node array.
pub(all) struct SyntaxNode {
  index : Int
  parent : Int?
  kind : String
  field_name : String?
  named : Bool
  missing : Bool
  start : Position
  end : Position
} derive(ToJson)

///|
pub(all) struct Diagnostic {
  node : Int
  kind : String
  start : Position
  end : Position
} derive(ToJson)

///|
/// Syntax-only evidence: parsed does not imply valid Python semantics or safe code.
pub(all) struct Document {
  schema_version : Int
  kind : String
  status : String
  parser : String
  coordinates : String
  source : String
  nodes : Array[SyntaxNode]
  diagnostics : Array[Diagnostic]
} derive(ToJson)

///|
pub(all) suberror SyntaxError {
  Invalid(String)
}

///|
pub extend Position with ToJson::{to_json}

///|
pub extend SyntaxNode with ToJson::{to_json}

///|
pub extend Diagnostic with ToJson::{to_json}

///|
pub extend Document with ToJson::{to_json}
