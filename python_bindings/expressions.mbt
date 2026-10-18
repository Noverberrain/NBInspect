///|
fn State::expression(
  self : State,
  node : Int,
) -> Bool raise @syntax.SyntaxError {
  let kind = self.document.nodes[node].kind
  match kind {
    "identifier" => self.read(node, "value")
    "integer" | "float" | "true" | "false" | "none" | "ellipsis" => true
    "string" =>
      if self
        .named(node)
        .all(fn(i) {
          let k = self.document.nodes[i].kind
          k == "string_start" ||
          k == "string_content" ||
          k == "string_end" ||
          k == "escape_sequence"
        }) {
        true
      } else {
        self.uncertain(node, "unsupported-string-interpolation")
        false
      }
    "parenthesized_expression" | "concatenated_string" => {
      let mut scalar = true
      for child in self.named(node) {
        let value = self.expression(child)
        scalar = scalar && value
      }
      scalar
    }
    "binary_operator"
    | "unary_operator"
    | "not_operator"
    | "comparison_operator" => {
      let operands = self.named(node)
      if kind == "comparison_operator" && operands.length() > 2 {
        self.uncertain(node, "unsupported-short-circuit-comparison")
        return false
      }
      let mut scalar = true
      for child in operands {
        let value = self.expression(child)
        scalar = scalar && value
      }
      if !scalar {
        self.uncertain(node, "dynamic-operator")
      }
      scalar
    }
    "list" | "tuple" | "set" => {
      for child in self.named(node) {
        let scalar = self.expression(child)
        if kind == "set" && !scalar {
          self.uncertain(child, "dynamic-hashing")
        }
      }
      false
    }
    "dictionary" => {
      for child in self.named(node) {
        if self.document.nodes[child].kind != "pair" {
          self.uncertain(child, "unsupported-dictionary-item")
        } else {
          let key = self.field(child, "key")
          let value = self.field(child, "value")
          if key == None || value == None {
            self.uncertain(child, "unsupported-dictionary-pair")
          } else {
            let scalar = self.expression(key.unwrap())
            ignore(self.expression(value.unwrap()))
            if !scalar {
              self.uncertain(child, "dynamic-hashing")
            }
          }
        }
      }
      false
    }
    "call" => {
      if self.field(node, "function") is Some(f) {
        ignore(self.expression(f))
      }
      if self.field(node, "arguments") is Some(args) {
        if self.document.nodes[args].kind != "argument_list" {
          self.uncertain(args, "unsupported-call-argument-scope")
          return false
        }
        let arguments = self.named(args)
        if arguments.any(fn(i) {
            let k = self.document.nodes[i].kind
            k == "list_splat" || k == "dictionary_splat"
          }) {
          self.uncertain(node, "unsupported-call-unpacking")
          return false
        }
        for arg in arguments {
          if self.document.nodes[arg].kind == "keyword_argument" {
            if self.field(arg, "value") is Some(value) {
              ignore(self.expression(value))
            } else {
              self.uncertain(arg, "unsupported-keyword-argument")
            }
          } else {
            ignore(self.expression(arg))
          }
        }
      }
      self.uncertain(node, "dynamic-call")
      false
    }
    "attribute" => {
      if self.field(node, "object") is Some(object) {
        ignore(self.expression(object))
      }
      self.uncertain(node, "dynamic-attribute")
      false
    }
    "subscript" => {
      for child in self.named(node) {
        ignore(self.expression(child))
      }
      self.uncertain(node, "dynamic-subscript")
      false
    }
    _ => {
      self.uncertain(node, "unsupported-expression:" + kind)
      false
    }
  }
}
