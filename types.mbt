///|
pub(all) struct Cell {
  index : Int
  id : String?
  kind : String
  source : String
  raw : Json
}

///|
pub(all) struct Finding {
  code : String
  severity : String
  path : String
  message : String
}

///|
pub(all) struct Notebook {
  minor : Int
  cells : Array[Cell]
  raw : Json
  findings : Array[Finding]
  compatible : Bool
}

///|
pub suberror InputError {
  Invalid(String)
}
