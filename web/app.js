const element = id => document.getElementById(id);
const inputLimit = 10 * 1024 * 1024;
let activeWorker = null;
let runId = 0;
let current = null;
let downloadUrls = [];
let lastMode = null;
let sampleMode = false;

const cell = (id, source) => ({ id, cell_type: 'code', source, metadata: {}, execution_count: null, outputs: [] });
const prose = (id, source) => ({ id, cell_type: 'markdown', source, metadata: {} });
const notebook = cells => JSON.stringify({ nbformat: 4, nbformat_minor: 5, metadata: {}, cells });
const sampleBefore = notebook([cell('setup', 'x = 1\n'), cell('compute', 'print(x)\n'), cell('ending', 'print("done")\n'), prose('notes', '# Results\n')]);
const sampleAfter = notebook([cell('compute', 'print(x + 1)\n'), cell('setup', 'x = 1\n'), cell('ending', 'print("done")\n'), prose('notes', '# Updated results\n')]);

function clearResult(message) {
  runId++;
  activeWorker?.terminate();
  activeWorker = null;
  current = null;
  for (const url of downloadUrls) URL.revokeObjectURL(url);
  downloadUrls = [];
  for (const kind of ['json', 'html']) {
    const link = element(kind);
    link.removeAttribute('href');
    link.setAttribute('aria-disabled', 'true');
  }
  element('report').hidden = true;
  element('report').removeAttribute('srcdoc');
  element('empty').hidden = false;
  element('status').textContent = message;
}

async function readNotebook(id) {
  const file = element(id).files[0];
  if (!file) throw new Error(id === 'before' ? '请选择原始 Notebook。' : '请选择修改后的 Notebook。');
  if (file.size > inputLimit) throw new Error('文件超过 10 MiB 限制。');
  return file.text();
}

async function analyze(mode) {
  clearResult('正在分析…');
  const ownRun = runId;
  lastMode = mode;
  try {
    const before = sampleMode ? sampleBefore : await readNotebook('before');
    const after = mode === 'check' ? '' : sampleMode ? sampleAfter : await readNotebook('after');
    if (ownRun !== runId) return;
    const worker = new Worker('./worker.js', { type: 'module' });
    activeWorker = worker;
    worker.onerror = event => {
      if (ownRun === runId) clearResult('分析失败：浏览器未能加载 MoonBit 模块。请先运行构建脚本。');
      event.preventDefault();
    };
    worker.onmessage = ({ data }) => {
      if (ownRun !== runId) return;
      worker.terminate();
      activeWorker = null;
      if (data.error) {
        clearResult('分析失败：' + data.error);
        return;
      }
      current = data;
      element('status').textContent = data.report.kind === 'diff'
        ? `比较完成 · 可见差异 ${data.report.visible_changes} 项 · 共 ${data.report.total_changes} 项`
        : `检查完成 · ${data.report.status} · ${data.report.findings.length} 条诊断`;
      element('report').srcdoc = data.html;
      element('report').hidden = false;
      element('empty').hidden = true;
      for (const kind of ['json', 'html']) {
        const content = kind === 'json' ? JSON.stringify(data.report, null, 2) : data.html;
        const type = kind === 'json' ? 'application/json' : 'text/html';
        const url = URL.createObjectURL(new Blob([content], { type: type + ';charset=utf-8' }));
        downloadUrls.push(url);
        const link = element(kind);
        link.href = url;
        link.download = 'nbinspect-report.' + kind;
        link.setAttribute('aria-disabled', 'false');
      }
    };
    worker.postMessage({ before, after, view: element('view').value });
  } catch (error) {
    if (ownRun === runId) clearResult('分析失败：' + error.message);
  }
}

element('check').addEventListener('click', () => analyze('check'));
element('compare').addEventListener('click', () => analyze('diff'));
element('sample').addEventListener('click', () => { sampleMode = true; analyze('diff'); });
for (const id of ['before', 'after']) {
  element(id).addEventListener('change', () => {
    sampleMode = false;
    clearResult('文件已选择。点击“检查”或“比较”开始分析。');
  });
}
element('view').addEventListener('change', () => {
  if (lastMode === 'diff' && current) analyze('diff');
});
