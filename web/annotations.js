// Human decisions are kept separate from the immutable analysis report.
export function createAnnotations(element, document, Blob, URL) {
  const labels = { 'needs-action': '需处理', confirmed: '已确认', accepted: '允许保留' };
  let data = null;
  const notes = new Map();
  let urls = [];
  const escape = value => String(value).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[c]);
  const index = () => Number(element('note-item').value);
  function clearDownloads() {
    urls.forEach(url => URL.revokeObjectURL(url)); urls = [];
    for (const kind of ['json', 'html']) {
      element('notes-' + kind).removeAttribute('href');
      element('notes-' + kind).setAttribute('aria-disabled', 'true');
    }
  }
  function reset() {
    data = null; notes.clear(); clearDownloads();
    element('notes-panel').hidden = true;
    element('note-item').replaceChildren();
    element('note-reason').value = '';
    element('note-context').textContent = '';
    for (const id of ['note-item', 'note-decision', 'note-reason', 'note-save', 'note-remove']) element(id).disabled = true;
    element('notes-status').textContent = '标注仅保存在当前页面，导出后可保留记录。';
  }
  function selected() {
    if (!data || !Number.isInteger(index()) || index() < 0 || index() >= data.report.changes.length) return null;
    return data.report.changes[index()];
  }
  function loadSelection() {
    const row = selected(); if (!row) return;
    const finding = row.after || row.before;
    const note = notes.get(index());
    element('note-context').textContent = '#' + (index() + 1) + ' · ' + row.status + ' · ' + finding.code + ' · ' + finding.path + '\n' + finding.message;
    element('note-decision').value = note?.decision || 'needs-action';
    element('note-reason').value = note?.reason || '';
    element('note-remove').disabled = !note;
  }
  function start(result) {
    reset();
    if (result.report.kind !== 'review') return;
    data = result;
    element('notes-panel').hidden = false;
    // Append individually to avoid argument limits on large reports.
    data.report.changes.forEach((row, i) => {
      const option = document.createElement('option');
      const finding = row.after || row.before;
      option.value = String(i);
      option.textContent = '#' + (i + 1) + ' · ' + row.status + ' · ' + finding.code + ' · ' + finding.path;
      element('note-item').appendChild(option);
    });
    element('note-item').value = '0';
    for (const id of ['note-item', 'note-decision', 'note-reason', 'note-save']) element(id).disabled = !data.report.changes.length;
    element('notes-status').textContent = data.report.changes.length ? '已标注 0 / ' + data.report.changes.length + ' 项；保存后可导出记录。' : '当前报告没有风险项可标注。';
    loadSelection();
  }
  function updateDownloads() {
    clearDownloads();
    element('notes-status').textContent = '已标注 ' + notes.size + ' / ' + data.report.changes.length + ' 项；原始分析判定保持不变。';
    if (!notes.size) return;
    const rows = [...notes.entries()].sort(([a], [b]) => a - b).map(([change_index, value]) => ({ change_index, ...value }));
    const record = { schema_version: 1, kind: 'review-notes', exported_at: new Date().toISOString(), report: data.report, notes: rows };
    const body = rows.map(note => {
      const change = data.report.changes[note.change_index];
      const finding = change.after || change.before;
      return '<tr><td>' + (note.change_index + 1) + '</td><td>' + escape(change.status + ' / ' + finding.code + ' / ' + finding.path) + '</td><td>' + escape(labels[note.decision]) + '</td><td><pre>' + escape(note.reason) + '</pre></td></tr>';
    }).join('');
    const section = '<section id="human-review-notes"><h2>Human review notes / 人工审阅标注</h2><p>These decisions do not change the original analysis status or CI gates. Original status: ' + escape(data.report.status) + '.</p><div style="overflow-x:auto"><table style="width:100%;border-collapse:collapse"><thead><tr><th>Item</th><th>Original finding</th><th>Decision</th><th>Reason</th></tr></thead><tbody>' + body + '</tbody></table></div></section>';
    const html = data.html.replace('</main>', section + '</main>');
    for (const [kind, content, type] of [['json', JSON.stringify(record, null, 2), 'application/json'], ['html', html, 'text/html']]) {
      const url = URL.createObjectURL(new Blob([content], { type: type + ';charset=utf-8' }));
      urls.push(url);
      const link = element('notes-' + kind);
      link.href = url; link.download = 'nbinspect-review-notes.' + kind;
      link.setAttribute('aria-disabled', 'false');
    }
  }
  function save() {
    if (!selected()) return;
    const decision = element('note-decision').value;
    const reason = element('note-reason').value;
    if (!Object.hasOwn(labels, decision) || reason.length > 2000) {
      element('notes-status').textContent = '未保存：状态无效或理由超过 2000 字符。'; return;
    }
    if (decision === 'accepted' && !reason.trim()) {
      element('notes-status').textContent = '未保存：“允许保留”需要填写理由。'; return;
    }
    notes.set(index(), { decision, reason }); updateDownloads(); loadSelection();
  }
  function remove() {
    if (!selected()) return;
    notes.delete(index()); updateDownloads(); loadSelection();
  }
  element('note-item').addEventListener('change', loadSelection);
  element('note-save').addEventListener('click', save);
  element('note-remove').addEventListener('click', remove);
  reset();
  return { reset, start };
}
