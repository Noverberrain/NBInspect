import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
import * as core from '../web/nbinspect.js';

const ids = ['before', 'after', 'view', 'check', 'compare', 'review', 'sample', 'sample-review', 'profile', 'sample-profile', 'profile-diff', 'sample-profile-diff',
  'risk-status', 'risk-controls', 'status', 'report', 'empty', 'json', 'html',
  'policy-file', 'policy-reset', 'policy-status', 'policy-effective', 'policy-name'];
const elements = Object.fromEntries(ids.map(id => [id, {
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
  document: { getElementById: id => elements[id] },
  window: { addEventListener(event, callback) { windowListeners[event] = callback; } },
  Worker, Blob,
  URL: {
    createObjectURL(blob) { const url = 'blob:test/' + ++nextBlob; blobs.set(url, blob); return url; },
    revokeObjectURL(url) { blobs.delete(url); },
  },
};
vm.runInNewContext(await readFile('web/app.js', 'utf8'), context);
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
