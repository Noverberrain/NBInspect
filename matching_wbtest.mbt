///|
fn book(
  items : Array[(String, String)],
  minor? : Int = 5,
) -> Notebook raise InputError {
  let cells : Array[Json] = items.map(fn(pair) {
    let v : Json = {
      "cell_type": "markdown",
      "id": pair.0,
      "metadata": {},
      "source": pair.1,
    }
    v
  })
  let v : Json = {
    "nbformat": 4,
    "nbformat_minor": minor,
    "metadata": {},
    "cells": cells,
  }
  parse(v.stringify())
}

///|
test "insertion does not move following cells" {
  let r = match_cells(
    book([("a", "A"), ("b", "B")]),
    book([("x", "X"), ("a", "A"), ("b", "B")]),
  )
  assert_eq(r.added, [0])
  assert_eq(r.pairs.filter(fn(p) { p.moved }).length(), 0)
}

///|
test "identity allows movement and modification" {
  let r = match_cells(
    book([("a", "A"), ("b", "B"), ("c", "C")]),
    book([("b", "changed"), ("c", "C"), ("a", "A")]),
  )
  assert_eq(r.pairs.length(), 3)
  assert_eq(r.pairs.filter(fn(p) { p.moved }).length(), 1)
}

///|
test "duplicate contents remain ambiguous without usable IDs" {
  let r = match_cells(
    book([("bad id", "same"), ("bad id", "same")]),
    book([("bad id", "same"), ("bad id", "same")]),
  )
  assert_eq(r.pairs.length(), 0)
  assert_eq(r.ambiguous.length(), 2)
}

///|
test "similarity matching is mutual and bounded" {
  let r = match_cells(
    book([("a", "one\ntwo\nthree")]),
    book([("b", "one\ntwo\nfour")]),
    threshold=0.4,
  )
  assert_eq(r.pairs[0].basis, "similarity")
  try
    match_cells(
      book([("a", "A"), ("b", "B")]),
      book([("c", "C"), ("d", "D")]),
      max_candidates=1,
    )
  catch {
    Invalid(s) => assert_true(s.contains("budget"))
  } noraise {
    _ => fail("expected budget failure")
  }
}
