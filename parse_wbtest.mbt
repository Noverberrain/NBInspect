///|
fn fixture(source : Json, id? : String = "a") -> String {
  let value : Json = {
    "nbformat": 4,
    "nbformat_minor": 5,
    "metadata": {},
    "cells": [
      {
        "cell_type": "code",
        "id": id,
        "metadata": {},
        "source": source,
        "execution_count": null,
        "outputs": [],
      },
    ],
  }
  value.stringify()
}

///|
test "text representations and unknown fields" {
  let a = parse(fixture("a\nb"))
  let b = parse(fixture(["a\n", "b"]))
  assert_eq(a.cells[0].source, b.cells[0].source)
  assert_eq(a.compatible, true)
}

///|
test "duplicate and invalid IDs are findings" {
  assert_eq(parse(fixture("", id="bad id")).findings.length(), 1)
}

///|
test "invalid structure is located" {
  try parse("{\"nbformat\":4}") catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("expected invalid structure")
  }
}

///|
test "size limits reject rather than truncate" {
  try parse(fixture("abc"), max_bytes=10) catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("expected size rejection")
  }
}

///|
test "version and extension preservation" {
  let n = parse(
    "{\"nbformat\":4,\"nbformat_minor\":6,\"metadata\":{},\"cells\":[],\"extension\":42}",
  )
  assert_eq(n.compatible, false)
  assert_eq(field(n.raw, "extension"), Json::number(42))
}
