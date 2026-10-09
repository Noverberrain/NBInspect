import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { nbinspect_analyze, nbinspect_render_report, nbinspect_review, nbinspect_render_review, nbinspect_analyze_with_policy, nbinspect_review_with_policy, nbinspect_parse_policy } from '../web/nbinspect.js';

const cell = (id, source) => ({ id, cell_type: 'code', source, metadata: {}, execution_count: null, outputs: [] });
const notebook = cells => JSON.stringify({ nbformat: 4, nbformat_minor: 5, metadata: {}, cells });
const before = notebook([cell('setup', 'x = 1\n'), cell('print', 'print(x)\n')]);
const after = notebook([cell('print', 'print(x + 1)\n'), cell('setup', 'x = 1\n')]);

const check = JSON.parse(nbinspect_analyze(before, '', 'all'));
assert.equal(check.kind, 'check');
assert.equal(check.cell_count, 2);
const diff = JSON.parse(nbinspect_analyze(before, after, 'all'));
assert.equal(diff.kind, 'diff');
assert.ok(diff.visible_changes >= 1);
assert.equal(diff.matches.length, 2);
const bad = JSON.parse(nbinspect_analyze('{', '', 'all'));
assert.ok(bad.error);
const html = nbinspect_render_report(JSON.stringify(diff));
assert.match(html, /<!doctype html>/i);
assert.match(html, /Matching evidence/);


const errorCell = (id, source, message) => ({
  ...cell(id, source),
  outputs: [{ output_type: 'error', ename: 'DemoError', evalue: message, traceback: [] }],
});
const riskBefore = notebook([
  errorCell('same', 'same()', 'old same'),
  errorCell('fixed', 'fixed()', 'old fixed'),
  cell('new', 'new()'),
  errorCell(undefined, 'alpha()', 'old uncertain'),
]);
const riskAfter = notebook([
  cell('fixed', 'fixed()'),
  errorCell('same', 'same()', 'old same'),
  errorCell('new', 'new()', '<script>new error</script>'),
  errorCell(undefined, 'omega()', 'new uncertain'),
]);
const review = JSON.parse(nbinspect_review(riskBefore, riskAfter));
assert.equal(review.kind, 'review');
assert.equal(review.status, 'passed'); // Warning-only additions do not block at error.
for (const status of ['introduced', 'existing', 'resolved', 'uncertain']) {
  assert.ok(review.summary[status] > 0, status);
  const filtered = nbinspect_render_review(JSON.stringify(review), status);
  assert.match(filtered, new RegExp('Visible risks: ' + review.summary[status] + '<'));
  assert.match(filtered, /Matching evidence/);
  for (const other of ['introduced', 'existing', 'resolved', 'uncertain']) {
    assert.equal(filtered.includes('<h3>' + other + '</h3>'), other === status);
  }
}
const fullReviewHtml = nbinspect_render_report(JSON.stringify(review));
const hostile = structuredClone(review);
hostile.changes.find(change => change.status === 'introduced').after.message = '<script>new error</script>';
const escaped = nbinspect_render_report(JSON.stringify(hostile));
assert.match(escaped, /&lt;script&gt;new error/);
assert.ok(!escaped.includes('<script>new error'));
assert.ok(fullReviewHtml.includes('<h3>resolved</h3>'));
const cleanId = notebook([cell('stable', 'same source')]);
const missingId = JSON.parse(cleanId);
delete missingId.cells[0].id;
const blockedReview = JSON.parse(nbinspect_review(cleanId, JSON.stringify(missingId)));
assert.equal(blockedReview.status, 'blocked');
assert.ok(blockedReview.changes.some(change => change.status === 'introduced' && change.after?.code === 'FMT002'));
assert.ok(JSON.parse(nbinspect_review('{', riskAfter)).error);
assert.ok(JSON.parse(nbinspect_review(riskBefore, '')).error);
const unsupported = JSON.parse(riskAfter);
unsupported.nbformat_minor = 6;
assert.ok(JSON.parse(nbinspect_review(riskBefore, JSON.stringify(unsupported))).error);
assert.ok(JSON.parse(nbinspect_review(' '.repeat(10485761), riskAfter)).error);
assert.match(nbinspect_render_review(JSON.stringify({ ...review, changes: [] }), 'introduced'), /No risks in this view/);

// Browser policies must use the same effective settings and reports as the native CLI.
const policyBefore = notebook([cell('stable', 'same()')]);
const policyAfter = notebook([errorCell('stable', 'same()', 'saved error')]);
await mkdir('_build/browser-policy-fixtures', { recursive: true });
await writeFile('_build/browser-policy-fixtures/before.ipynb', policyBefore);
await writeFile('_build/browser-policy-fixtures/after.ipynb', policyAfter);
const { spawnSync } = await import('node:child_process');
for (const name of ['teaching', 'research', 'sharing']) {
  const policyPath = 'configs/' + name + '.json';
  const input = await readFile(policyPath, 'utf8');
  const effective = JSON.parse(nbinspect_parse_policy(input));
  assert.ok(!effective.error, name);
  for (const mode of ['check', 'review']) {
    const report = JSON.parse(mode === 'check'
      ? nbinspect_analyze_with_policy(policyAfter, '', 'all', input)
      : nbinspect_review_with_policy(policyBefore, policyAfter, input));
    const args = [mode, ...(mode === 'check'
      ? ['_build/browser-policy-fixtures/after.ipynb']
      : ['_build/browser-policy-fixtures/before.ipynb', '_build/browser-policy-fixtures/after.ipynb']), '--config', policyPath, '--format', 'json'];
    const native = spawnSync('_build/native/debug/build/cmd/nbinspect/nbinspect.exe', args, { encoding: 'utf8' });
    assert.equal(native.status, report.status === 'blocked' ? 1 : 0, native.stderr);
    assert.deepEqual(report, JSON.parse(native.stdout), name + ' ' + mode);
    assert.deepEqual(report.policy, effective);
    assert.match(nbinspect_render_report(JSON.stringify(report)), new RegExp(effective.fail_on));
  }
}
assert.equal(JSON.parse(nbinspect_review_with_policy(policyBefore, policyAfter, '{"fail_on":"warning"}')).status, 'blocked');
const disabled = JSON.parse(nbinspect_analyze_with_policy(policyAfter, '', 'all', '{"rules":{"OUT001":{"enabled":false}}}'));
assert.ok(!disabled.findings.some(finding => finding.code === 'OUT001'));
const tinyOutputs = JSON.parse(nbinspect_analyze_with_policy(policyAfter, '', 'all', '{"fail_on":"warning","limits":{"max_cell_output_bytes":1,"max_total_output_bytes":1}}'));
assert.equal(tinyOutputs.status, 'blocked');
assert.ok(tinyOutputs.findings.some(finding => finding.code === 'SIZE001'));
assert.deepEqual(JSON.parse(nbinspect_analyze_with_policy(before, after, 'all', '{')), diff);
assert.deepEqual(JSON.parse(nbinspect_analyze_with_policy(before, '', 'all', '')), check);
for (const input of ['', '{', '{"rules":{"FMT001":{"enabled":false}}}', '{"limits":{"max_total_output_bytes":0}}', '{"unknown":1}']) {
  assert.ok(JSON.parse(nbinspect_parse_policy(input)).error, input);
}
assert.match(JSON.parse(nbinspect_parse_policy(' '.repeat(1048577))).error, /1 MiB/);
assert.match(JSON.parse(nbinspect_parse_policy('😀'.repeat(262145))).error, /1 MiB/);
assert.match(JSON.parse(nbinspect_review_with_policy(policyBefore, policyAfter, '{"rules":{"BAD001":{}}}')).error, /BAD001/);

// Exercise the actual Worker protocol, including cached rendering without rerunning analysis.
const { resolve } = await import('node:path');
const { pathToFileURL } = await import('node:url');
let posted = null;
globalThis.self = { postMessage: message => { posted = message; } };
const moduleUrl = pathToFileURL(resolve('web/nbinspect.js')).href;
const source = (await readFile('web/worker.js', 'utf8')).replace("'./nbinspect.js'", JSON.stringify(moduleUrl));
await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
self.onmessage({ data: { mode: 'review', before: riskBefore, after: riskAfter, riskStatus: 'all' } });
assert.equal(posted.report.kind, 'review');
const complete = JSON.stringify(posted.report);
const exportHtml = posted.html;
assert.equal(posted.displayHtml, exportHtml);
self.onmessage({ data: { mode: 'render', riskStatus: 'introduced' } });
assert.equal(posted.filtered, true);
assert.equal(posted.riskStatus, 'introduced');
assert.ok(!posted.displayHtml.includes('<h3>resolved</h3>'));
assert.ok(exportHtml.includes('<h3>resolved</h3>'));
self.onmessage({ data: { mode: 'render', riskStatus: 'all' } });
assert.equal(posted.displayHtml, exportHtml);
assert.equal(complete, JSON.stringify(review));
self.onmessage({ data: { mode: 'check', before, after: '', view: 'all' } });
assert.equal(posted.report.kind, 'check');
self.onmessage({ data: { mode: 'render', riskStatus: 'all' } });
assert.ok(posted.error);
self.onmessage({ data: { mode: 'policy', input: '{"fail_on":"warning"}' } });
assert.equal(posted.policy.fail_on, 'warning');
self.onmessage({ data: { mode: 'review', before: policyBefore, after: policyAfter, policy: '{"fail_on":"warning"}', riskStatus: 'all' } });
assert.equal(posted.report.status, 'blocked');
assert.equal(posted.report.policy.fail_on, 'warning');
const policyHtml = posted.html;
self.onmessage({ data: { mode: 'render', riskStatus: 'introduced' } });
assert.equal(posted.filtered, true);
assert.match(policyHtml, /warning/);
self.onmessage({ data: { mode: 'policy', input: '{"rules":{"FMT002":{"severity":"info"}}}' } });
assert.match(posted.error, /FMT002/);
delete globalThis.self;
console.log('Browser policies: three templates match native CLI check/review, limits, disabled rules, strict validation and Worker protocol passed');
console.log('Browser MoonBit bridge and Worker: check, diff, review, all risk filters, input limits, diagnostics, escaped HTML passed');
