import assert from 'node:assert/strict';
import { nbinspect_analyze, nbinspect_render_report, nbinspect_review, nbinspect_render_review } from '../web/nbinspect.js';

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

// Exercise the actual Worker protocol, including cached rendering without rerunning analysis.
const { readFile } = await import('node:fs/promises');
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
delete globalThis.self;
console.log('Browser MoonBit bridge and Worker: check, diff, review, all risk filters, input limits, diagnostics, escaped HTML passed');
