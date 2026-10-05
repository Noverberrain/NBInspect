///|
pub(all) struct CellMatch {
  before : Int
  after : Int
  basis : String
  score : Double
  moved : Bool
}

///|
pub(all) struct MatchResult {
  pairs : Array[CellMatch]
  deleted : Array[Int]
  added : Array[Int]
  ambiguous : Array[Int]
}

///|
fn unique_id(cells : Array[Cell], id : String) -> Bool {
  valid_id(id) && cells.filter(fn(c) { c.id == Some(id) }).length() == 1
}

///|
fn similarity(a : String, b : String) -> Double {
  // Bounded line-set Jaccard; code whitespace is retained.
  let aa = a.split("\n").map(fn(s) { s.to_owned() })
  let bb = b.split("\n").map(fn(s) { s.to_owned() })
  let aset : Map[String, Bool] = Map([])
  let bset : Map[String, Bool] = Map([])
  for s in aa {
    aset[s] = true
  }
  for s in bb {
    bset[s] = true
  }
  let mut common = 0
  for s, _ in aset {
    if bset.contains(s) {
      common += 1
    }
  }
  let union = aset.length() + bset.length() - common
  if union == 0 {
    1.0
  } else {
    common.to_double() / union.to_double()
  }
}

///|
/// Identity first, then unique exact source, then mutual unambiguous similarity.
/// Candidate search is bounded; unresolved duplicates remain additions/deletions.
pub fn match_cells(
  a : Notebook,
  b : Notebook,
  threshold? : Double = 0.6,
  margin? : Double = 0.15,
  max_candidates? : Int = 1000000,
) -> MatchResult raise InputError {
  if threshold < 0.0 || threshold > 1.0 || margin < 0.0 || max_candidates <= 0 {
    raise Invalid("invalid matching options")
  }
  let left = Array::make(a.cells.length(), -1)
  let right = Array::make(b.cells.length(), -1)
  let methods = Array::make(a.cells.length(), "")
  let scores = Array::make(a.cells.length(), 0.0)
  let ambiguous : Array[Int] = []
  let mut attempts = 0
  for i, c in a.cells {
    if c.id is Some(id) && unique_id(a.cells, id) && unique_id(b.cells, id) {
      for j, d in b.cells {
        if d.id == Some(id) {
          left[i] = j
          right[j] = i
          methods[i] = "id"
          scores[i] = 1.0
        }
      }
    }
  }
  for i, c in a.cells {
    if left[i] < 0 {
      let candidates : Array[Int] = []
      for j, d in b.cells {
        if right[j] < 0 {
          attempts += 1
          if attempts > max_candidates {
            raise Invalid("matching candidate budget exceeded")
          }
          if c.kind == d.kind && c.source == d.source {
            candidates.push(j)
          }
        }
      }
      if candidates.length() == 1 {
        let j = candidates[0]
        let reverse = a.cells.filter(fn(x) {
          left[x.index] < 0 && x.kind == c.kind && x.source == c.source
        })
        if reverse.length() == 1 {
          left[i] = j
          right[j] = i
          methods[i] = "exact"
          scores[i] = 1.0
        }
      }
    }
  }
  let best_left = Array::make(a.cells.length(), -1)
  let best_right = Array::make(b.cells.length(), -1)
  let best_score = Array::make(a.cells.length(), 0.0)
  let gaps = Array::make(a.cells.length(), 0.0)
  for i, c in a.cells {
    if left[i] < 0 {
      let mut best = -1.0
      let mut second = -1.0
      for j, d in b.cells {
        if right[j] < 0 && c.kind == d.kind {
          attempts += 1
          if attempts > max_candidates {
            raise Invalid("matching candidate budget exceeded")
          }
          if c.source.length() > 100000 || d.source.length() > 100000 {
            raise Invalid("similarity text limit exceeded")
          }
          let s = similarity(c.source, d.source)
          if s > best {
            second = best
            best = s
            best_left[i] = j
          } else if s > second {
            second = s
          }
        }
      }
      best_score[i] = best
      gaps[i] = best - second
    }
  }
  for j, d in b.cells {
    if right[j] < 0 {
      let mut best = -1.0
      let mut second = -1.0
      let mut bi = -1
      for i, c in a.cells {
        if left[i] < 0 && c.kind == d.kind {
          attempts += 1
          if attempts > max_candidates {
            raise Invalid("matching candidate budget exceeded")
          }
          let s = similarity(c.source, d.source)
          if s > best {
            second = best
            best = s
            bi = i
          } else if s > second {
            second = s
          }
        }
      }
      if best >= threshold && best - second >= margin {
        best_right[j] = bi
      }
    }
  }
  for i, j in best_left {
    if j >= 0 && best_score[i] >= threshold {
      if gaps[i] >= margin && best_right[j] == i {
        left[i] = j
        right[j] = i
        methods[i] = "similarity"
        scores[i] = best_score[i]
      } else {
        ambiguous.push(i)
      }
    }
  }
  // LIS on matched target positions; insertion alone never changes relative order.
  let ordered : Array[Int] = []
  for i, j in left {
    if j >= 0 {
      ordered.push(i)
    }
  }
  let lengths = Array::make(ordered.length(), 1)
  let prev = Array::make(ordered.length(), -1)
  let mut end = -1
  for p, i in ordered {
    for q = 0; q < p; q = q + 1 {
      if left[ordered[q]] < left[i] && lengths[q] + 1 > lengths[p] {
        lengths[p] = lengths[q] + 1
        prev[p] = q
      }
    }
    if end < 0 || lengths[p] > lengths[end] {
      end = p
    }
  }
  let stationary : Map[Int, Bool] = Map([])
  while end >= 0 {
    stationary[ordered[end]] = true
    end = prev[end]
  }
  let pairs : Array[CellMatch] = []
  let deleted : Array[Int] = []
  let added : Array[Int] = []
  for i, j in left {
    if j >= 0 {
      pairs.push({
        before: i,
        after: j,
        basis: methods[i],
        score: scores[i],
        moved: !stationary.contains(i),
      })
    } else {
      deleted.push(i)
    }
  }
  for j, i in right {
    if i < 0 {
      added.push(j)
    }
  }
  { pairs, deleted, added, ambiguous, }
}
