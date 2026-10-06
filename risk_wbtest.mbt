///|
fn risk_findings(
  review : RiskReview,
  code : String,
  status : String,
) -> Array[RiskChange] {
  review.changes.filter(fn(change) {
    if change.status != status {
      return false
    }
    match change.after {
      Some(f) => f.code == code
      None =>
        match change.before {
          Some(f) => f.code == code
          None => false
        }
    }
  })
}

///|
fn risk_code_book(outputs : Array[Json]) -> Notebook raise InputError {
  let value : Json = {
    "nbformat": 4,
    "nbformat_minor": 5,
    "metadata": {},
    "cells": [
      {
        "cell_type": "code",
        "id": "a",
        "metadata": {},
        "source": "print(1)",
        "execution_count": null,
        "outputs": outputs,
      },
    ],
  }
  parse(value.stringify())
}

///|
test "moving a cell keeps its publication warning existing" {
  let source = "![missing](attachment:x.png)"
  let before = book([("a", "A"), ("b", source)])
  let after = book([("b", source), ("a", "A")])
  let review = review_risks(before, after)
  let existing = risk_findings(review, "ATT001", "existing")
  assert_eq(existing.length(), 1)
  assert_eq(existing[0].match_basis, Some("id"))
  assert_true(
    existing[0].before.unwrap().path != existing[0].after.unwrap().path,
  )
  assert_eq(risk_findings(review, "ATT001", "introduced").length(), 0)
  assert_eq(risk_findings(review, "ATT001", "resolved").length(), 0)
}

///|
test "new and fixed broken attachments are distinguished" {
  let clean = book([("a", "plain")])
  let broken = book([("a", "![missing](attachment:x.png)")])
  let added = review_risks(clean, broken)
  assert_eq(risk_findings(added, "ATT001", "introduced").length(), 1)
  let fixed = review_risks(broken, clean)
  assert_eq(risk_findings(fixed, "ATT001", "resolved").length(), 1)
}

///|
test "repeated findings are paired by count within a matched cell" {
  let one = book([("a", "![x](attachment:x.png)")])
  let two = book([("a", "![x](attachment:x.png) ![y](attachment:y.png)")])
  let review = review_risks(one, two)
  assert_eq(risk_findings(review, "ATT001", "existing").length(), 1)
  assert_eq(risk_findings(review, "ATT001", "introduced").length(), 1)
}

///|
test "output index changes do not invent a new exception" {
  let error_output : Json = {
    "output_type": "error",
    "ename": "DemoError",
    "evalue": "demo",
    "traceback": [],
  }
  let stream : Json = {
    "output_type": "stream",
    "name": "stdout",
    "text": "hello",
  }
  let before = risk_code_book([error_output])
  let after = risk_code_book([stream, error_output])
  let review = review_risks(before, after)
  let existing = risk_findings(review, "OUT001", "existing")
  assert_eq(existing.length(), 1)
  assert_true(
    existing[0].before.unwrap().path != existing[0].after.unwrap().path,
  )
  assert_eq(risk_findings(review, "OUT001", "introduced").length(), 0)
}

///|
test "new code exception and structural ID error are introduced" {
  let error_output : Json = {
    "output_type": "error",
    "ename": "DemoError",
    "evalue": "demo",
    "traceback": [],
  }
  let review = review_risks(risk_code_book([]), risk_code_book([error_output]))
  assert_eq(risk_findings(review, "OUT001", "introduced").length(), 1)
  let id_review = review_risks(
    book([("a", "text")]),
    book([("bad id", "text")]),
  )
  let invalid = risk_findings(id_review, "FMT002", "introduced")
  assert_eq(invalid.length(), 1)
  assert_eq(invalid[0].match_basis, Some("exact"))
}

///|
test "unmatched cells with possible counterparts remain uncertain" {
  let before = book([("bad id", "same"), ("bad id", "same")])
  let after = book([("bad id", "same"), ("bad id", "same")])
  let review = review_risks(before, after)
  assert_eq(review.matches.pairs.length(), 0)
  assert_true(risk_findings(review, "FMT002", "uncertain").length() > 0)
  assert_eq(risk_findings(review, "FMT002", "introduced").length(), 0)
  assert_eq(risk_findings(review, "FMT002", "resolved").length(), 0)
}

///|
test "isolated added and deleted cells have definite risk changes" {
  let clean = book([])
  let broken = book([("a", "![missing](attachment:x.png)")])
  assert_eq(
    risk_findings(review_risks(clean, broken), "ATT001", "introduced").length(),
    1,
  )
  assert_eq(
    risk_findings(review_risks(broken, clean), "ATT001", "resolved").length(),
    1,
  )
}

///|
test "unverified Notebook versions are rejected" {
  try review_risks(book([], minor=6), book([])) catch {
    Invalid(message) => assert_true(message.contains("unverified"))
  } noraise {
    _ => fail("expected unverified version rejection")
  }
}

///|
test "replacing a broken attachment is a new risk and a resolved risk" {
  let old = book([("a", "![x](attachment:x.png)")])
  let revised = book([("a", "![y](attachment:y.png)")])
  let review = review_risks(old, revised)
  assert_eq(risk_findings(review, "ATT001", "existing").length(), 0)
  assert_eq(risk_findings(review, "ATT001", "introduced").length(), 1)
  assert_eq(risk_findings(review, "ATT001", "resolved").length(), 1)
}

///|
test "replacing an exception is not counted as the old exception" {
  let first : Json = {
    "output_type": "error",
    "ename": "ValueError",
    "evalue": "bad input",
    "traceback": [],
  }
  let second : Json = {
    "output_type": "error",
    "ename": "ZeroDivisionError",
    "evalue": "division by zero",
    "traceback": [],
  }
  let review = review_risks(risk_code_book([first]), risk_code_book([second]))
  assert_eq(risk_findings(review, "OUT001", "existing").length(), 0)
  assert_eq(risk_findings(review, "OUT001", "introduced").length(), 1)
  assert_eq(risk_findings(review, "OUT001", "resolved").length(), 1)
}

///|
test "moving and editing a cell does not renew the same warning" {
  let old = book([("a", "plain"), ("b", "![x](attachment:x.png)")])
  let revised = book([
    ("b", "Changed text\n![x](attachment:x.png)"),
    ("a", "plain"),
  ])
  let review = review_risks(old, revised)
  let warning = risk_findings(review, "ATT001", "existing")
  assert_eq(warning.length(), 1)
  assert_eq(warning[0].match_basis, Some("id"))
  assert_eq(risk_findings(review, "ATT001", "introduced").length(), 0)
}

///|
test "document metadata warning is compared separately from cells" {
  let complete = parse(
    "{\"nbformat\":4,\"nbformat_minor\":5,\"metadata\":{\"kernelspec\":{},\"language_info\":{}},\"cells\":[]}",
  )
  let absent = book([])
  assert_eq(
    risk_findings(review_risks(complete, absent), "META001", "introduced").length(),
    1,
  )
  assert_eq(
    risk_findings(review_risks(absent, complete), "META001", "resolved").length(),
    1,
  )
}
