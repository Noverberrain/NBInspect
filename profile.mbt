///|
fn profile_bytes(value : Json) -> Int64 {
  @utf8.encode(value.stringify()).length().to_int64()
}

///|
fn profile_number(value : Int64) -> Json {
  Json::number(value.to_double())
}

///|
fn profile_pointer(key : String) -> String {
  key.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
fn profile_resource(
  resources : Array[Json],
  mimes : Map[String, (Int64, Int)],
  path : String,
  kind : String,
  mime : String?,
  value : Json,
) -> Unit raise InputError {
  if resources.length() >= 10000 {
    raise Invalid("profile resource limit exceeded (10000)")
  }
  let bytes = profile_bytes(value)
  resources.push({
    "path": path,
    "kind": kind,
    "mime": match mime {
      Some(s) => Json::string(s)
      None => Json::null()
    },
    "bytes": profile_number(bytes),
  })
  if mime is Some(s) {
    let (previous, count) = mimes.get(s).unwrap_or((0L, 0))
    mimes[s] = (previous + bytes, count + 1)
  }
}

///|
/// Profile compact JSON UTF-8 sizes without decoding or executing payloads.
/// The four summary categories partition notebook_bytes. Resource/MIME sizes
/// describe stored JSON values and exclude their enclosing keys and separators.
/// Missing attachments contribute zero; empty output arrays still occupy 2 bytes.
/// Requires a parsed, compatible Notebook. At most 10000 resource entries.
pub fn profile_report(n : Notebook) -> Json raise InputError {
  if !n.compatible {
    raise Invalid("profile requires a verified nbformat minor version (0-5)")
  }
  let cells : Array[(Int64, Int, Json)] = []
  let resources : Array[Json] = []
  let mimes : Map[String, (Int64, Int)] = Map([])
  let mut source_bytes = 0L
  let mut output_bytes = 0L
  let mut attachment_bytes = 0L
  for cell in n.cells {
    let path = "/cells/" + cell.index.to_string()
    let source = profile_bytes(field(cell.raw, "source"))
    let outputs = if cell.kind == "code" {
      profile_bytes(field(cell.raw, "outputs"))
    } else {
      0L
    }
    let attachments = match cell.raw {
      Object(o) =>
        match o.get("attachments") {
          Some(value) => profile_bytes(value)
          None => 0L
        }
      _ => 0L
    }
    let bytes = profile_bytes(cell.raw)
    source_bytes += source
    output_bytes += outputs
    attachment_bytes += attachments
    cells.push(
      (
        bytes,
        cell.index,
        {
          "index": cell.index,
          "id": match cell.id {
            Some(s) => Json::string(s)
            None => Json::null()
          },
          "cell_type": cell.kind,
          "path": path,
          "bytes": profile_number(bytes),
          "source_bytes": profile_number(source),
          "output_bytes": profile_number(outputs),
          "attachment_bytes": profile_number(attachments),
          "other_bytes": profile_number(bytes - source - outputs - attachments),
        },
      ),
    )
    if cell.kind == "code" {
      for i, output in array_at(field(cell.raw, "outputs"), path + "/outputs") {
        let op = path + "/outputs/" + i.to_string()
        match field(output, "output_type") {
          String("stream") =>
            profile_resource(
              resources,
              mimes,
              op + "/text",
              "stream",
              None,
              field(output, "text"),
            )
          String("error") =>
            profile_resource(resources, mimes, op, "error", None, output)
          _ =>
            match field(output, "data") {
              Object(bundle) =>
                for mime, value in bundle {
                  profile_resource(
                    resources,
                    mimes,
                    op + "/data/" + profile_pointer(mime),
                    "output",
                    Some(mime),
                    value,
                  )
                }
              _ => ()
            }
        }
      }
    }
    match field(cell.raw, "attachments") {
      Object(attachments) =>
        for name, bundle in attachments {
          match bundle {
            Object(data) =>
              for mime, value in data {
                profile_resource(
                  resources,
                  mimes,
                  path +
                  "/attachments/" +
                  profile_pointer(name) +
                  "/" +
                  profile_pointer(mime),
                  "attachment",
                  Some(mime),
                  value,
                )
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  // Stable ties and key sorting make native and JS reports reproducible.
  cells.sort_by(fn(a, b) {
    if a.0 == b.0 {
      a.1.compare(b.1)
    } else {
      b.0.compare(a.0)
    }
  })
  resources.sort_by(fn(a, b) {
    let aa = field(a, "bytes")
    let bb = field(b, "bytes")
    if aa == bb {
      report_string(field(a, "path")).compare(report_string(field(b, "path")))
    } else {
      match (aa, bb) {
        (Number(x, ..), Number(y, ..)) => y.compare(x)
        _ => 0
      }
    }
  })
  let mime_rows = mimes
    .iter()
    .map(fn(entry) {
      let (mime, (bytes, count)) = entry
      (
        bytes,
        mime,
        Json::object({
          "mime": mime.to_json(),
          "bytes": profile_number(bytes),
          "count": count.to_json(),
        }),
      )
    })
    .collect()
  mime_rows.sort_by(fn(a, b) {
    if a.0 == b.0 {
      a.1.compare(b.1)
    } else {
      b.0.compare(a.0)
    }
  })
  let notebook_bytes = profile_bytes(n.raw)
  {
    "schema_version": 1,
    "kind": "profile",
    "status": "complete",
    "measurement": "compact-json-utf8",
    "nbformat_minor": n.minor,
    "cell_count": n.cells.length(),
    "resource_count": resources.length(),
    "summary": {
      "notebook_bytes": profile_number(notebook_bytes),
      "source_bytes": profile_number(source_bytes),
      "output_bytes": profile_number(output_bytes),
      "attachment_bytes": profile_number(attachment_bytes),
      "other_bytes": profile_number(
        notebook_bytes - source_bytes - output_bytes - attachment_bytes,
      ),
    },
    "cells": cells.map(fn(row) { row.2 }),
    "mime_types": mime_rows.map(fn(row) { row.2 }),
    "resources": resources,
  }
}
