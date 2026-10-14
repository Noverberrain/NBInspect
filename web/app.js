import { createAnnotations } from './annotations.js';
const element = id => document.getElementById(id);
const annotations = createAnnotations(element, document, Blob, URL);
const inputLimit = 10 * 1024 * 1024;
let activeWorker = null;
let runId = 0;
let current = null;
let downloadUrls = [];
let lastMode = null;
let sampleMode = false;
let policyText = '';
let policyLoading = false;
let policyError = '';
let policyVersion = 0;
let policyWorker = null;
let budgetText = '';
let budgetVersion = 0;
let budgetWorker = null;
// Demo has explicit zero allowances and never substitutes an imported budget.
const sampleBudget = JSON.stringify({ limits: { max_notebook_growth_bytes: 0, max_output_growth_bytes: 0, max_attachment_growth_bytes: 0 } });

const cell = (id, source) => ({ id, cell_type: 'code', source, metadata: {}, execution_count: null, outputs: [] });
const prose = (id, source) => ({ id, cell_type: 'markdown', source, metadata: {} });
const notebook = cells => JSON.stringify({ nbformat: 4, nbformat_minor: 5, metadata: {}, cells });
const sampleBefore = notebook([cell('setup', 'x = 1\n'), cell('compute', 'print(x)\n'), cell('ending', 'print("done")\n'), prose('notes', '# Results\n')]);
const sampleAfter = notebook([cell('compute', 'print(x + 1)\n'), cell('setup', 'x = 1\n'), cell('ending', 'print("done")\n'), prose('notes', '# Updated results\n')]);

const failedCell = (id, source, message) => ({ ...cell(id, source), outputs: [{ output_type: 'error', ename: 'DemoError', evalue: message, traceback: [] }] });
const riskBefore = notebook([
  failedCell('existing', 'print("same")', 'saved error'),
  failedCell('fixed', 'print("fixed")', 'old error'),
  cell('new-risk', 'print("new")'),
  failedCell(undefined, 'alpha()', 'unmatched old error'),
]);
const riskAfter = notebook([
  cell('fixed', 'print("fixed")'),
  failedCell('existing', 'print("same")', 'saved error'),
  failedCell('new-risk', 'print("new")', 'new error'),
  failedCell(undefined, 'omega()', 'unmatched new error'),
]);


// Stored media are counted as JSON values; no sample payload is rendered.
const profileSample = notebook([
  cell('setup', 'values = list(range(1000))\n'),
  { ...cell('results', 'print(values)\n'), outputs: [
    { output_type: 'stream', name: 'stdout', text: '示例运行输出：0, 1, 2, 3, 4\n'.repeat(800) },
    { output_type: 'display_data', data: { 'image/png': 'iVBORw0KGgo=', 'text/html': '<p>示例结果</p>' }, metadata: {} },
  ] },
  { ...prose('notes', '![示例图](attachment:demo.svg)\n'), attachments: {
    'demo.svg': { 'image/svg+xml': '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><circle cx="10" cy="10" r="8"/></svg>' },
  } },
]);
// Handwritten storage changes, not execution results: move notes, grow output/attachment.
const profileAfter = JSON.parse(profileSample);
profileAfter.cells = [profileAfter.cells[2], profileAfter.cells[0], profileAfter.cells[1]];
profileAfter.cells[0].attachments['demo.svg']['image/svg+xml'] += ' '.repeat(200);
profileAfter.cells[2].source = 'print(values[:200])\n';
profileAfter.cells[2].outputs[0].text += '新增示例输出\n'.repeat(400);
const profileDiffSampleAfter = JSON.stringify(profileAfter);

function clearResult(message) {
  annotations.reset();
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
  element('risk-status').disabled = true;
  element('risk-controls').hidden = true;
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
  if (policyLoading && !['profile', 'profile-diff', 'budget'].includes(mode)) return;
  if (['check', 'review'].includes(mode) && policyError) {
    clearResult('规则配置无效，请重新导入或恢复默认规则。');
    return;
  }
  if (mode === 'budget' && !sampleMode && !budgetText) {
    clearResult('请先导入有效的增长预算 JSON 配置。');
    return;
  }
  const selectedBudget = sampleMode ? sampleBudget : budgetText;
  clearResult('正在分析…');
  const ownRun = runId;
  lastMode = mode;
  try {
    const before = sampleMode ? (['profile', 'profile-diff', 'budget'].includes(mode) ? profileSample : mode === 'review' ? riskBefore : sampleBefore) : await readNotebook('before');
    const after = ['check', 'profile'].includes(mode) ? '' : sampleMode ? (['profile-diff', 'budget'].includes(mode) ? profileDiffSampleAfter : mode === 'review' ? riskAfter : sampleAfter) : await readNotebook('after');
    if (ownRun !== runId) return;
    const worker = new Worker('./worker.js', { type: 'module' });
    activeWorker = worker;
    worker.onerror = event => {
      if (ownRun === runId) clearResult('分析失败：浏览器未能加载 MoonBit 模块。请先运行构建脚本。');
      event.preventDefault();
    };
    worker.onmessage = ({ data }) => {
      if (ownRun !== runId) return;
      if (data.error) {
        clearResult('分析失败：' + data.error);
        return;
      }
      if (data.filtered) {
        if (data.riskStatus !== element('risk-status').value) return;
        element('report').srcdoc = data.displayHtml;
        showStatus();
        return;
      }
      if (data.report.kind !== 'review') {
        worker.terminate();
        activeWorker = null;
      }
      current = data;
      annotations.start(data);
      element('risk-controls').hidden = data.report.kind !== 'review';
      element('risk-status').disabled = data.report.kind !== 'review';
      showStatus();
      element('report').srcdoc = data.displayHtml;
      element('report').hidden = false;
      element('empty').hidden = true;
      for (const kind of ['json', 'html']) {
        const content = kind === 'json' ? JSON.stringify(data.report, null, 2) : data.html;
        const type = kind === 'json' ? 'application/json' : 'text/html';
        const url = URL.createObjectURL(new Blob([content], { type: type + ';charset=utf-8' }));
        downloadUrls.push(url);
        const link = element(kind);
        link.href = url;
        link.download = (['profile', 'profile-diff', 'budget'].includes(data.report.kind) ? 'nbinspect-' + data.report.kind + '.' : 'nbinspect-report.') + kind;
        link.setAttribute('aria-disabled', 'false');
      }
    };
    worker.postMessage({ mode, before, after, view: element('view').value, riskStatus: element('risk-status').value, policy: policyText, budget: selectedBudget });
  } catch (error) {
    if (ownRun === runId) clearResult('分析失败：' + error.message);
  }
}

function showStatus() {
  const report = current.report;
  if (report.kind === 'budget') {
    const labels = { notebook_bytes: '总体', output_bytes: '输出', attachment_bytes: '附件' };
    const failures = report.checks.filter(row => row.status === 'blocked').map(row => labels[row.metric] + '超额 ' + row.excess_bytes.toLocaleString('zh-CN') + ' 字节');
    element('status').textContent = (sampleMode ? '预算示例（固定零增长额度） · ' : '') + '预算检查完成 · ' + (report.status === 'blocked' ? '未通过 · ' + failures.join(' / ') : '通过 · 已配置的 ' + report.checks.length + ' 项均未超额') + ' · 仅检查体积，发布风险需另行审阅';
  } else if (report.kind === 'profile-diff') {
    const s = report.summary.delta;
    const signed = value => (value > 0 ? '+' : '') + value.toLocaleString('zh-CN');
    element('status').textContent = '体积比较完成 · 紧凑 JSON 增减 ' + signed(s.notebook_bytes) + ' 字节 · 正文 ' + signed(s.source_bytes) + ' / 输出 ' + signed(s.output_bytes) + ' / 附件 ' + signed(s.attachment_bytes) + ' / 其他 ' + signed(s.other_bytes) + ' 字节 · 匹配 ' + report.matched_count + ' 对 / 未匹配 ' + report.unmatched_before_count + ' → ' + report.unmatched_after_count + ' · 旧单元格歧义 ' + report.ambiguous_before.length + ' 项' + (report.ambiguous_before.length ? '（需人工复核）' : '');
  } else if (report.kind === 'profile') {
    const s = report.summary;
    element('status').textContent = '体积分析完成 · 紧凑 JSON ' + s.notebook_bytes.toLocaleString('zh-CN') + ' 字节 · 输出 ' + s.output_bytes.toLocaleString('zh-CN') + ' / 附件 ' + s.attachment_bytes.toLocaleString('zh-CN') + ' 字节 · ' + report.cell_count + ' 个单元格';
  } else if (report.kind === 'review') {
    const s = report.summary;
    const filter = element('risk-status').value;
    const visible = filter === 'all' ? report.changes.length : s[filter];
    element('status').textContent = '审阅完成 · 新增 ' + s.introduced + ' / 已有 ' + s.existing + ' / 已消除 ' + s.resolved + ' / 待确认 ' + s.uncertain + ' · 当前显示 ' + visible + ' 项 · ' + (report.status === 'blocked' ? '新增风险达到阻断级别' : '未新增阻断级别风险');
  } else {
    element('status').textContent = report.kind === 'diff'
      ? '比较完成 · 可见差异 ' + report.visible_changes + ' 项 · 共 ' + report.total_changes + ' 项'
      : '检查完成 · ' + report.status + ' · ' + report.findings.length + ' 条诊断';
  }
}

function setPolicyButtons() {
  for (const id of ['check', 'compare', 'review', 'sample', 'sample-review', 'profile', 'sample-profile', 'profile-diff', 'sample-profile-diff']) {
    element(id).disabled = (policyLoading && !['profile', 'sample-profile', 'profile-diff', 'sample-profile-diff'].includes(id)) || (policyError !== '' && ['check', 'review', 'sample-review'].includes(id));
  }
}

function policyFailed(message) {
  policyLoading = false;
  policyError = message;
  policyText = '';
  element('policy-status').textContent = '配置无效：' + message + '。请重新导入或恢复默认规则。';
  setPolicyButtons();
}

async function importPolicy() {
  const version = ++policyVersion;
  policyWorker?.terminate();
  policyWorker = null;
  policyText = '';
  policyError = '';
  policyLoading = true;
  clearResult('发布规则已更改，旧报告已清空。');
  element('policy-effective').hidden = true;
  element('policy-effective').textContent = '';
  element('policy-name').textContent = '正在读取…';
  element('policy-status').textContent = '正在校验规则配置…';
  setPolicyButtons();
  const file = element('policy-file').files[0];
  try {
    if (!file) { resetPolicy(); return; }
    element('policy-name').textContent = file.name;
    if (file.size > 1024 * 1024) throw new Error('规则文件超过 1 MiB 限制');
    const input = await file.text();
    if (version !== policyVersion) return;
    const worker = new Worker('./worker.js', { type: 'module' });
    policyWorker = worker;
    worker.onerror = event => {
      if (version === policyVersion) {
        worker.terminate();
        policyWorker = null;
        policyFailed('浏览器未能加载 MoonBit 模块');
      }
      event.preventDefault();
    };
    worker.onmessage = ({ data }) => {
      if (version !== policyVersion) return;
      worker.terminate();
      policyWorker = null;
      if (data.error) { policyFailed(data.error); return; }
      policyText = input;
      policyLoading = false;
      const policy = data.policy;
      const enabled = Object.values(policy.rules).filter(rule => rule.enabled).length;
      element('policy-status').textContent = '已应用 · ' + policy.fail_on + ' 阻断 · 启用 ' + enabled + '/' + Object.keys(policy.rules).length + ' 条规则 · 检查与风险审阅使用此策略，差异比较与体积分析不受影响。';
      element('policy-effective').textContent = JSON.stringify(policy, null, 2);
      element('policy-effective').hidden = false;
      setPolicyButtons();
    };
    worker.postMessage({ mode: 'policy', input });
  } catch (error) {
    if (version === policyVersion) policyFailed(error.message);
  }
}

function resetPolicy() {
  policyVersion++;
  policyWorker?.terminate();
  policyWorker = null;
  policyText = '';
  policyError = '';
  policyLoading = false;
  element('policy-file').value = '';
  element('policy-name').textContent = '默认规则';
  element('policy-status').textContent = '默认规则 · error 阻断 · 导入 JSON 可调整严重等级、启用规则及输出大小阈值。';
  element('policy-effective').hidden = true;
  element('policy-effective').textContent = '';
  setPolicyButtons();
  clearResult('已恢复默认规则，点击操作重新分析。');
}

function clearBudget(clearFile = true) {
  budgetVersion++;
  budgetWorker?.terminate();
  budgetWorker = null;
  budgetText = '';
  element('budget').disabled = true;
  if (clearFile) element('budget-file').value = '';
  element('budget-name').textContent = '未导入';
  element('budget-effective').hidden = true;
  element('budget-effective').textContent = '';
  element('budget-status').textContent = '需显式导入增长预算；未配置的类别不检查，0 表示不允许正增长。';
  clearResult('增长预算已清除，旧报告已清空。');
}

async function importBudget() {
  const file = element('budget-file').files[0];
  clearBudget(false);
  const version = budgetVersion;
  if (!file) return;
  element('budget-name').textContent = file.name;
  element('budget-status').textContent = '正在校验增长预算…';
  const failed = message => {
    element('budget-status').textContent = '预算无效：' + message + '。请重新导入。';
  };
  try {
    if (file.size > 1024 * 1024) throw new Error('预算文件超过 1 MiB 限制');
    const input = await file.text();
    if (version !== budgetVersion) return;
    const worker = new Worker('./worker.js', { type: 'module' });
    budgetWorker = worker;
    worker.onerror = event => {
      if (version === budgetVersion) {
        worker.terminate();
        budgetWorker = null;
        failed('浏览器未能加载 MoonBit 模块');
      }
      event.preventDefault();
    };
    worker.onmessage = ({ data }) => {
      if (version !== budgetVersion) return;
      worker.terminate();
      budgetWorker = null;
      if (data.error) { failed(data.error); return; }
      budgetText = JSON.stringify(data.budget);
      element('budget-effective').textContent = JSON.stringify(data.budget, null, 2);
      element('budget-effective').hidden = false;
      element('budget-status').textContent = '预算已应用 · ' + Object.keys(data.budget.limits).length + ' 项额度 · 恰好达到预算或缩减通过；与发布规则独立。';
      element('budget').disabled = false;
    };
    worker.postMessage({ mode: 'budget-config', input });
  } catch (error) {
    if (version === budgetVersion) failed(error.message);
  }
}

element('budget-file').addEventListener('change', importBudget);
element('budget-reset').addEventListener('click', () => clearBudget());
element('budget').addEventListener('click', () => { sampleMode = false; analyze('budget'); });
element('sample-budget').addEventListener('click', () => { sampleMode = true; analyze('budget'); });
element('policy-file').addEventListener('change', importPolicy);
element('policy-reset').addEventListener('click', resetPolicy);
element('check').addEventListener('click', () => analyze('check'));
element('profile').addEventListener('click', () => { sampleMode = false; analyze('profile'); });
element('sample-profile').addEventListener('click', () => { sampleMode = true; analyze('profile'); });
element('profile-diff').addEventListener('click', () => { sampleMode = false; analyze('profile-diff'); });
element('sample-profile-diff').addEventListener('click', () => { sampleMode = true; analyze('profile-diff'); });
element('compare').addEventListener('click', () => analyze('diff'));
element('review').addEventListener('click', () => analyze('review'));
element('sample-review').addEventListener('click', () => { sampleMode = true; analyze('review'); });
element('sample').addEventListener('click', () => { sampleMode = true; analyze('diff'); });
for (const id of ['before', 'after']) {
  element(id).addEventListener('change', () => {
    sampleMode = false;
    clearResult('文件已选择。点击“检查”“比较”“审阅发布风险”、“分析原始文件体积”、“比较体积变化”或“检查增长预算”开始分析。');
  });
}
element('view').addEventListener('change', () => {
  if (lastMode === 'diff' && current) analyze('diff');
});

element('risk-status').addEventListener('change', () => {
  if (current?.report.kind === 'review' && activeWorker) {
    activeWorker.postMessage({ mode: 'render', riskStatus: element('risk-status').value });
  }
});
window.addEventListener('pagehide', () => {
  budgetVersion++;
  budgetWorker?.terminate();
  budgetWorker = null;
  policyVersion++;
  policyWorker?.terminate();
  policyWorker = null;
  clearResult('选择文件开始分析。');
});
