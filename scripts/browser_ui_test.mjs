import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import vm from 'node:vm';
import * as core from '../web/nbinspect.js';

const ids = ['before', 'after', 'view', 'check', 'compare', 'review', 'sample', 'sample-review',
  'risk-status', 'risk-controls', 'status', 'report', 'empty', 'json', 'html'];
const elements = Object.fromEntries(ids.map(id => [id, {
  files: [], value: 'all', hidden: false, disabled: false, attributes: {}, listeners: {},
  addEventListener(event, callback) { this.listeners[event] = callback; },
  setAttribute(name, value) { this.attributes[name] = value; },
  removeAttribute(name) { delete this.attributes[name]; if (name === 'srcdoc') this.srcdoc = ''; },
}]));
const blobs = new Map();
const workers = [];
const workerSource = (await readFile('web/worker.js', 'utf8')).replace(/^import .*;\n/, '');
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
const context = {
  document: { getElementById: id => elements[id] },
  window: { addEventListener() {} },
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

// Ignored fixtures for the manual browser import check.
await mkdir('_build/browser-fixtures', { recursive: true });
await writeFile('_build/browser-fixtures/before.ipynb', before);
await writeFile('_build/browser-fixtures/after.ipynb', after);
console.log('Browser UI: risk sample, all filters, complete JSON/HTML blobs, check/diff regression, File.text import, empty/error/size states, cleanup passed');
