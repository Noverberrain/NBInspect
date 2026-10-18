import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, access } from 'node:fs/promises';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createFrontend } from '../tools/python-syntax/frontend.mjs';
import { nbinspect_python_bindings } from '../_build/js/release/build/python_syntax/bridge/bridge.js';

const directory = resolve('_build/python-bindings/' + crypto.randomUUID());
await mkdir(directory, { recursive: true });
const parse = await createFrontend(await readFile('tools/python-syntax/node_modules/tree-sitter-python/tree-sitter-python.wasm'));
const executable = resolve('_build/native/debug/build/cmd/python_syntax_probe/python_syntax_probe.exe');
const oracle = process.argv.includes('--python-oracle');
let cases = 0, oracleCases = 0;
async function analyze(source, expectedStatus, compareOracle = false) {
  const raw = JSON.stringify(parse(source));
  const path = resolve(directory, 'transport.json'); await writeFile(path, raw);
  const native = spawnSync(executable, [path, '--bindings'], { encoding: 'utf8', timeout: 10000, windowsHide: true, maxBuffer: 16777216 });
  assert.equal(native.status, expectedStatus === 'modeled' ? 0 : 1, native.stderr);
  const report = JSON.parse(nbinspect_python_bindings(raw));
  assert.deepEqual(JSON.parse(native.stdout), report);
  assert.equal(report.status, expectedStatus); assert.equal(report.kind, 'python-bindings');
  assert.equal(report.source, source);
  const events = [...report.definitions, ...report.references, ...report.uncertainties].sort((a, b) => a.order - b.order);
  assert.deepEqual(events.map(e => e.order), events.map((_, i) => i));
  for (const reference of report.references) {
    if (reference.resolution === 'bound') {
      const definition = report.definitions[reference.definition];
      assert.equal(definition.name, reference.name); assert.ok(definition.order < reference.order);
    } else assert.equal(reference.definition, undefined);
    assert.equal(Buffer.from(source).subarray(reference.start.byte_offset, reference.end.byte_offset).toString(), reference.name);
  }
  if (oracle && compareOracle) {
    const result = spawnSync('python', ['scripts/binding_reference.py'], { input: source, encoding: 'utf8', timeout: 10000, windowsHide: true });
    assert.equal(result.status, 0, result.stderr);
    const expected = JSON.parse(result.stdout);
    const roles = [...report.definitions.map(d => ({ name: d.name, role: 'Store', line: d.start.line, column: d.start.column })),
      ...report.references.filter(r => r.context !== 'augmented-target').map(r => ({ name: r.name, role: 'Load', line: r.start.line, column: r.start.column }))]
      .sort((a, b) => a.line - b.line || a.column - b.column || a.role.localeCompare(b.role));
    assert.deepEqual(roles, expected.roles); oracleCases++;
  }
  cases++; return report;
}
let report = await analyze('x=1\ny=x+1\nx=2\nz=x\n', 'modeled', true);
assert.deepEqual(report.definitions.map(d => [d.name,d.version]), [['x',1],['y',1],['x',2],['z',1]]);
assert.deepEqual(report.references.map(r => r.definition), [0,2]);
report = await analyze('x=x\n', 'modeled', true);
assert.equal(report.references[0].resolution, 'external');
assert.ok(report.references[0].order < report.definitions[0].order);
report = await analyze('a=b=outside\n', 'modeled', true);
assert.deepEqual(report.definitions.map(d => d.name), ['a','b']);
assert.ok(report.references[0].order < report.definitions[0].order);
report = await analyze('x=1\nx+=x\n', 'modeled', true);
assert.deepEqual(report.references.map(r => r.definition), [0,0]);
assert.equal(report.definitions[1].version, 2);
await analyze('a=1; b=a; a=2; c=a\n', 'modeled', true);
await analyze('a=1\nb=-(a+2)\nc=not b\nd=a < b\n', 'modeled', true);
await analyze('text="fake_name"\n# another_name\npass\n', 'modeled', true);
await analyze('a=1\nb=[a,2]\nc=(a,3)\nd={"key":a}\ne={a,3}\n', 'modeled', true);
await analyze('# 中文😀\r\nx=1\r\ny=x\r\n', 'modeled', true);
await analyze('', 'modeled', true);
report = await analyze('x=1\ny=f(key=x)\nz=x\nw=y\nx=2\nk=x\n', 'incomplete', true);
assert.deepEqual(report.references.map(r => [r.name,r.resolution]), [['f','external'],['x','bound'],['x','unknown-after-barrier'],['y','bound'],['x','bound']]);
assert.ok(!report.references.some(r => r.name === 'key'));
assert.equal(report.definitions.filter(d => d.name === 'x')[1].version, 2);
report = await analyze('x=1\nx+=f(x)\n', 'incomplete', true);
assert.equal(report.references[0].context, 'augmented-target');
assert.equal(report.references[2].definition, 0);
report = await analyze('value=obj.attr[idx]\n', 'incomplete', true);
assert.deepEqual(report.references.map(r => r.name), ['obj','idx']);
assert.ok(!report.references.some(r => r.name === 'attr'));
for (const source of ['if condition:\n    x=hidden\ny=x\n', 'for x in hidden:\n    y=x\nz=x\n', 'def f(arg):\n    return hidden+arg\ny=f\n', 'class C:\n    x=hidden\ny=C\n']) {
  report = await analyze(source, 'incomplete');
  assert.ok(!report.references.some(r => ['hidden','arg','condition'].includes(r.name)));
  assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
}
for (const source of ['x=1\ny=[x for x in items]\nz=x\n', 'x=1\ny=lambda arg: hidden\nz=x\n', 'x=1\ny=(x:=2)\nz=x\n', 'x=1\ny=x and other\nz=x\n', 'x=1\ny=1 < x < 3\nz=x\n', 'x=1\ny=f"{x}"\nz=x\n', 'x=1\nx: int=2\ny=x\n', 'x=1\na,b=values\ny=x\n', 'x=1\nobj.attr=2\ny=x\n', 'x=1\nimport module\ny=x\n', 'x=1\ndel x\ny=x\n']) {
  report = await analyze(source, 'incomplete');
  assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
}
report = await analyze('x=1\nf(key=x,*items)\ny=x\n', 'incomplete');
assert.ok(report.uncertainties.some(u => u.reason === 'unsupported-call-unpacking'));
assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
report = await analyze('x=1\nK=2\ny=x\n', 'incomplete');
assert.ok(report.uncertainties.some(u => u.reason === 'identifier-normalization-unsupported'));
assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
report = await analyze('x=1\ny=outside+1\nz=x\n', 'incomplete', true);
assert.ok(report.uncertainties.some(u => u.reason === 'dynamic-operator'));
assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
for (const source of ['K=1\nK=2\ny=K\n', 'K=1\ny=K\nz=K\n']) {
  report = await analyze(source, 'incomplete');
  assert.equal(report.references.at(-1).resolution, 'unknown-after-barrier');
}
for (let i=0;i<12;i++) {
  const a='value_'+i,b='copy_'+i,c='result_'+i;
  const newline=i%2?'\r\n':'\n';
  const source=['# rename/spacing case '+i,a+' = 1',b+' = ('+a+')',a+'=2',c+' = '+a+' + '+b,''].join(newline);
  report = await analyze(source,'modeled');
  assert.deepEqual(report.references.map(r=>r.definition),[0,2,1]);
  assert.deepEqual(report.definitions.filter(d=>d.name===a).map(d=>d.version),[1,2]);
}
report = await analyze('x=1\nf(x for x in items)\ny=x\n','incomplete');
assert.ok(report.uncertainties.some(u=>u.reason==='unsupported-call-argument-scope'));
assert.ok(!report.references.some(r=>r.name==='items'));
assert.equal(report.references.at(-1).resolution,'unknown-after-barrier');
report = await analyze('x=1\ny={opaque,x}\n','incomplete');
assert.equal(report.references.at(-1).resolution,'unknown-after-barrier');
report = await analyze('x=(\n', 'incomplete');
assert.equal(report.definitions.length, 0); assert.equal(report.references.length, 0);
assert.ok(report.syntax_diagnostics.length);
const marker = resolve(directory,'MUST-NOT-EXIST');
await analyze('__import__("pathlib").Path('+JSON.stringify(marker)+').write_text("executed")\n', 'incomplete');
await assert.rejects(access(marker));
const sourceFile = resolve(directory,'names.py');
for (const [source,code] of [['x=1\ny=x\n',0],['x=f()\n',1],['x=(\n',1]]) {
  await writeFile(sourceFile,source);
  for (const backend of ['js','native']) {
    const run = spawnSync(process.execPath,['tools/python-syntax/probe.mjs',sourceFile,'--backend',backend,'--mode','bindings'],{encoding:'utf8',timeout:15000,windowsHide:true});
    assert.equal(run.status,code,run.stderr); assert.equal(JSON.parse(run.stdout).kind,'python-bindings');
  }
}
console.log('Python bindings: '+cases+' native/JS cases, assignment/read order, versions, barriers, scoped unknowns, CST evidence, no execution and CLI modes passed; CPython AST role comparisons: '+oracleCases);
