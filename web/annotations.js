// Human decisions are kept separate from the immutable analysis report.
export function createAnnotations(element, document, Blob, URL) {
  const labels = { 'needs-action': '需处理', confirmed: '已确认', accepted: '允许保留' };
  let data = null;
  const notes = new Map();
  let urls = [];
  let importVersion = 0;
  const importLimit = 20 * 1024 * 1024;
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
  function cancelImport() {
    importVersion++;
    element('notes-file').value = '';
  }
  function reset() {
    cancelImport();
    element('notes-file').disabled = true;
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
    element('notes-file').disabled = false;
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
    cancelImport();
    notes.set(index(), { decision, reason }); updateDownloads(); loadSelection();
  }
  function remove() {
    if (!selected()) return;
    cancelImport();
    notes.delete(index()); updateDownloads(); loadSelection();
  }
  function hasKeys(value, keys) {
    return value !== null && typeof value === 'object' && !Array.isArray(value) &&
      Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
  }
  // Object property order is irrelevant; array order and every report field matter.
  // Iteration also avoids recursive calls on untrusted nested JSON.
  function sameReport(left, right) {
    const pending = [[left, right]];
    while (pending.length) {
      const [a, b] = pending.pop();
      if (a === b) continue;
      if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
      const keys = Object.keys(a);
      if (keys.length !== Object.keys(b).length) return false;
      for (const key of keys) {
        if (!Object.hasOwn(b, key)) return false;
        pending.push([a[key], b[key]]);
      }
    }
    return true;
  }
  function validateImport(record, report) {
    if (!hasKeys(record, ['schema_version', 'kind', 'exported_at', 'report', 'notes']) ||
        record.schema_version !== 1 || record.kind !== 'review-notes' ||
        typeof record.exported_at !== 'string' || !Number.isFinite(Date.parse(record.exported_at))) {
      throw new Error('不是支持的 v1 标注记录');
    }
    if (!sameReport(record.report, report)) throw new Error('报告快照与当前分析不一致，请使用相同文件、规则及分析版本重新审阅');
    if (!Array.isArray(record.notes) || record.notes.length > report.changes.length) throw new Error('标注列表无效');
    const restored = new Map();
    for (const note of record.notes) {
      if (!hasKeys(note, ['change_index', 'decision', 'reason']) ||
          !Number.isInteger(note.change_index) || note.change_index < 0 || note.change_index >= report.changes.length ||
          restored.has(note.change_index) || !Object.hasOwn(labels, note.decision) || typeof note.decision !== 'string' ||
          typeof note.reason !== 'string' || note.reason.length > 2000 || (note.decision === 'accepted' && !note.reason.trim())) {
        throw new Error('存在重复、越界或无效标注，允许保留必须填写理由');
      }
      restored.set(note.change_index, { decision: note.decision, reason: note.reason });
    }
    return restored;
  }
  async function importNotes() {
    const ownVersion = ++importVersion;
    const snapshot = data;
    const file = element('notes-file').files[0];
    if (!snapshot) return;
    if (!file) {
      element('notes-status').textContent = '已取消导入，现有标注保持不变。'; return;
    }
    element('notes-status').textContent = '正在读取并校验标注记录…';
    try {
      if (file.size > importLimit) throw new Error('标注 JSON 超过 20 MiB 上限');
      const text = await file.text();
      if (ownVersion !== importVersion || data !== snapshot) return;
      if (new TextEncoder().encode(text).length > importLimit) throw new Error('标注 JSON 超过 20 MiB 上限');
      let record;
      try { record = JSON.parse(text.replace(/^\uFEFF/, '')); }
      catch { throw new Error('JSON 格式无效'); }
      const restored = validateImport(record, snapshot.report);
      // Commit only after the complete record passes; failed imports leave saved notes intact.
      notes.clear();
      for (const [key, note] of restored) notes.set(key, note);
      updateDownloads(); loadSelection();
      element('notes-status').textContent = '已导入 ' + notes.size + ' 项标注并替换原有标注；原始分析判定保持不变。';
    } catch (error) {
      if (ownVersion === importVersion && data === snapshot) element('notes-status').textContent = '导入失败，现有标注保持不变：' + error.message;
    } finally {
      if (ownVersion === importVersion) element('notes-file').value = '';
    }
  }
  element('notes-file').addEventListener('change', importNotes);
  element('note-item').addEventListener('change', loadSelection);
  element('note-save').addEventListener('click', save);
  element('note-remove').addEventListener('click', remove);
  reset();
  return { reset, start };
}
