///|
/// A limited, sequential module-name model. It does not execute code, solve
/// branches or functions, infer cell dependencies, or reconstruct kernel history.
/// Dynamic effects invalidate prefix bindings; new explicit writes can bind again.
pub fn analyze(input : String) -> BindingReport raise @syntax.SyntaxError {
  let document = @syntax.read_transport(input)
  let children : Array[Array[Int]] = Array::makei(document.nodes.length(), fn(
    _,
  ) {
    []
  })
  for node in document.nodes {
    if node.parent is Some(p) {
      children[p].push(node.index)
    }
  }
  let state : State = {
    document,
    source_bytes: @utf8.encode(document.source),
    children,
    environment: {},
    versions: {},
    definitions: [],
    references: [],
    uncertainties: [],
    next_order: 0,
    tainted: false,
  }
  if document.status != "parsed" {
    state.uncertain(0, "syntax-errors-no-binding-analysis")
  } else {
    for node in state.named(0) {
      state.statement(node)
    }
  }
  {
    schema_version: 1,
    kind: "python-bindings",
    status: if state.uncertainties.is_empty() {
      "modeled"
    } else {
      "incomplete"
    },
    assumption: "sequential-module-normal-completion-no-implicit-namespace-effects",
    parser: document.parser,
    source: document.source,
    definitions: state.definitions,
    references: state.references,
    uncertainties: state.uncertainties,
    syntax_diagnostics: document.diagnostics,
  }
}

///|
fn State::statement(self : State, node : Int) -> Unit raise @syntax.SyntaxError {
  match self.document.nodes[node].kind {
    "expression_statement" =>
      for child in self.named(node) {
        match self.document.nodes[child].kind {
          "assignment" => self.assignment(child, node)
          "augmented_assignment" => self.augmented(child, node)
          _ => ignore(self.expression(child))
        }
      }
    "pass_statement" | "comment" => ()
    _ =>
      self.uncertain(
        node,
        "unsupported-statement:" + self.document.nodes[node].kind,
      )
  }
}

///|
fn State::assignment(
  self : State,
  node : Int,
  statement : Int,
) -> Unit raise @syntax.SyntaxError {
  let targets : Array[Int] = []
  let mut cursor = node
  while self.document.nodes[cursor].kind == "assignment" {
    let left = self.field(cursor, "left")
    let right = self.field(cursor, "right")
    if self.field(cursor, "type") != None || left == None || right == None {
      self.uncertain(node, "unsupported-assignment")
      return
    }
    let target = left.unwrap()
    if self.document.nodes[target].kind != "identifier" {
      self.uncertain(node, "unsupported-assignment-target")
      return
    }
    targets.push(target)
    cursor = right.unwrap()
  }
  // Python evaluates the RHS once, then assigns chain targets left to right.
  let scalar = self.expression(cursor)
  for target in targets {
    self.write(target, statement, "assignment", scalar)
  }
}

///|
fn State::augmented(
  self : State,
  node : Int,
  statement : Int,
) -> Unit raise @syntax.SyntaxError {
  let left = self.field(node, "left")
  let right = self.field(node, "right")
  if left == None ||
    right == None ||
    self.document.nodes[left.unwrap()].kind != "identifier" {
    self.uncertain(node, "unsupported-augmented-target")
    return
  }
  let target = left.unwrap()
  // Unlike ordinary assignment, the target is read before the RHS.
  let old_scalar = self.read(target, "augmented-target")
  let rhs_scalar = self.expression(right.unwrap())
  if !old_scalar || !rhs_scalar {
    self.uncertain(node, "dynamic-augmented-operator")
  }
  self.write(target, statement, "augmented", old_scalar && rhs_scalar)
}
