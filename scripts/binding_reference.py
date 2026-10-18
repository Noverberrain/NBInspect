"""Development-only CPython AST role oracle; never evaluate or execute input."""
import ast
import json
import sys

source = sys.stdin.buffer.read().decode("utf-8")
tree = ast.parse(source)
roles = []
for node in ast.walk(tree):
    if isinstance(node, ast.Name):
        roles.append({"name": node.id, "role": type(node.ctx).__name__,
                      "line": node.lineno - 1, "column": node.col_offset})
roles.sort(key=lambda item: (item["line"], item["column"], item["role"]))
json.dump({"python": sys.version.split()[0], "roles": roles}, sys.stdout)
