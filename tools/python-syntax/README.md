# Python syntax frontend experiment

This is the first analysis-depth milestone: a reproducible syntax frontend, not variable binding, dataflow, dependency inference or proof of correct execution. It is independent of the stable `nbinspect` CLI, Notebook review rules and browser UI.

## Prepare and run

Requires the existing MoonBit toolchain, Node.js 24, npm and PowerShell 7. The first preparation downloads integrity-locked packages; npm install scripts are disabled.

```powershell
pwsh -NoProfile -File scripts/prepare_python_syntax.ps1
node tools/python-syntax/probe.mjs examples/python-syntax/positions.py --backend js
node tools/python-syntax/probe.mjs examples/python-syntax/positions.py --backend native --output report.json
```

The input is one UTF-8 Python source file, including an empty file. Output is JSON; an existing output file is never overwritten. Exit codes: `0` means a tree without parser recovery diagnostics, `1` means a recovered tree with ERROR or MISSING nodes, `2` means configuration, input, resource or adapter failure. `parsed` only describes this pinned grammar's syntax result. It is not CPython compilation, semantic validation, a dependency result or a safety guarantee. `%`/`!` notebook magic is not rewritten or silently removed.

## Current architecture and limits

- Tree-sitter Python **0.25.0**, web-tree-sitter **0.25.10**, both MIT licensed. Dependencies and tarball integrity values are in `package-lock.json`; see [third-party notices](THIRD_PARTY.md).
- Node or a browser hosts the **same WASM grammar**. Its concrete syntax tree (CST, including punctuation and comments) is normalized to a flat preorder transport. A CST is not yet a Python semantic AST.
- MoonBit's independent `python_syntax` package validates this transport and exposes typed document, node, position and diagnostic models on native and JS. The native probe currently consumes a transport created by **Node/WASM**; it is **not** a direct native C parser binding. Node remains required for both command modes. The transport validator cannot authenticate an externally fabricated tree or independently prove Python grammar validity.
- Every node retains kind, named/missing flags, optional incoming grammar field, parent and half-open source range. JSON omits absent optional fields. Coordinates are **zero-based UTF-8 byte offsets and LF-based line/byte columns**, not UTF-16 positions or screen columns. CRLF, non-ASCII and non-BMP characters are preserved. The report includes the complete source once; it is local and no source is uploaded.
- At most **1 MiB** source, **50,000** CST nodes, **256** nesting edges and **16 MiB** transport. A parser progress callback requests cancellation after roughly one second; it is cooperative, not a process isolation guarantee. Native validation subprocesses have a ten-second timeout. Exceeding a limit fails rather than returning a truncated success. Parser/tree/cursor handles are released on failures.
- No source code, imports, functions, shell commands or Notebook cells are executed. No modifications are made to input files. Direct Notebook import, symbol binding, dependency graphs and cross-version impact analysis remain later milestones.

## Validation

```powershell
moon test python_syntax --target native
moon test python_syntax --target js
node scripts/python_syntax_test.mjs
```

The integration suite uses the actual pinned WASM grammar and compares the same artifacts through both MoonBit backends. It exercises empty/complex source, grammar fields, error recovery, Unicode/CRLF, invalid transports, resource limits, cancellation, non-execution and actual probe command exits. Small hand-written examples demonstrate grammar structure; they are not executed notebooks or evidence of semantic-analysis accuracy.
