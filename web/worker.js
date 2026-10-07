import { nbinspect_analyze, nbinspect_render_report, nbinspect_review, nbinspect_render_review } from './nbinspect.js';

let report = null;
self.onmessage = ({ data }) => {
  try {
    if (data.mode === 'render') {
      if (report?.kind !== 'review') throw new Error('没有可筛选的风险报告。');
      self.postMessage({ filtered: true, riskStatus: data.riskStatus, displayHtml: nbinspect_render_review(JSON.stringify(report), data.riskStatus) });
      return;
    }
    report = JSON.parse(data.mode === 'review'
      ? nbinspect_review(data.before, data.after)
      : nbinspect_analyze(data.before, data.after, data.view));
    if (report.error) throw new Error(report.error);
    const input = JSON.stringify(report);
    const html = nbinspect_render_report(input);
    const displayHtml = report.kind === 'review' ? nbinspect_render_review(input, data.riskStatus) : html;
    self.postMessage({ report, html, displayHtml });
  } catch (error) {
    self.postMessage({ error: String(error?.message || error) });
  }
};
