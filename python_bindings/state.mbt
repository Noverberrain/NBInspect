///|
priv struct State {
  document : @syntax.Document
  source_bytes : Bytes
  children : Array[Array[Int]]
  environment : Map[String, Int]
  versions : Map[String, Int]
  definitions : Array[Definition]
  references : Array[Reference]
  uncertainties : Array[Uncertainty]
  mut next_order : Int
  mut tainted : Bool
}

///|
fn State::next(self : State) -> Int raise @syntax.SyntaxError {
  if self.next_order >= 100000 {
    raise @syntax.Invalid("binding event limit exceeded")
  }
  let order = self.next_order
  self.next_order += 1
  order
}

///|
fn State::uncertain(
  self : State,
  node : Int,
  reason : String,
) -> Unit raise @syntax.SyntaxError {
  let n = self.document.nodes[node]
  self.uncertainties.push({
    order: self.next(),
    node,
    reason,
    start: n.start,
    end: n.end,
  })
  self.environment.clear()
  self.tainted = true
}

///|
fn State::content(self : State, node : Int) -> String raise @syntax.SyntaxError {
  let n = self.document.nodes[node]
  @utf8.decode(
    self.source_bytes.exact_view(
      start=n.start.byte_offset,
      end=n.end.byte_offset,
    ),
    ignore_bom=true,
  ) catch {
    _ => raise @syntax.Invalid("identifier span is not valid UTF-8")
  }
}

///|
fn ascii_name(name : String) -> Bool {
  if name == "" {
    return false
  }
  for i, c in name.to_array() {
    if c != '_' &&
      !(c >= 'a' && c <= 'z') &&
      !(c >= 'A' && c <= 'Z') &&
      !(i > 0 && c >= '0' && c <= '9') {
      return false
    }
  }
  true
}

///|
fn State::read(
  self : State,
  node : Int,
  context : String,
) -> Bool raise @syntax.SyntaxError {
  let name = self.content(node)
  if !ascii_name(name) {
    self.uncertain(node, "identifier-normalization-unsupported")
  }
  let binding = self.environment.get(name)
  let n = self.document.nodes[node]
  self.references.push({
    order: self.next(),
    name,
    node,
    context,
    resolution: if binding is Some(_) {
      "bound"
    } else if self.tainted {
      "unknown-after-barrier"
    } else {
      "external"
    },
    definition: binding,
    start: n.start,
    end: n.end,
  })
  match binding {
    Some(id) => self.definitions[id].scalar
    None => false
  }
}

///|
fn State::write(
  self : State,
  node : Int,
  statement : Int,
  kind : String,
  scalar : Bool,
) -> Unit raise @syntax.SyntaxError {
  let name = self.content(node)
  if !ascii_name(name) {
    self.uncertain(node, "identifier-normalization-unsupported")
    return
  }
  let version = self.versions.get(name).unwrap_or(0) + 1
  let id = self.definitions.length()
  let n = self.document.nodes[node]
  self.definitions.push({
    id,
    order: self.next(),
    name,
    version,
    node,
    statement,
    kind,
    scalar,
    start: n.start,
    end: n.end,
  })
  self.versions[name] = version
  self.environment[name] = id
}

///|
fn State::field(self : State, node : Int, name : String) -> Int? {
  for i in self.children[node] {
    if self.document.nodes[i].field_name == Some(name) {
      return Some(i)
    }
  }
  None
}

///|
fn State::named(self : State, node : Int) -> Array[Int] {
  self.children[node].filter(fn(i) {
    self.document.nodes[i].named && self.document.nodes[i].kind != "comment"
  })
}
