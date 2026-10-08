///|
#borrow(path, utf8)
extern "C" fn list_bytes(path : String, utf8 : Bytes) -> Bytes = "nb_list"

///|
fn directory_entries(path : String) -> Array[String] raise @nb.InputError {
  if path == "" || path.contains("\u0000") {
    raise @nb.Invalid("invalid directory path")
  }
  let raw = list_bytes(path, @utf8.encode(path))
  if raw.length() == 0 {
    raise @nb.Invalid(
      "cannot list directory (unreadable, linked or listing limit exceeded): " +
      path,
    )
  }
  let decoded = @utf8.decode(raw) catch {
    _ => raise @nb.Invalid("directory names are not UTF-8: " + path)
  }
  let entries = decoded[1:]
    .to_owned()
    .split("\u0000")
    .filter(fn(s) { s.length() > 0 })
    .map(fn(s) { s.to_owned() })
    .to_array()
  entries.sort()
  entries
}

///|
/// Discovery and file reads stay native; checks and report aggregation use the core.
fn scan_batch(
  root : String,
  recursive : Bool,
  fail_on : String,
) -> Json raise @nb.InputError {
  let first = directory_entries(root)
  let pending : Array[(String, Array[String])] = [("", first)]
  let paths : Array[String] = []
  let issues : Array[Json] = []
  let skipped : Array[Json] = []
  let mut directories = 1
  let mut limited = false
  while pending.length() > 0 && !limited {
    let (relative, entries) = pending.pop().unwrap()
    for entry in entries {
      let name = entry[1:].to_owned()
      let relative_path = if relative == "" {
        name
      } else {
        relative + "/" + name
      }
      let full = root + "/" + relative_path
      if entry.has_prefix("L") {
        skipped.push({
          "path": relative_path,
          "reason": "linked or special entry",
        })
      } else if entry.has_prefix("D") {
        if [
            "_build", ".git", ".mooncakes", ".ipynb_checkpoints", "node_modules",
          ].contains(name) {
          skipped.push({ "path": relative_path, "reason": "excluded directory" })
        } else if recursive {
          if directories >= 4096 {
            issues.push({
              "path": relative_path,
              "error": "directory limit (4096) exceeded",
            })
            limited = true
            break
          }
          directories += 1
          let children = directory_entries(full) catch {
            @nb.Invalid(message) => {
              issues.push({ "path": relative_path, "error": message })
              []
            }
          }
          pending.push((relative_path, children))
        }
      } else if name.to_lower().has_suffix(".ipynb") {
        if paths.length() >= 1000 {
          issues.push({
            "path": relative_path,
            "error": "Notebook limit (1000) exceeded",
          })
          limited = true
          break
        }
        paths.push(relative_path)
      }
    }
  }
  paths.sort()
  let files : Array[Json] = []
  for path in paths {
    let result = try {
      let notebook = @nb.parse(read(root + "/" + path))
      let report = @nb.check_report(notebook, fail_on~)
      @nb.batch_file(path, report)
    } catch {
      @nb.Invalid(message) => @nb.batch_error(path, message)
    }
    files.push(result)
  }
  @nb.batch_report(root, files, issues, skipped, recursive~, fail_on~)
}
