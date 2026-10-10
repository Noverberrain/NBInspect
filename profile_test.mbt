///|
fn profile_get(value : Json, key : String) -> Json {
  match value {
    Object(o) => o.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
fn profile_rows(report : Json, key : String) -> Array[Json] {
  match profile_get(report, key) {
    Array(rows) => rows
    _ => []
  }
}

///|
fn profile_size(value : Json) -> Json {
  @utf8.encode(value.stringify()).length().to_json()
}

///|
fn profile_book(
  cells : Array[Json],
  minor? : Int = 5,
) -> @nbinspect.Notebook raise @nbinspect.InputError {
  let value : Json = {
    "nbformat": 4,
    "nbformat_minor": minor,
    "metadata": {},
    "cells": cells,
    "extension": "preserved",
  }
  @nbinspect.parse(value.stringify())
}

///|
test "profile partitions compact UTF-8 bytes and keeps raw source representation" {
  let cell : Json = {
    "cell_type": "code",
    "id": "a",
    "source": ["你好\n", "print(1)"],
    "metadata": { "custom": "value" },
    "outputs": [],
    "execution_count": null,
  }
  let n = profile_book([cell])
  let raw = n.raw.stringify()
  let r = @nbinspect.profile_report(n)
  assert_eq(profile_get(r, "kind"), Json::string("profile"))
  assert_eq(profile_get(r, "schema_version"), Json::number(1))
  assert_eq(profile_get(r, "measurement"), Json::string("compact-json-utf8"))
  let summary = profile_get(r, "summary")
  assert_eq(profile_get(summary, "notebook_bytes"), profile_size(n.raw))
  assert_eq(
    profile_get(summary, "source_bytes"),
    profile_size(profile_get(cell, "source")),
  )
  assert_eq(profile_get(summary, "output_bytes"), Json::number(2))
  assert_eq(profile_get(summary, "attachment_bytes"), Json::number(0))
  let mut total = 0.0
  for key in ["source_bytes", "output_bytes", "attachment_bytes", "other_bytes"] {
    match profile_get(summary, key) {
      Number(v, ..) => {
        assert_true(v >= 0.0)
        total += v
      }
      _ => fail("missing size")
    }
  }
  assert_eq(Json::number(total), profile_get(summary, "notebook_bytes"))
  let row = profile_rows(r, "cells")[0]
  assert_eq(profile_get(row, "bytes"), profile_size(cell))
  assert_eq(n.raw.stringify(), raw)
  assert_false(r.stringify().contains("print(1)"))
}

///|
test "profile MIME totals include every representation and attachment without decoding" {
  let outputs : Json = [
    {
      "output_type": "display_data",
      "data": {
        "image/png": "invalid-base64",
        "application/json": { "值": [1, 2] },
      },
      "metadata": {},
    },
    {
      "output_type": "execute_result",
      "execution_count": 1,
      "data": { "image/png": ["aa", "bb"] },
      "metadata": {},
    },
  ]
  let attachments : Json = { "a~/~/.png": { "image/png": "aaaa" } }
  let code : Json = {
    "cell_type": "code",
    "id": "c",
    "source": "x",
    "metadata": {},
    "execution_count": 1,
    "outputs": outputs,
  }
  let markdown : Json = {
    "cell_type": "markdown",
    "id": "m",
    "source": "image",
    "metadata": {},
    "attachments": attachments,
  }
  let r = @nbinspect.profile_report(profile_book([code, markdown]))
  assert_eq(profile_get(r, "resource_count"), Json::number(4))
  let mimes = profile_rows(r, "mime_types")
  let png = mimes.filter(fn(row) {
      profile_get(row, "mime") == Json::string("image/png")
    })[0]
  assert_eq(profile_get(png, "count"), Json::number(3))
  // 16 + 11 + 6 compact JSON value bytes, with quotes/array punctuation.
  assert_eq(profile_get(png, "bytes"), Json::number(33))
  assert_eq(
    profile_get(profile_get(r, "summary"), "output_bytes"),
    profile_size(outputs),
  )
  assert_eq(
    profile_get(profile_get(r, "summary"), "attachment_bytes"),
    profile_size(attachments),
  )
  let resources = profile_rows(r, "resources")
  assert_true(
    resources.any(fn(row) {
      profile_get(row, "path") ==
      Json::string("/cells/1/attachments/a~0~1~0~1.png/image~1png")
    }),
  )
  assert_false(r.stringify().contains("invalid-base64"))
}

///|
test "profile stream and error resources do not invent MIME types" {
  let error : Json = {
    "output_type": "error",
    "ename": "E",
    "evalue": "saved",
    "traceback": ["line\n"],
  }
  let code : Json = {
    "cell_type": "code",
    "id": "a",
    "source": "",
    "metadata": {},
    "execution_count": null,
    "outputs": [
      { "output_type": "stream", "name": "stdout", "text": ["你好\n"] },
      error,
    ],
  }
  let r = @nbinspect.profile_report(profile_book([code]))
  assert_eq(profile_rows(r, "mime_types").length(), 0)
  let resources = profile_rows(r, "resources")
  assert_eq(resources.length(), 2)
  let saved = resources.filter(fn(row) {
      profile_get(row, "kind") == Json::string("error")
    })[0]
  assert_eq(profile_get(saved, "mime"), Json::null())
  assert_eq(profile_get(saved, "bytes"), profile_size(error))
}

///|
test "profile deterministic size ranking and tie order across identical cells" {
  let small : Json = {
    "cell_type": "raw",
    "id": "s",
    "source": "x",
    "metadata": {},
  }
  let large : Json = {
    "cell_type": "raw",
    "id": "l",
    "source": "xxxxxxxxxxxxxxxx",
    "metadata": {},
  }
  let r = @nbinspect.profile_report(profile_book([small, small, large]))
  let rows = profile_rows(r, "cells")
  assert_eq(profile_get(rows[0], "index"), Json::number(2))
  assert_eq(profile_get(rows[1], "index"), Json::number(0))
  assert_eq(profile_get(rows[2], "index"), Json::number(1))
  let first : Json = {
    "cell_type": "markdown",
    "source": "",
    "metadata": {},
    "attachments": { "x": { "z/type": "a", "a/type": "b" } },
  }
  let second : Json = {
    "cell_type": "markdown",
    "source": "",
    "metadata": {},
    "attachments": { "x": { "a/type": "b", "z/type": "a" } },
  }
  assert_eq(
    @nbinspect.profile_report(profile_book([first])).stringify(),
    @nbinspect.profile_report(profile_book([second])).stringify(),
  )
}

///|
test "profile empty notebooks null attachments and supported version boundaries" {
  for minor in 0..<=5 {
    let r = @nbinspect.profile_report(profile_book([], minor~))
    assert_eq(profile_get(r, "cell_count"), Json::number(0))
    assert_eq(
      profile_get(profile_get(r, "summary"), "source_bytes"),
      Json::number(0),
    )
    assert_eq(profile_rows(r, "cells").length(), 0)
    assert_true(@nbinspect.html_report(r).contains("Size breakdown (bytes)"))
  }
  let cell : Json = {
    "cell_type": "raw",
    "source": "",
    "metadata": {},
    "attachments": null,
  }
  let r = @nbinspect.profile_report(profile_book([cell]))
  assert_eq(
    profile_get(profile_get(r, "summary"), "attachment_bytes"),
    Json::number(4),
  )
  try @nbinspect.profile_report(profile_book([], minor=6)) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("verified nbformat"))
  } noraise {
    _ => fail("unsupported version accepted")
  }
}

///|
test "profile reports escape hostile MIME keys and retain locations without payloads" {
  let cell : Json = {
    "cell_type": "markdown",
    "id": "<img>",
    "source": "secret-source",
    "metadata": {},
    "attachments": {
      "<script>&\"'": { "<svg/onload=alert(1)>": "secret-payload" },
    },
  }
  let r = @nbinspect.profile_report(profile_book([cell]))
  let html = @nbinspect.html_report(r)
  assert_false(html.contains("<script>"))
  assert_false(html.contains("<svg/"))
  assert_false(html.contains("<img>"))
  assert_true(html.contains("&lt;script&gt;&amp;&quot;&#39;"))
  assert_true(html.contains("script-src 'none'"))
  assert_false(html.contains("secret-payload"))
  assert_false(html.contains("secret-source"))
  let text = @nbinspect.text_report(r)
  assert_true(text.contains("Cells by size"))
  assert_true(text.contains("MIME payloads"))
  assert_true(text.contains("/cells/0/attachments/"))
}

///|
test "profile resource limit rejects excess instead of silently truncating" {
  let data : Map[String, Json] = Map([])
  for i in 0..<10000 {
    data[i.to_string()] = Json::null()
  }
  let make_cell = fn() {
    let cell : Json = {
      "cell_type": "markdown",
      "source": "",
      "metadata": {},
      "attachments": { "x": Json::object(data) },
    }
    cell
  }
  assert_eq(
    profile_get(
      @nbinspect.profile_report(profile_book([make_cell()])),
      "resource_count",
    ),
    Json::number(10000),
  )
  data["extra"] = Json::null()
  try @nbinspect.profile_report(profile_book([make_cell()])) catch {
    @nbinspect.Invalid(message) =>
      assert_true(message.contains("resource limit"))
  } noraise {
    _ => fail("resource limit ignored")
  }
}
