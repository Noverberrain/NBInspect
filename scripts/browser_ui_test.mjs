import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
import * as core from '../web/nbinspect.js';

const ids = ['notes-file', 'notes-panel', 'note-item', 'note-decision', 'note-reason', 'note-save', 'note-remove', 'notes-status', 'note-context', 'notes-json', 'notes-html', 'before', 'after', 'view', 'check', 'compare', 'review', 'sample', 'sample-review', 'profile', 'sample-profile', 'profile-diff', 'sample-profile-diff',
  'risk-status', 'risk-controls', 'status', 'report', 'empty', 'json', 'html',
  'policy-file', 'policy-reset', 'policy-status', 'policy-effective', 'policy-name',
  'budget', 'sample-budget', 'budget-file', 'budget-reset', 'budget-status', 'budget-effective', 'budget-name'];
const elements = Object.fromEntries(ids.map(id => [id, {
  replaceChildren(...children) { this.children = children; },
  appendChild(child) { this.children.push(child); },
  files: [], value: 'all', hidden: false, disabled: false, attributes: {}, listeners: {},
  addEventListener(event, callback) { this.listeners[event] = callback; },
  setAttribute(name, value) { this.attributes[name] = value; },
  removeAttribute(name) { delete this.attributes[name]; if (name === 'srcdoc') this.srcdoc = ''; },
}]));
const blobs = new Map();
const workers = [];
const workerSource = (await readFile('web/worker.js', 'utf8')).replace(/^import .*;\r?\n/, '');
class Worker {
  constructor() {
    this.dead = false;
    workers.push(this);
    this.context = {
      ...core,
      self: { postMessage: data => queueMicrotask(() => {
        if (!this.dead) this.onmessage?.({ data });
      }) },
    };
    vm.runInNewContext(workerSource, this.context);
  }
  postMessage(data) {
    queueMicrotask(() => { if (!this.dead) this.context.self.onmessage({ data }); });
  }
  terminate() { this.dead = true; }
}
let nextBlob = 0;
const windowListeners = {};
const context = {
  document: { createElement: () => ({}), getElementById: id => elements[id] },
  window: { addEventListener(event, callback) { windowListeners[event] = callback; } },
  Worker, Blob, TextEncoder,
  URL: {
    createObjectURL(blob) { const url = 'blob:test/' + ++nextBlob; blobs.set(url, blob); return url; },
    revokeObjectURL(url) { blobs.delete(url); },
  },
};
vm.runInNewContext((await readFile('web/annotations.js', 'utf8')).replace('export function', 'function'), context);
vm.runInNewContext((await readFile('web/app.js', 'utf8')).replace(/^import .*;\r?\n/, ''), context);
async function trigger(id, event = 'click') {
  elements[id].listeners[event]();
  await new Promise(resolve => setImmediate(resolve));
}
await trigger('review');
assert.match(elements.status.textContent, /请选择原始/);
assert.equal(blobs.size, 0);
await trigger('sample-review');
assert.match(elements.status.textContent, /审阅完成/);
assert.equal(elements['risk-controls'].hidden, false);
assert.equal(elements['risk-status'].disabled, false);
const originalJsonUrl = elements.json.href;
const originalHtmlUrl = elements.html.href;
const complete = JSON.parse(await blobs.get(originalJsonUrl).text());
const completeHtml = await blobs.get(originalHtmlUrl).text();
for (const status of ['introduced', 'existing', 'resolved', 'uncertain']) {
  assert.ok(complete.summary[status] > 0);
  elements['risk-status'].value = status;
  await trigger('risk-status', 'change');
  assert.ok(elements.report.srcdoc.includes('Risk filter: ' + status));
  assert.equal(elements.json.href, originalJsonUrl);
  assert.equal(elements.html.href, originalHtmlUrl);
  assert.ok(completeHtml.includes('<h3>' + status + '</h3>'));
}
elements['risk-status'].value = 'introduced';
await trigger('risk-status', 'change');
assert.ok(!elements.report.srcdoc.includes('<h3>resolved</h3>'));
assert.ok(completeHtml.includes('<h3>resolved</h3>'));
assert.equal(blobs.size, 2);
await trigger('sample');
assert.match(elements.status.textContent, /比较完成/);
assert.equal(elements['risk-controls'].hidden, true);
assert.ok(!blobs.has(originalJsonUrl));
assert.equal(blobs.size, 2);
await trigger('check');
assert.match(elements.status.textContent, /检查完成/);
assert.equal(elements['risk-status'].disabled, true);

// Exercise actual File.text() flow, a zero-risk filtered view and invalidation.
const notebook = cells => JSON.stringify({
  nbformat: 4, nbformat_minor: 5,
  metadata: { kernelspec: { name: 'python3' }, language_info: { name: 'python' } }, cells,
});
const before = notebook([]);
const after = notebook([]);
elements.before.files = [{ size: before.length, text: async () => before }];
elements.after.files = [{ size: after.length, text: async () => after }];
await trigger('before', 'change');
assert.equal(blobs.size, 0);
assert.equal(elements.report.hidden, true);
await trigger('review');
assert.match(elements.status.textContent, /新增 0/);
assert.ok(elements.report.srcdoc.includes('No risks in this view.'));
elements.after.files = [{ size: 1, text: async () => '{' }];
await trigger('after', 'change');
await trigger('review');
assert.match(elements.status.textContent, /分析失败/);
assert.equal(elements.json.attributes['aria-disabled'], 'true');
elements.before.files = [{ size: 10485761, text: async () => { throw Error('must not read'); } }];
await trigger('before', 'change');
await trigger('review');
assert.match(elements.status.textContent, /10 MiB/);
assert.equal(blobs.size, 0);
assert.ok(workers.every(worker => worker.dead));

// Import, switch and reset actual MoonBit policies; invalid policies must not reuse old reports.
const policyJson = '{"fail_on":"warning","rules":{"OUT001":{"severity":"error"}}}';
elements['policy-file'].files = [{ name: '<img src=x onerror=alert(1)>.json', size: policyJson.length, text: async () => policyJson }];
await trigger('policy-file', 'change');
assert.match(elements['policy-status'].textContent, /已应用.*warning/);
assert.equal(elements['policy-name'].textContent, '<img src=x onerror=alert(1)>.json');
assert.equal(JSON.parse(elements['policy-effective'].textContent).rules.OUT001.severity, 'error');
assert.equal(blobs.size, 0);
await trigger('sample-review');
assert.match(elements.status.textContent, /新增风险达到阻断级别/);
const policyReport = JSON.parse(await blobs.get(elements.json.href).text());
assert.equal(policyReport.policy.fail_on, 'warning');
assert.equal(policyReport.policy.rules.OUT001.severity, 'error');
assert.match(await blobs.get(elements.html.href).text(), /warning/);
elements['risk-status'].value = 'existing';
await trigger('risk-status', 'change');
assert.equal(JSON.parse(await blobs.get(elements.json.href).text()).policy.fail_on, 'warning');
await trigger('policy-reset');
assert.equal(blobs.size, 0);
assert.equal(elements['policy-effective'].hidden, true);
await trigger('sample-review');
assert.equal(JSON.parse(await blobs.get(elements.json.href).text()).policy.fail_on, 'error');

elements['policy-file'].files = [{ name: 'bad.json', size: 2, text: async () => '{"unknown":1}' }];
await trigger('policy-file', 'change');
assert.match(elements['policy-status'].textContent, /configuration.*unknown/);
assert.equal(elements.check.disabled, true);
assert.equal(elements.review.disabled, true);
assert.equal(blobs.size, 0);
await trigger('check');
assert.match(elements.status.textContent, /规则配置无效/);
await trigger('sample');
assert.match(elements.status.textContent, /比较完成/);
elements['policy-file'].files = [{ name: 'huge.json', size: 1048577, text: async () => { throw Error('must not read'); } }];
await trigger('policy-file', 'change');
assert.match(elements['policy-status'].textContent, /1 MiB/);
assert.equal(blobs.size, 0);
elements['policy-file'].files = [{ name: 'unreadable.json', size: 1, text: async () => { throw Error('read failed'); } }];
await trigger('policy-file', 'change');
assert.match(elements['policy-status'].textContent, /read failed/);

// A late file read must not undo a reset or a newer import.
let finishRead;
elements['policy-file'].files = [{ name: 'slow.json', size: 2, text: () => new Promise(resolve => { finishRead = resolve; }) }];
await trigger('policy-file', 'change');
assert.equal(elements.check.disabled, true);
await trigger('policy-reset');
finishRead(policyJson);
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements['policy-name'].textContent, '默认规则');
assert.equal(elements.review.disabled, false);
let finishOld;
elements['policy-file'].files = [{ name: 'old.json', size: 2, text: () => new Promise(resolve => { finishOld = resolve; }) }];
await trigger('policy-file', 'change');
elements['policy-file'].files = [{ name: 'new.json', size: 2, text: async () => '{}' }];
await trigger('policy-file', 'change');
finishOld(policyJson);
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements['policy-name'].textContent, 'new.json');
assert.equal(JSON.parse(elements['policy-effective'].textContent).fail_on, 'error');
await trigger('policy-reset');
assert.ok(workers.every(worker => worker.dead));
console.log('Browser policy UI: import, effective settings, report downloads, invalid/oversized/read errors, reset, stale read and newer import races passed');


// Profile sample, downloads and a single selected file with an unreadable second file.
await trigger('sample-profile');
assert.match(elements.status.textContent, /体积分析完成.*紧凑 JSON/);
assert.equal(elements['risk-controls'].hidden, true);
assert.equal(elements['risk-status'].disabled, true);
assert.equal(elements.json.download, 'nbinspect-profile.json');
assert.equal(elements.html.download, 'nbinspect-profile.html');
const sampleProfile = JSON.parse(await blobs.get(elements.json.href).text());
assert.equal(sampleProfile.kind, 'profile');
assert.equal(sampleProfile.cell_count, 3);
assert.equal(sampleProfile.resource_count, 4);
assert.ok(sampleProfile.summary.output_bytes > sampleProfile.summary.attachment_bytes);
assert.ok(!sampleProfile.policy);
assert.match(await blobs.get(elements.html.href).text(), /MIME payloads/);
assert.match(elements.report.srcdoc, /Stored resources by size/);
assert.equal(blobs.size, 2);
assert.ok(workers.every(worker => worker.dead));
// The original-file button must not silently reuse a preceding demo.
elements.before.files = [];
await trigger('profile');
assert.match(elements.status.textContent, /请选择原始/);
await trigger('sample-profile');
const sampleProfileUrl = elements.json.href;
elements.before.files = [{ size: before.length, text: async () => before }];
elements.after.files = [{ size: 1, text: async () => { throw Error('profile must not read second file'); } }];
await trigger('before', 'change');
await trigger('profile');
assert.match(elements.status.textContent, /体积分析完成.*0 个单元格/);
assert.equal(JSON.parse(await blobs.get(elements.json.href).text()).cell_count, 0);
assert.ok(!blobs.has(sampleProfileUrl));

// Invalid and loading publication policies cannot disable this independent operation.
elements['policy-file'].files = [{ name: 'invalid.json', size: 1, text: async () => '{' }];
await trigger('policy-file', 'change');
assert.equal(elements.profile.disabled, false);
assert.equal(elements['sample-profile'].disabled, false);
await trigger('profile');
assert.match(elements.status.textContent, /体积分析完成/);
let finishProfilePolicy;
elements['policy-file'].files = [{ name: 'pending.json', size: 2, text: () => new Promise(resolve => { finishProfilePolicy = resolve; }) }];
await trigger('policy-file', 'change');
assert.equal(elements.check.disabled, true);
assert.equal(elements.profile.disabled, false);
await trigger('sample-profile');
assert.match(elements.status.textContent, /体积分析完成/);
finishProfilePolicy('{}');
await new Promise(resolve => setImmediate(resolve));
assert.match(elements.status.textContent, /体积分析完成/);
await trigger('policy-reset');
assert.equal(blobs.size, 0);

// Error paths remove the last report and never make downloadable success artifacts.
elements.before.files = [];
await trigger('before', 'change');
await trigger('profile');
assert.match(elements.status.textContent, /请选择原始/);
elements.before.files = [{ size: 1, text: async () => '{' }];
await trigger('profile');
assert.match(elements.status.textContent, /分析失败/);
assert.equal(elements.json.attributes['aria-disabled'], 'true');
elements.before.files = [{ size: 10485761, text: async () => { throw Error('must not read'); } }];
await trigger('profile');
assert.match(elements.status.textContent, /10 MiB/);
elements.before.files = [{ size: 1, text: async () => { throw Error('profile read failed'); } }];
await trigger('profile');
assert.match(elements.status.textContent, /profile read failed/);
assert.equal(blobs.size, 0);

// Late file reads and old Worker callbacks must not replace a newer result.
let finishProfileRead;
elements.before.files = [{ size: 1, text: () => new Promise(resolve => { finishProfileRead = resolve; }) }];
await trigger('profile');
await trigger('sample-review');
const latestUrl = elements.json.href;
finishProfileRead(before);
await new Promise(resolve => setImmediate(resolve));
assert.match(elements.status.textContent, /审阅完成/);
assert.equal(elements.json.href, latestUrl);
const oldReviewWorker = workers.at(-1);
await trigger('sample-profile');
const latestProfileUrl = elements.json.href;
oldReviewWorker.onmessage({ data: { error: 'stale failure' } });
assert.match(elements.status.textContent, /体积分析完成/);
assert.equal(elements.json.href, latestProfileUrl);
elements.view.value = 'code';
await trigger('view', 'change');
assert.equal(elements.json.href, latestProfileUrl);
await trigger('sample');
assert.match(elements.status.textContent, /比较完成/);
await trigger('sample-profile');
windowListeners.pagehide();
assert.equal(blobs.size, 0);
assert.equal(elements.report.hidden, true);
assert.ok(workers.every(worker => worker.dead));
console.log('Browser profile UI: samples/imports, policy independence, downloads, invalid/oversized/read errors, stale results, cleanup passed');
// Ignored fixtures for the manual browser import check.
await mkdir('_build/browser-fixtures', { recursive: true });
await writeFile('_build/browser-fixtures/before.ipynb', before);
await writeFile('_build/browser-fixtures/after.ipynb', after);
console.log('Browser UI: risk sample, all filters, complete JSON/HTML blobs, check/diff regression, File.text import, empty/error/size states, cleanup passed');

// Version sizes: real two-file selection, signed summaries and complete downloads.
const sizeBefore = await readFile('examples/profile-before.ipynb', 'utf8');
const sizeAfter = await readFile('examples/profile-after.ipynb', 'utf8');
const selectSizeFiles = async (first = sizeBefore, second = sizeAfter) => {
  elements.before.files = [{ size: Buffer.byteLength(first), text: async () => first }];
  elements.after.files = [{ size: Buffer.byteLength(second), text: async () => second }];
  await trigger('before', 'change');
};
await trigger('sample-profile-diff');
assert.match(elements.status.textContent, /体积比较完成.*增减 \+/);
const sizeSample = JSON.parse(await blobs.get(elements.json.href).text());
assert.equal(sizeSample.kind, 'profile-diff');
assert.equal(sizeSample.matched_count, 3);
assert.ok(sizeSample.cells.some(row => row.moved));
assert.equal(elements['risk-controls'].hidden, true);
assert.equal(elements['risk-status'].disabled, true);
assert.equal(elements.json.download, 'nbinspect-profile-diff.json');
assert.equal(elements.html.download, 'nbinspect-profile-diff.html');
assert.match(await blobs.get(elements.html.href).text(), /Cell measurements and matching evidence/);
assert.ok(!sizeSample.policy);
const oldSizeSampleUrl = elements.json.href;
elements.before.files = [];
await trigger('profile-diff'); // Real-file button cannot silently reuse the demo.
assert.match(elements.status.textContent, /请选择原始/);
assert.ok(!blobs.has(oldSizeSampleUrl));
await selectSizeFiles();
elements.after.files = [];
await trigger('profile-diff');
assert.match(elements.status.textContent, /请选择修改后/);
await selectSizeFiles();
await trigger('profile-diff');
const sizeSelected = JSON.parse(await blobs.get(elements.json.href).text());
assert.deepEqual(sizeSelected, JSON.parse(core.nbinspect_profile_diff(sizeBefore, sizeAfter)));
assert.match(elements.status.textContent, /正文.*输出.*附件.*其他/);
assert.match(elements.status.textContent, /匹配 3 对/);
const selectedSizeUrl = elements.json.href;
elements.view.value = 'content';
await trigger('view', 'change');
await trigger('risk-status', 'change');
assert.equal(elements.json.href, selectedSizeUrl); // Display filters do not recalculate sizes.
await selectSizeFiles(sizeAfter, sizeBefore);
await trigger('profile-diff');
assert.match(elements.status.textContent, /增减 -/);
await selectSizeFiles(sizeBefore, sizeBefore);
await trigger('profile-diff');
assert.match(elements.status.textContent, /增减 0 字节/);
const repeatedSize = notebook([0, 1].map(() => ({ cell_type: 'code', source: 'same', metadata: {}, execution_count: null, outputs: [] })));
await selectSizeFiles(repeatedSize, repeatedSize);
await trigger('profile-diff');
assert.match(elements.status.textContent, /未匹配 2 → 2.*歧义 2 项/);
assert.equal(JSON.parse(await blobs.get(elements.json.href).text()).cells.length, 4);

// Size comparison remains available with invalid or loading publication rules.
elements['policy-file'].files = [{ name: 'bad.json', size: 1, text: async () => '{' }];
await trigger('policy-file', 'change');
assert.equal(elements['profile-diff'].disabled, false);
assert.equal(elements['sample-profile-diff'].disabled, false);
await trigger('sample-profile-diff');
assert.match(elements.status.textContent, /体积比较完成/);
let finishSizePolicy;
elements['policy-file'].files = [{ name: 'slow.json', size: 2, text: () => new Promise(resolve => { finishSizePolicy = resolve; }) }];
await trigger('policy-file', 'change');
assert.equal(elements['profile-diff'].disabled, false);
await selectSizeFiles();
await trigger('profile-diff');
assert.match(elements.status.textContent, /体积比较完成/);
finishSizePolicy('{}');
await new Promise(resolve => setImmediate(resolve));
assert.match(elements.status.textContent, /体积比较完成/);
await trigger('policy-reset');
assert.equal(blobs.size, 0);

// Bad, oversized and unreadable inputs on either side clear success artifacts.
for (const id of ['before', 'after']) {
  for (const file of [
    { size: 1, text: async () => '{' },
    { size: 10485761, text: async () => { throw Error('must not read'); } },
    { size: 1, text: async () => { throw Error('size read failed'); } },
  ]) {
    await selectSizeFiles();
    await trigger('profile-diff');
    elements[id].files = [file];
    await trigger('profile-diff');
    assert.match(elements.status.textContent, /分析失败/);
    assert.equal(elements.json.attributes['aria-disabled'], 'true');
    assert.equal(elements.report.hidden, true);
    assert.equal(blobs.size, 0);
  }
}
// Late second-file reads and cancelled Worker callbacks cannot replace the next result.
let finishSizeRead;
await selectSizeFiles();
elements.after.files = [{ size: 1, text: () => new Promise(resolve => { finishSizeRead = resolve; }) }];
await trigger('profile-diff');
await trigger('sample-profile');
const latestSingleUrl = elements.json.href;
finishSizeRead(sizeAfter);
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements.json.href, latestSingleUrl);
assert.match(elements.status.textContent, /体积分析完成/);
await trigger('sample-review');
const precedingWorker = workers.at(-1);
await trigger('sample-profile-diff');
const latestSizeUrl = elements.json.href;
precedingWorker.onmessage({ data: { error: 'stale size error' } });
assert.equal(elements.json.href, latestSizeUrl);
assert.match(elements.status.textContent, /体积比较完成/);
assert.ok(workers.every(worker => worker.dead));
windowListeners.pagehide();
assert.equal(blobs.size, 0);
assert.equal(elements.report.hidden, true);
console.log('Browser profile-diff UI: two files/demo isolation, growth/shrink/zero/ambiguity, full downloads, policy/filter independence, both-input errors, cancellation and cleanup passed');

// Independent budget import and both pass/block results remain downloadable.
await trigger('budget-reset');
assert.equal(elements.budget.disabled, true);
await trigger('budget');
assert.match(elements.status.textContent, /请先导入有效/);
const growthBudget = await readFile('configs/growth-budget.json', 'utf8');
const importBudgetFile = async text => {
  elements['budget-file'].files = [{ name: '<img>.json', size: Buffer.byteLength(text), text: async () => text }];
  await trigger('budget-file', 'change');
};
await importBudgetFile(growthBudget);
assert.equal(elements.budget.disabled, false);
assert.equal(elements['budget-name'].textContent, '<img>.json');
assert.deepEqual(JSON.parse(elements['budget-effective'].textContent), JSON.parse(growthBudget));
await selectSizeFiles();
await trigger('budget');
assert.match(elements.status.textContent, /预算检查完成 · 通过/);
assert.equal(elements.json.download, 'nbinspect-budget.json');
assert.equal(elements.html.download, 'nbinspect-budget.html');
const downloadedBudget = JSON.parse(await blobs.get(elements.json.href).text());
assert.deepEqual(downloadedBudget, JSON.parse(core.nbinspect_budget(sizeBefore, sizeAfter, growthBudget)));
assert.match(await blobs.get(elements.html.href).text(), /Effective size budget/);
assert.equal(elements['risk-controls'].hidden, true);
await trigger('sample-budget');
assert.match(elements.status.textContent, /固定零增长额度.*未通过.*超额/);
assert.equal(JSON.parse(await blobs.get(elements.json.href).text()).status, 'blocked');
assert.equal(JSON.parse(elements['budget-effective'].textContent).limits.max_notebook_growth_bytes, 204800);
await trigger('budget'); // Imported files/config survive a separate fixed demo.
assert.match(elements.status.textContent, /预算检查完成 · 通过/);
const zeroBudget = '{"limits":{"max_notebook_growth_bytes":0,"max_output_growth_bytes":0,"max_attachment_growth_bytes":0}}';
await importBudgetFile(zeroBudget);
assert.equal(blobs.size, 0);
await trigger('budget');
assert.match(elements.status.textContent, /未通过.*总体超额 251.*输出超额 133.*附件超额 57/);
const blockedBudgetUrl = elements.json.href;
elements.view.value = 'code';
await trigger('view', 'change');
await trigger('risk-status', 'change');
assert.equal(elements.json.href, blockedBudgetUrl);
await selectSizeFiles(sizeAfter, sizeBefore);
await trigger('budget');
assert.match(elements.status.textContent, /预算检查完成 · 通过/);

// Invalid budget does not disable publication checks, profiles, or the explicit demo.
await importBudgetFile('{');
assert.equal(elements.budget.disabled, true);
assert.match(elements['budget-status'].textContent, /预算无效/);
assert.equal(blobs.size, 0);
await trigger('sample-profile-diff');
assert.match(elements.status.textContent, /体积比较完成/);
await trigger('sample-review');
assert.match(elements.status.textContent, /审阅完成/);
await trigger('sample-budget');
assert.match(elements.status.textContent, /固定零增长额度.*未通过/);
elements.before.files = [];
await importBudgetFile(growthBudget);
await trigger('budget');
assert.match(elements.status.textContent, /请选择原始/); // Real button must not reuse demo.
await selectSizeFiles();
elements.after.files = [];
await trigger('budget');
assert.match(elements.status.textContent, /请选择修改后/);
for (const id of ['before', 'after']) {
  for (const file of [
    { size: 1, text: async () => '{' },
    { size: 10485761, text: async () => { throw Error('must not read'); } },
    { size: 1, text: async () => { throw Error('budget input read failed'); } },
  ]) {
    await selectSizeFiles();
    elements[id].files = [file];
    await trigger('budget');
    assert.match(elements.status.textContent, /分析失败/);
    assert.equal(blobs.size, 0);
    assert.equal(elements.report.hidden, true);
  }
}
for (const file of [
  { name: 'huge.json', size: 1048577, text: async () => { throw Error('must not read'); } },
  { name: 'unreadable.json', size: 1, text: async () => { throw Error('budget read failed'); } },
]) {
  elements['budget-file'].files = [file];
  await trigger('budget-file', 'change');
  assert.equal(elements.budget.disabled, true);
  assert.match(elements['budget-status'].textContent, /预算无效/);
}
// Reset/new import fences a late read; publication-policy errors never affect budgets.
let finishBudgetRead;
elements['budget-file'].files = [{ name: 'slow.json', size: 2, text: () => new Promise(resolve => { finishBudgetRead = resolve; }) }];
await trigger('budget-file', 'change');
await trigger('budget-reset');
finishBudgetRead(growthBudget);
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements.budget.disabled, true);
let finishOldBudget;
elements['budget-file'].files = [{ name: 'old.json', size: 2, text: () => new Promise(resolve => { finishOldBudget = resolve; }) }];
await trigger('budget-file', 'change');
await importBudgetFile(zeroBudget);
finishOldBudget(growthBudget);
await new Promise(resolve => setImmediate(resolve));
assert.equal(JSON.parse(elements['budget-effective'].textContent).limits.max_notebook_growth_bytes, 0);
elements['policy-file'].files = [{ name: 'bad.json', size: 1, text: async () => '{' }];
await trigger('policy-file', 'change');
assert.equal(elements.budget.disabled, false);
await selectSizeFiles();
await trigger('budget');
assert.match(elements.status.textContent, /预算检查完成.*未通过/);
let finishBudgetPolicy;
elements['policy-file'].files = [{ name: 'slow.json', size: 2, text: () => new Promise(resolve => { finishBudgetPolicy = resolve; }) }];
await trigger('policy-file', 'change');
await trigger('budget');
assert.match(elements.status.textContent, /预算检查完成/);
finishBudgetPolicy('{}');
await new Promise(resolve => setImmediate(resolve));
await trigger('policy-reset');
assert.equal(elements.budget.disabled, false);
let finishBudgetNotebook;
elements.after.files = [{ size: 1, text: () => new Promise(resolve => { finishBudgetNotebook = resolve; }) }];
await trigger('budget');
await trigger('budget-reset');
finishBudgetNotebook(sizeAfter);
await new Promise(resolve => setImmediate(resolve));
assert.equal(blobs.size, 0);
assert.equal(elements.report.hidden, true);
await trigger('sample-review');
const priorBudgetWorker = workers.at(-1);
await trigger('sample-budget');
const freshBudgetUrl = elements.json.href;
priorBudgetWorker.onmessage({ data: { error: 'stale budget callback' } });
assert.equal(elements.json.href, freshBudgetUrl);
windowListeners.pagehide();
assert.equal(blobs.size, 0);
assert.ok(workers.every(worker => worker.dead));
// A late validation callback cannot re-enable a cleared or replaced budget.
await importBudgetFile(growthBudget);
const retiredBudgetWorker = workers.at(-1);
await trigger('budget-reset');
retiredBudgetWorker.onmessage({ data: { budget: JSON.parse(growthBudget) } });
assert.equal(elements.budget.disabled, true);
await importBudgetFile(zeroBudget);
retiredBudgetWorker.onmessage({ data: { error: 'old validation failure' } });
assert.match(elements['budget-status'].textContent, /预算已应用/);
assert.equal(JSON.parse(elements['budget-effective'].textContent).limits.max_notebook_growth_bytes, 0);
windowListeners.pagehide();
assert.ok(workers.every(worker => worker.dead));
console.log('Browser budget UI: import/clear, full blocked/passed downloads, demo isolation, independent policy/filter states, both-input errors, stale reads/callbacks and cleanup passed');

// The browser's actual review entry and downloads include OUT002 and its evidence.
await trigger('policy-reset');
elements['risk-status'].value = 'all';
const staleBook = source => notebook([{ cell_type: 'code', id: 'result', metadata: {}, source, execution_count: 1, outputs: [{ output_type: 'stream', name: 'stdout', text: 'same saved output' }] }]);
const staleFirst = staleBook('value = 1\nprint(value)\n');
const staleSecond = staleBook('value = 2\nprint(value)\n');
elements.before.files = [{ size: staleFirst.length, text: async () => staleFirst }];
elements.after.files = [{ size: staleSecond.length, text: async () => staleSecond }];
await trigger('before', 'change');
await trigger('review');
assert.match(elements.status.textContent, /未新增阻断级别风险/);
assert.match(elements.report.srcdoc, /Saved output evidence/);
let staleDownload = JSON.parse(await blobs.get(elements.json.href).text());
assert.equal(staleDownload.changes.find(row => row.after?.code === 'OUT002').after.severity, 'info');
assert.match(await blobs.get(elements.html.href).text(), /before_source_path/);
elements['risk-status'].value = 'introduced';
await trigger('risk-status', 'change');
assert.match(elements.report.srcdoc, /OUT002/);
const staleFullUrl = elements.json.href;
elements['risk-status'].value = 'uncertain';
await trigger('risk-status', 'change');
assert.ok(!elements.report.srcdoc.includes('Saved output evidence'));
assert.equal(elements.json.href, staleFullUrl);
const staleConfig = '{"rules":{"OUT002":{"severity":"error"}}}';
elements['policy-file'].files = [{ name: 'stale-policy.json', size: staleConfig.length, text: async () => staleConfig }];
await trigger('policy-file', 'change');
assert.match(elements['policy-status'].textContent, /9\/9 条规则/);
await trigger('review');
assert.match(elements.status.textContent, /新增风险达到阻断级别/);
await trigger('check');
assert.ok(!JSON.parse(await blobs.get(elements.json.href).text()).findings.some(row => row.code === 'OUT002'));
windowListeners.pagehide();
assert.equal(blobs.size, 0);
console.log('Browser stale output UI: real inputs, info/error policy, nine-rule display, visible evidence, risk filters and full downloads passed');
await trigger('policy-reset');
await trigger('sample-review');
assert.equal(elements['notes-panel'].hidden, false);
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
const baselineUrl = elements.json.href;
const baselineHtmlUrl = elements.html.href;
const baseline = await blobs.get(baselineUrl).text();
const baselineHtml = await blobs.get(baselineHtmlUrl).text();
elements['note-decision'].value = 'accepted';
elements['note-reason'].value = '   ';
await trigger('note-save');
assert.match(elements['notes-status'].textContent, /需要填写理由/);
assert.equal(blobs.size, 2);
for (const [decision, reason] of [['invalid', 'reason'], ['confirmed', 'x'.repeat(2001)]]) {
  elements['note-decision'].value = decision;
  elements['note-reason'].value = reason;
  await trigger('note-save');
  assert.match(elements['notes-status'].textContent, /未保存/);
  assert.equal(blobs.size, 2);
}
const unsafe = '</main><script>alert("risk")</script>&\'\n原因';
elements['note-decision'].value = 'accepted';
elements['note-reason'].value = unsafe;
await trigger('note-save');
const firstNotesUrl = elements['notes-json'].href;
let record = JSON.parse(await blobs.get(firstNotesUrl).text());
assert.equal(record.kind, 'review-notes');
assert.equal(record.schema_version, 1);
assert.ok(!Number.isNaN(Date.parse(record.exported_at)));
assert.deepEqual(record.report, JSON.parse(baseline));
assert.deepEqual(record.notes, [{ change_index: 0, decision: 'accepted', reason: unsafe }]);
let notesHtml = await blobs.get(elements['notes-html'].href).text();
assert.ok(notesHtml.includes('human-review-notes'));
assert.ok(notesHtml.includes('&lt;script&gt;'));
assert.ok(!notesHtml.includes('<script>alert'));
assert.ok(notesHtml.includes('Original status: ' + record.report.status));
assert.equal(await blobs.get(baselineUrl).text(), baseline);
assert.equal(await blobs.get(baselineHtmlUrl).text(), baselineHtml);
elements['note-item'].value = '1';
await trigger('note-item', 'change');
assert.equal(elements['note-decision'].value, 'needs-action');
assert.equal(elements['note-reason'].value, '');
elements['note-decision'].value = 'confirmed';
elements['note-reason'].value = '已核对';
await trigger('note-save');
assert.ok(!blobs.has(firstNotesUrl));
record = JSON.parse(await blobs.get(elements['notes-json'].href).text());
assert.deepEqual(record.notes.map(n => n.change_index), [0, 1]);
const notesUrlBeforeFilter = elements['notes-json'].href;
elements['risk-status'].value = 'resolved';
await trigger('risk-status', 'change');
assert.equal(elements['notes-json'].href, notesUrlBeforeFilter);
elements['note-item'].value = '0';
await trigger('note-item', 'change');
assert.equal(elements['note-reason'].value, unsafe);
await trigger('note-remove');
record = JSON.parse(await blobs.get(elements['notes-json'].href).text());
assert.deepEqual(record.notes.map(n => n.change_index), [1]);
elements['note-item'].value = '1';
await trigger('note-item', 'change');
elements['note-decision'].value = 'needs-action';
await trigger('note-save');
record = JSON.parse(await blobs.get(elements['notes-json'].href).text());
assert.equal(record.notes.length, 1);
assert.equal(record.notes[0].decision, 'needs-action');
await trigger('note-remove');
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
assert.equal(blobs.size, 2);
elements['note-item'].value = '-1';
await trigger('note-save');
assert.equal(blobs.size, 2);
elements['note-item'].value = '0';
await trigger('note-save');
assert.equal(blobs.size, 4);
await trigger('before', 'change');
assert.equal(elements['notes-panel'].hidden, true);
assert.equal(blobs.size, 0);
await trigger('sample-review');
await trigger('note-save');
await trigger('policy-reset');
assert.equal(blobs.size, 0);
await trigger('sample-review');
await trigger('note-save');
await trigger('sample');
assert.equal(elements['notes-panel'].hidden, true);
assert.equal(blobs.size, 2);
await trigger('sample-review');
await trigger('note-save');
windowListeners.pagehide();
assert.equal(blobs.size, 0);
// Empty reviews have no editable notes and no annotation downloads.
const emptyReview = JSON.stringify({ nbformat: 4, nbformat_minor: 5, metadata: { kernelspec: { name: 'python3', display_name: 'Python 3', language: 'python' }, language_info: { name: 'python' } }, cells: [] });
for (const id of ['before', 'after']) elements[id].files = [{ size: emptyReview.length, text: async () => emptyReview }];
await trigger('before', 'change');
await trigger('review');
assert.equal(elements['notes-panel'].hidden, false);
assert.equal(elements['note-save'].disabled, true);
assert.match(elements['notes-status'].textContent, /没有风险项/);
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
windowListeners.pagehide();
console.log('Browser review annotations: validation, snapshot, escaping, save/update/remove, filter stability, input/policy/operation/page cleanup and empty reports passed');
// Restore only to the same complete report, without changing analysis decisions.
await trigger('sample-review');
elements['note-decision'].value = 'accepted';
elements['note-reason'].value = unsafe;
await trigger('note-save');
elements['note-item'].value = '1';
await trigger('note-item', 'change');
elements['note-decision'].value = 'confirmed';
elements['note-reason'].value = '第二项已核对';
await trigger('note-save');
const savedNotes = JSON.parse(await blobs.get(elements['notes-json'].href).text());
async function importText(text, overrides = {}) {
  elements['notes-file'].files = [{ name: 'review-notes.json', size: new TextEncoder().encode(text).length, text: async () => text, ...overrides }];
  await trigger('notes-file', 'change');
}
async function restoredRecord() { return JSON.parse(await blobs.get(elements['notes-json'].href).text()); }
function clone(value) { return JSON.parse(JSON.stringify(value)); }
await trigger('sample-review');
assert.equal(elements['notes-file'].disabled, false);
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
const untouchedReportUrl = elements.json.href;
const untouchedHtmlUrl = elements.html.href;
await importText(JSON.stringify(savedNotes));
assert.match(elements['notes-status'].textContent, /已导入 2 项/);
assert.equal(elements['notes-file'].value, '');
assert.equal(elements['note-decision'].value, 'accepted');
assert.equal(elements['note-reason'].value, unsafe);
assert.deepEqual((await restoredRecord()).notes, savedNotes.notes);
assert.equal(elements.json.href, untouchedReportUrl);
assert.equal(elements.html.href, untouchedHtmlUrl);
assert.deepEqual((await restoredRecord()).report, savedNotes.report);
assert.ok((await blobs.get(elements['notes-html'].href).text()).includes('&lt;script&gt;'));
assert.ok(!(await blobs.get(elements['notes-html'].href).text()).includes('<script>alert'));
elements['risk-status'].value = 'introduced';
await trigger('risk-status', 'change');
assert.deepEqual((await restoredRecord()).notes, savedNotes.notes);
const invalidRecords = [null, [], 'record', savedNotes.report];
for (const mutate of [
  r => { r.schema_version = 2; },
  r => { r.kind = 'review'; },
  r => { r.exported_at = 'invalid'; },
  r => { delete r.exported_at; },
  r => { r.extra = true; },
  r => { r.report = null; },
  r => { r.report.changes[0].status = 'changed'; },
  r => { r.report.changes.reverse(); },
  r => { r.report.policy.fail_on = 'info'; },
  r => { r.notes = {}; },
  r => { r.notes = Array(savedNotes.report.changes.length + 1).fill(r.notes[0]); },
  r => { r.notes[1].change_index = r.notes[0].change_index; },
  r => { r.notes[1].change_index = -1; },
  r => { r.notes[1].change_index = 0.5; },
  r => { r.notes[1].change_index = '1'; },
  r => { r.notes[1].change_index = r.report.changes.length; },
  r => { r.notes[1].decision = 'constructor'; },
  r => { r.notes[1].decision = ['confirmed']; },
  r => { r.notes[1].reason = null; },
  r => { r.notes[1].reason = 'x'.repeat(2001); },
  r => { r.notes[1].decision = 'accepted'; r.notes[1].reason = ' \n '; },
  r => { delete r.notes[1].reason; },
  r => { r.notes[1].extra = true; },
]) { const r = clone(savedNotes); mutate(r); invalidRecords.push(r); }
for (const invalid of invalidRecords) {
  const url = elements['notes-json'].href;
  await importText(JSON.stringify(invalid));
  assert.match(elements['notes-status'].textContent, /导入失败，现有标注保持不变/);
  assert.equal(elements['notes-json'].href, url);
  assert.deepEqual((await restoredRecord()).notes, savedNotes.notes);
}
await importText('{broken');
assert.match(elements['notes-status'].textContent, /JSON 格式无效/);
await importText('', { size: 20 * 1024 * 1024 + 1, text: () => { throw Error('must not read'); } });
assert.match(elements['notes-status'].textContent, /20 MiB/);
await importText('中'.repeat(7 * 1024 * 1024), { size: 1 });
assert.match(elements['notes-status'].textContent, /20 MiB/);
await importText('', { text: async () => { throw Error('read denied'); } });
assert.match(elements['notes-status'].textContent, /read denied/);
assert.deepEqual((await restoredRecord()).notes, savedNotes.notes);
// Pretty-printing, BOM and object field order do not invalidate an otherwise identical snapshot.
function reverseKeys(value) {
  if (Array.isArray(value)) return value.map(reverseKeys);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).reverse().map(([key, item]) => [key, reverseKeys(item)]));
  return value;
}
await importText('\uFEFF' + JSON.stringify(reverseKeys(savedNotes), null, 2));
assert.match(elements['notes-status'].textContent, /已导入 2 项/);
const noNotes = { ...savedNotes, notes: [] };
await importText(JSON.stringify(noNotes));
assert.match(elements['notes-status'].textContent, /已导入 0 项/);
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
assert.equal(elements['note-reason'].value, '');
await importText(JSON.stringify(savedNotes));
elements['note-decision'].value = 'needs-action';
elements['note-reason'].value = '导入后继续编辑';
await trigger('note-save');
assert.equal((await restoredRecord()).notes[0].reason, '导入后继续编辑');
// A newer import, explicit manual edits and lifecycle changes all fence pending reads.
async function pendingImport() {
  let resolve, reject;
  const deferred = new Promise((yes, no) => { resolve = yes; reject = no; });
  await importText('', { text: () => deferred });
  return { resolve, reject };
}
let pending = await pendingImport();
await importText(JSON.stringify(savedNotes));
const newUrl = elements['notes-json'].href;
pending.resolve(JSON.stringify(noNotes));
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements['notes-json'].href, newUrl);
pending = await pendingImport();
elements['note-reason'].value = '读取期间手动修改';
await trigger('note-save');
pending.resolve(JSON.stringify(savedNotes));
await new Promise(resolve => setImmediate(resolve));
assert.equal((await restoredRecord()).notes[0].reason, '读取期间手动修改');
pending = await pendingImport();
await trigger('note-remove');
pending.resolve(JSON.stringify(savedNotes));
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual((await restoredRecord()).notes.map(note => note.change_index), [1]);
pending = await pendingImport();
elements['notes-file'].files = [];
await trigger('notes-file', 'change');
pending.resolve(JSON.stringify(noNotes));
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual((await restoredRecord()).notes.map(note => note.change_index), [1]);
for (const action of [() => trigger('before', 'change'), () => trigger('policy-reset'), () => trigger('budget-reset'), () => trigger('sample'), async () => windowListeners.pagehide()]) {
  await trigger('sample-review');
  pending = await pendingImport();
  await action();
  const status = elements['notes-status'].textContent;
  pending.reject(Error('late read error'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(elements['notes-status'].textContent, status);
  assert.equal(elements['notes-file'].disabled, true);
  assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
}
await trigger('sample-review');
pending = await pendingImport();
await trigger('sample-review');
pending.resolve(JSON.stringify(savedNotes));
await new Promise(resolve => setImmediate(resolve));
assert.equal(elements['notes-json'].attributes['aria-disabled'], 'true');
windowListeners.pagehide();
assert.equal(blobs.size, 0);
console.log('Browser annotation import: round trip, immutable full snapshot, key order/BOM, strict atomic validation, limits/read errors, empty replace, editing, newest-read/manual/lifecycle fences passed');
