import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { resolve } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { createFrontend, limits } from '../tools/python-syntax/frontend.mjs';
import { nbinspect_python_syntax } from '../_build/js/release/build/python_syntax/bridge/bridge.js';

const directory = resolve('_build/python-syntax/tests-' + crypto.randomUUID());
await mkdir(directory, { recursive: true });
const parse = await createFrontend(await readFile('tools/python-syntax/node_modules/tree-sitter-python/tree-sitter-python.wasm'));
const executable = resolve('_build/native/debug/build/cmd/python_syntax_probe/python_syntax_probe.exe');
let cases = 0;
async function both(raw, code) {
  const input = resolve(directory, 'transport.json');
  await writeFile(input, JSON.stringify(raw));
  let native;
  try { native = execFileSync(executable, [input], { encoding: 'utf8', timeout: 10000, windowsHide: true, maxBuffer: 16777216 }); assert.equal(code, 0); }
  catch (error) { assert.equal(error.status, code); native = error.stdout; }
  const js = JSON.parse(nbinspect_python_syntax(JSON.stringify(raw)));
  assert.deepEqual(JSON.parse(native), js);
  cases++; return js;
}
const samples = [
  '', '# comment only', 'x = 1\ny = x + 2\n',
  '# 中文😀\r\n变量 = "😀"\r\nnext = 变量 + 1\r\n',
  'import math as m\nfrom collections import defaultdict\nx = m.sqrt(4)\n',
  'def f(x):\n    return [n * x for n in range(3)]\n\nclass C:\n    pass\n',
  'for x in [1, 2]:\n    if x > 0:\n        print(f"value={x}")\n',
  'text = "fake_name # not a comment"\n# another_name\n',
];
for (const source of samples) {
  const doc = await both(parse(source), 0);
  assert.equal(doc.status, 'parsed'); assert.equal(doc.source, source);
  for (const node of doc.nodes) {
    const bytes = Buffer.from(source);
    assert.doesNotThrow(() => new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(node.start.byte_offset, node.end.byte_offset)));
  }
}
for (const source of ['   ', '\n\n', '\ufeffx=1\n']) {
  const doc = await both(parse(source), 0);
  assert.equal(doc.source, source);
}
const unicode = await both(parse(samples[3]), 0);
const identifier = unicode.nodes.find(n => n.kind === 'identifier');
assert.equal(identifier.start.byte_offset, Buffer.byteLength('# 中文😀\r\n'));
assert.equal(identifier.end.byte_offset - identifier.start.byte_offset, 6);
assert.equal(identifier.start.line, 1); assert.equal(identifier.start.column, 0);
const textOnly = await both(parse(samples[7]), 0);
assert.equal(textOnly.nodes.filter(n => n.kind === 'identifier').length, 1);
assert.ok(textOnly.nodes.some(n => n.kind === 'assignment'));
assert.ok(textOnly.nodes.some(n => n.field_name === 'left'));
assert.ok(textOnly.nodes.some(n => n.field_name === 'right'));
for (const source of ['x = (', 'def :\n pass', 'if x\n    pass\n', '%time x = 1\n', '!ls\n']) {
  const doc = await both(parse(source), 1);
  assert.equal(doc.status, 'parse-errors'); assert.ok(doc.diagnostics.length);
}
const base = parse('x = 1\n');
for (const mutate of [
  r => { r.schema_version = 2; }, r => { r.parser = 'unknown'; },
  r => { r.nodes[0].parent = 0; }, r => { r.nodes[0].kind = 'identifier'; },
  r => { r.nodes[1].parent = 100; }, r => { r.nodes[1].start.line = 100; },
  r => { r.nodes[1].start.column = 1; }, r => { r.nodes[1].end.byte_offset = 100; },
  r => { r.nodes[1].missing = 'false'; }, r => { r.nodes[1].extra = true; },
  r => { r.nodes[1].field_name = ''; }, r => { r.nodes[2].parent = null; },
  r => { r.root_has_error = true; },
  r => { r.nodes[4].start = r.nodes[3].start; },
  r => { r.nodes[4].parent = 0; r.nodes[5].parent = 2; },
]) {
  const raw = structuredClone(base); mutate(raw);
  assert.equal(typeof (await both(raw, 2)).error, 'string');
}
const tooMany = structuredClone(base);
tooMany.nodes = Array(limits.nodes + 1).fill(base.nodes[0]);
assert.match((await both(tooMany, 2)).error, /node count/);
const deep = structuredClone(base);
deep.nodes = Array.from({ length: 258 }, (_, i) => ({ ...base.nodes[0], kind: i ? 'parenthesized_expression' : 'module', parent: i ? i - 1 : null }));
assert.match((await both(deep, 2)).error, /depth/);
assert.throws(() => parse('x'.repeat(limits.sourceBytes + 1)), /1 MiB/);
assert.throws(() => parse('中'.repeat(400000)), /1 MiB/);
assert.throws(() => parse('\ud800'), /Unicode/);
assert.throws(() => parse('('.repeat(300) + 'x' + ')'.repeat(300)), /depth/);
assert.throws(() => parse('x=1\n'.repeat(12000)), /node count/);
const previousClock = Object.getOwnPropertyDescriptor(performance, 'now');
let ticks = 0;
try {
  Object.defineProperty(performance, 'now', { configurable: true, value: () => (ticks += 2000) });
  assert.throws(() => parse('x=1\n'.repeat(4000)), /timed out|no tree/);
} finally {
  if (previousClock) Object.defineProperty(performance, 'now', previousClock); else delete performance.now;
}
assert.equal((await both(parse('x=1\n'), 0)).status, 'parsed');

// Parsing callable-looking code must not cause filesystem side effects.
const marker = resolve(directory, 'MUST-NOT-EXIST');
await both(parse('__import__("pathlib").Path(' + JSON.stringify(marker) + ').write_text("executed")\n'), 0);
await assert.rejects(access(marker));
// The public probe exercises actual files, both hosts, output creation and exits.
const sourceFile = resolve(directory, '输入 😀.py');
await writeFile(sourceFile, samples[3]);
for (const backend of ['js', 'native']) {
  const run = spawnSync(process.execPath, ['tools/python-syntax/probe.mjs', sourceFile, '--backend', backend], { encoding: 'utf8', timeout: 15000, windowsHide: true });
  assert.equal(run.status, 0, run.stderr); assert.equal(JSON.parse(run.stdout).status, 'parsed');
}
await writeFile(sourceFile, 'x = (');
for (const backend of ['js', 'native']) {
  const run = spawnSync(process.execPath, ['tools/python-syntax/probe.mjs', sourceFile, '--backend', backend], { encoding: 'utf8', timeout: 15000, windowsHide: true });
  assert.equal(run.status, 1, run.stderr); assert.equal(JSON.parse(run.stdout).status, 'parse-errors');
}
await writeFile(sourceFile, Buffer.from([0xff]));
const invalid = spawnSync(process.execPath, ['tools/python-syntax/probe.mjs', sourceFile], { encoding: 'utf8', timeout: 15000, windowsHide: true });
assert.equal(invalid.status, 2);
console.log('Python syntax: ' + cases + ' native/JS parity cases, real WASM grammar, Unicode/CRLF, fields, recovery, corrupt transports, resource limits, no execution and CLI exits passed');
