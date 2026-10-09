import { nbinspect_analyze_with_policy, nbinspect_parse_policy, nbinspect_render_report, nbinspect_review_with_policy, nbinspect_render_review } from './nbinspect.js';

let report = null;
self.onmessage = ({ data }) => {
  try {
    if (data.mode === 'policy') {
      const policy = JSON.parse(nbinspect_parse_policy(data.input));
      if (policy.error) throw new Error(policy.error);
      self.postMessage({ policy });
      return;
    }
    if (data.mode === 'render') {
      if (report?.kind !== 'review') throw new Error('没有可筛选的风险报告。');
      self.postMessage({ filtered: true, riskStatus: data.riskStatus, displayHtml: nbinspect_render_review(JSON.stringify(report), data.riskStatus) });
      return;
    }
    report = JSON.parse(data.mode === 'review'
      ? nbinspect_review_with_policy(data.before, data.after, data.policy || '')
      : nbinspect_analyze_with_policy(data.before, data.after, data.view, data.policy || ''));
    if (report.error) throw new Error(report.error);
    const input = JSON.stringify(report);
    const html = nbinspect_render_report(input);
    const displayHtml = report.kind === 'review' ? nbinspect_render_review(input, data.riskStatus) : html;
    self.postMessage({ report, html, displayHtml });
  } catch (error) {
    self.postMessage({ error: String(error?.message || error) });
  }
};
