import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { nbinspect_budget, nbinspect_parse_budget, nbinspect_profile_diff, nbinspect_profile, nbinspect_analyze, nbinspect_render_report, nbinspect_review, nbinspect_render_review, nbinspect_analyze_with_policy, nbinspect_review_with_policy, nbinspect_parse_policy } from '../web/nbinspect.js';

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


// Browser profiles must match native reports byte-for-byte in meaning.
const profileInput = notebook([
  { ...cell('resources', ['你好\n', 'print(1)']), outputs: [
    { output_type: 'stream', name: 'stdout', text: ['你好\n'] },
    { output_type: 'display_data', data: { 'image/png': 'base64-placeholder', 'text/html': '<script>hidden-payload</script>' }, metadata: {} },
    { output_type: 'error', ename: 'Demo', evalue: 'hidden-payload', traceback: [] },
  ] },
  { cell_type: 'markdown', id: '<img>', source: 'private-source', metadata: {}, attachments: {
    'a~/~/.png': { 'image/png': 'AAAA' },
    '<script>': { '<svg/onload=alert(1)>': { nested: 'hidden-payload' } },
  } },
]);
await mkdir('_build/browser-profile-fixtures', { recursive: true });
await writeFile('_build/browser-profile-fixtures/profile.ipynb', profileInput);
const browserProfile = JSON.parse(nbinspect_profile(profileInput));
const nativeProfile = spawnSync('_build/native/debug/build/cmd/nbinspect/nbinspect.exe', ['profile', '_build/browser-profile-fixtures/profile.ipynb', '--format', 'json'], { encoding: 'utf8' });
assert.equal(nativeProfile.status, 0, nativeProfile.stderr);
assert.deepEqual(browserProfile, JSON.parse(nativeProfile.stdout));
assert.equal(browserProfile.resource_count, 6);
assert.equal(browserProfile.measurement, 'compact-json-utf8');
assert.ok(!JSON.stringify(browserProfile).includes('hidden-payload'));
assert.ok(!JSON.stringify(browserProfile).includes('private-source'));
const profileHtml = nbinspect_render_report(JSON.stringify(browserProfile));
assert.match(profileHtml, /Cells by size/);
assert.match(profileHtml, /&lt;script&gt;/);
assert.ok(!profileHtml.includes('<script>'));
assert.ok(!profileHtml.includes('<img>'));
assert.equal(JSON.parse(nbinspect_profile(notebook([]))).cell_count, 0);
for (const input of ['', '{', JSON.stringify({ ...JSON.parse(profileInput), nbformat_minor: 6 }), ' '.repeat(10485761), '😀'.repeat(2621441)]) {
  assert.ok(JSON.parse(nbinspect_profile(input)).error);
}
const tooManyResources = notebook([{ ...cell('limit', ''), outputs: Array.from({ length: 10001 }, () => ({ output_type: 'stream', name: 'stdout', text: '' })) }]);
assert.match(JSON.parse(nbinspect_profile(tooManyResources)).error, /resource limit/);
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
self.onmessage({ data: { mode: 'profile', before: profileInput, after: '{', view: 'code', policy: '{' } });
assert.deepEqual(posted.report, browserProfile); // Only the first input is profiled; no policy/diff filter.
assert.equal(posted.html, profileHtml);
assert.equal(posted.displayHtml, profileHtml);
self.onmessage({ data: { mode: 'render', riskStatus: 'all' } });
assert.ok(posted.error); // A profile must not leave the preceding review cached.
self.onmessage({ data: { mode: 'profile', before: '{' } });
assert.ok(posted.error);
self.onmessage({ data: { mode: 'profile', before: notebook([]) } });
assert.equal(posted.report.cell_count, 0);
console.log('Browser profile: native/JS parity, UTF-8 and resource limits, escaped offline HTML, independent Worker mode passed');
// Two-input storage bridge: same reports as native, including signed changes and ambiguity.
const sizeBefore = await readFile('examples/profile-before.ipynb', 'utf8');
const sizeAfter = await readFile('examples/profile-after.ipynb', 'utf8');
for (const [first, second, firstPath, secondPath] of [
  [sizeBefore, sizeAfter, 'examples/profile-before.ipynb', 'examples/profile-after.ipynb'],
  [sizeAfter, sizeBefore, 'examples/profile-after.ipynb', 'examples/profile-before.ipynb'],
]) {
  const result = JSON.parse(nbinspect_profile_diff(first, second));
  const native = spawnSync('_build/native/debug/build/cmd/nbinspect/nbinspect.exe', ['profile-diff', firstPath, secondPath, '--format', 'json'], { encoding: 'utf8' });
  assert.equal(native.status, 0, native.stderr);
  assert.deepEqual(result, JSON.parse(native.stdout));
  assert.equal(result.cells.reduce((total, row) => total + row.delta_bytes, result.container_delta_bytes), result.summary.delta.notebook_bytes);
  assert.ok(result.cells.some(row => row.moved));
}
const sizeReport = JSON.parse(nbinspect_profile_diff(sizeBefore, sizeAfter));
assert.equal(sizeReport.kind, 'profile-diff');
assert.ok(sizeReport.summary.delta.notebook_bytes > 0);
assert.ok(sizeReport.cells.some(row => row.delta_bytes < 0));
assert.equal(JSON.parse(nbinspect_profile_diff(sizeAfter, sizeBefore)).summary.delta.notebook_bytes, -sizeReport.summary.delta.notebook_bytes);
const duplicateCells = notebook([cell(undefined, 'same'), cell(undefined, 'same')]);
const duplicateReport = JSON.parse(nbinspect_profile_diff(duplicateCells, duplicateCells));
assert.deepEqual(duplicateReport.ambiguous_before, [0, 1]);
assert.equal(duplicateReport.matched_count, 0);
assert.equal(duplicateReport.cells.length, 4);
assert.equal(duplicateReport.summary.delta.notebook_bytes, 0);
const equalReport = JSON.parse(nbinspect_profile_diff(before, before));
assert.ok(equalReport.cells.every(row => row.delta_bytes === 0));
assert.equal(equalReport.matched_count, 2);
assert.equal(JSON.parse(nbinspect_profile_diff(notebook([]), notebook([]))).summary.delta.notebook_bytes, 0);
const sizeHtml = nbinspect_render_report(JSON.stringify(sizeReport));
assert.match(sizeHtml, /Cells by absolute size change/);
assert.match(sizeHtml, /Cell measurements and matching evidence/);
const hostileSize = JSON.parse(nbinspect_profile_diff(profileInput, profileInput));
const hostileSizeHtml = nbinspect_render_report(JSON.stringify(hostileSize));
assert.match(hostileSizeHtml, /&lt;img&gt;/);
assert.ok(!/<script|<img|<svg/i.test(hostileSizeHtml));
assert.ok(!hostileSizeHtml.includes('hidden-payload'));
for (const badInput of ['', '{', JSON.stringify({ ...JSON.parse(before), nbformat_minor: 6 }), ' '.repeat(10485761), '😀'.repeat(2621441), tooManyResources]) {
  for (const [first, second] of [[badInput, before], [before, badInput]]) {
    assert.ok(JSON.parse(nbinspect_profile_diff(first, second)).error);
  }
}
const budgetBefore = notebook(Array.from({ length: 1100 }, (_, i) => cell(undefined, 'old_' + i)));
const budgetAfter = notebook(Array.from({ length: 1100 }, (_, i) => cell(undefined, 'new_' + i)));
assert.match(JSON.parse(nbinspect_profile_diff(budgetBefore, budgetAfter)).error, /candidate budget exceeded/);
self.onmessage({ data: { mode: 'review', before: riskBefore, after: riskAfter, riskStatus: 'all' } });
self.onmessage({ data: { mode: 'profile-diff', before: sizeBefore, after: sizeAfter, view: 'code', riskStatus: 'introduced', policy: '{' } });
assert.deepEqual(posted.report, sizeReport);
assert.equal(posted.html, sizeHtml);
assert.equal(posted.displayHtml, sizeHtml);
self.onmessage({ data: { mode: 'render', riskStatus: 'all' } });
assert.ok(posted.error); // No stale risk-review cache after a size comparison.
for (const [first, second] of [['{', sizeAfter], [sizeBefore, '{']]) {
  self.onmessage({ data: { mode: 'profile-diff', before: first, after: second } });
  assert.ok(posted.error);
}
console.log('Browser profile-diff: native parity in both directions, zero/negative changes, movement, ambiguous duplicates, both-input limits, matching budget, escaped HTML and Worker isolation passed');
// Browser budgets use exactly the native allowances and complete comparison evidence.
const importedBudget = await readFile('configs/growth-budget.json', 'utf8');
const effectiveBudget = JSON.parse(nbinspect_parse_budget(importedBudget));
assert.deepEqual(effectiveBudget, JSON.parse(importedBudget));
const allowedBudget = JSON.parse(nbinspect_budget(sizeBefore, sizeAfter, importedBudget));
const nativeBudget = spawnSync('_build/native/debug/build/cmd/nbinspect/nbinspect.exe', ['budget', 'examples/profile-before.ipynb', 'examples/profile-after.ipynb', '--config', 'configs/growth-budget.json', '--format', 'json'], { encoding: 'utf8' });
assert.equal(nativeBudget.status, 0, nativeBudget.stderr);
assert.deepEqual(allowedBudget, JSON.parse(nativeBudget.stdout));
const noGrowth = '{"limits":{"max_notebook_growth_bytes":0,"max_output_growth_bytes":0,"max_attachment_growth_bytes":0}}';
const deniedBudget = JSON.parse(nbinspect_budget(sizeBefore, sizeAfter, noGrowth));
assert.equal(deniedBudget.status, 'blocked');
assert.equal(deniedBudget.exceeded_count, 3);
assert.deepEqual(deniedBudget.comparison, sizeReport);
assert.equal(JSON.parse(nbinspect_budget(sizeAfter, sizeBefore, noGrowth)).status, 'passed');
assert.equal(JSON.parse(nbinspect_budget(sizeBefore, sizeBefore, noGrowth)).status, 'passed');
assert.deepEqual(JSON.parse(nbinspect_parse_budget('{"limits":{"max_output_growth_bytes":0}}')), { schema_version: 1, limits: { max_output_growth_bytes: 0 } });
for (const input of ['', '{', '{}', '{"limits":{}}', '{"limits":{"max_output_growth_bytes":-1}}', '{"limits":{"max_output_growth_bytes":0.5}}', '{"limits":{"max_output_growth_bytes":2147483648}}', '{"rules":{}}', ' '.repeat(1048577), '😀'.repeat(262145)]) {
  assert.ok(JSON.parse(nbinspect_parse_budget(input)).error);
  assert.ok(JSON.parse(nbinspect_budget(sizeBefore, sizeAfter, input)).error);
}
for (const badInput of ['{', tooManyResources, ' '.repeat(10485761), '😀'.repeat(2621441)]) {
  assert.ok(JSON.parse(nbinspect_budget(badInput, sizeAfter, noGrowth)).error);
  assert.ok(JSON.parse(nbinspect_budget(sizeBefore, badInput, noGrowth)).error);
}
assert.match(JSON.parse(nbinspect_budget(budgetBefore, budgetAfter, noGrowth)).error, /candidate budget/);
self.onmessage({ data: { mode: 'budget-config', input: importedBudget } });
assert.deepEqual(posted.budget, effectiveBudget);
self.onmessage({ data: { mode: 'budget-config', input: '{' } });
assert.ok(posted.error);
self.onmessage({ data: { mode: 'review', before: riskBefore, after: riskAfter, riskStatus: 'all' } });
self.onmessage({ data: { mode: 'budget', before: sizeBefore, after: sizeAfter, budget: noGrowth, policy: '{', view: 'code', riskStatus: 'introduced' } });
assert.deepEqual(posted.report, deniedBudget);
assert.equal(posted.html, posted.displayHtml);
assert.match(posted.html, /Growth allowance results/);
self.onmessage({ data: { mode: 'render', riskStatus: 'introduced' } });
assert.ok(posted.error);
const escapedBudget = nbinspect_render_report(nbinspect_budget(profileInput, profileInput, noGrowth));
assert.match(escapedBudget, /&lt;img&gt;/);
assert.ok(!/<script|<img|<svg/i.test(escapedBudget));
assert.ok(!escapedBudget.includes('hidden-payload'));
console.log('Browser budget: native parity, normalized allowances, pass/block/shrink/zero, invalid/UTF-8/resource/budget limits, escaped HTML and independent Worker mode passed');
// OUT002 is a cross-version hint with identical native/JS decisions and filter evidence.
const staleBefore = notebook([{ ...cell('result', 'value = 1\nprint(value)\n'), execution_count: 1, outputs: [{ output_type: 'stream', name: 'stdout', text: 'same saved output' }] }]);
const staleAfter = notebook([{ ...JSON.parse(staleBefore).cells[0], source: 'value = 2\nprint(value)\n' }]);
await mkdir('_build/browser-stale-fixtures', { recursive: true });
await writeFile('_build/browser-stale-fixtures/before.ipynb', staleBefore);
await writeFile('_build/browser-stale-fixtures/after.ipynb', staleAfter);
const stalePolicy = '{"rules":{"OUT002":{"severity":"error"}}}';
await writeFile('_build/browser-stale-fixtures/policy.json', stalePolicy);
const staleReport = JSON.parse(nbinspect_review_with_policy(staleBefore, staleAfter, stalePolicy));
const nativeStale = spawnSync('_build/native/debug/build/cmd/nbinspect/nbinspect.exe', ['review', '_build/browser-stale-fixtures/before.ipynb', '_build/browser-stale-fixtures/after.ipynb', '--config', '_build/browser-stale-fixtures/policy.json', '--format', 'json'], { encoding: 'utf8' });
assert.equal(nativeStale.status, 1, nativeStale.stderr);
assert.deepEqual(staleReport, JSON.parse(nativeStale.stdout));
const staleHint = staleReport.changes.find(row => row.after?.code === 'OUT002');
assert.equal(staleHint.status, 'introduced');
assert.equal(staleHint.evidence.before_source_path, '/cells/0/source');
assert.ok(!JSON.stringify(staleHint).includes('same saved output'));
assert.equal(JSON.parse(nbinspect_review(staleBefore, staleAfter)).status, 'passed');
assert.ok(!JSON.parse(nbinspect_analyze(staleAfter, '', 'all')).findings.some(row => row.code === 'OUT002'));
const disabledStale = JSON.parse(nbinspect_review_with_policy(staleBefore, staleAfter, '{"rules":{"OUT002":{"enabled":false}}}'));
assert.ok(!disabledStale.changes.some(row => row.after?.code === 'OUT002'));
self.onmessage({ data: { mode: 'review', before: staleBefore, after: staleAfter, policy: stalePolicy, riskStatus: 'introduced' } });
assert.deepEqual(posted.report, staleReport);
assert.match(posted.displayHtml, /Saved output evidence/);
self.onmessage({ data: { mode: 'render', riskStatus: 'uncertain' } });
assert.ok(!posted.displayHtml.includes('Saved output evidence'));
console.log('Browser stale output: native parity, default info/configured block/disable, cross-version only, structured evidence, Worker and risk filters passed');
delete globalThis.self;
console.log('Browser policies: three templates match native CLI check/review, limits, disabled rules, strict validation and Worker protocol passed');
console.log('Browser MoonBit bridge and Worker: check, diff, review, all risk filters, input limits, diagnostics, escaped HTML passed');
