///|
test "saved exceptions are warnings and metadata absence is informational" {
  let n = parse(
    "{\"nbformat\":4,\"nbformat_minor\":4,\"metadata\":{},\"cells\":[{\"cell_type\":\"code\",\"metadata\":{},\"source\":\"raise Exception()\",\"execution_count\":1,\"outputs\":[{\"output_type\":\"error\",\"ename\":\"Exception\",\"evalue\":\"demo\",\"traceback\":[]}]}]}",
  )
  let f = check(n)
  assert_eq(f.filter(fn(x) { x.code == "OUT001" }).length(), 1)
  assert_eq(blocks(f), false)
  assert_eq(blocks(f, fail_on="warning"), true)
}

///|
test "attachments and output size are policy findings" {
  let n = book([("a", "![missing](attachment:x.png)")])
  assert_eq(check(n).filter(fn(f) { f.code == "ATT001" }).length(), 1)
  let c = parse(fixture(""))
  assert_eq(
    check(c, max_cell_output=1).filter(fn(f) { f.code == "SIZE001" }).length(),
    1,
  )
}

///|
test "rules can be selected and unknown rules rejected" {
  assert_eq(check(book([]), enabled=["OUT001"]).length(), 0)
  try check(book([]), enabled=["TYPO"]) catch {
    Invalid(_) => ()
  } noraise {
    _ => fail("unknown rule must fail")
  }
}

///|
test "old versions do not require cell IDs" {
  let n = parse(
    "{\"nbformat\":4,\"nbformat_minor\":0,\"metadata\":{},\"cells\":[{\"cell_type\":\"markdown\",\"source\":\"text\",\"metadata\":{}}]}",
  )
  assert_eq(n.findings.length(), 0)
}
