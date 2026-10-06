import { nbinspect_analyze, nbinspect_render_report } from './nbinspect.js';

self.onmessage = ({ data }) => {
  try {
    const report = JSON.parse(nbinspect_analyze(data.before, data.after, data.view));
    if (report.error) throw new Error(report.error);
    const html = nbinspect_render_report(JSON.stringify(report));
    self.postMessage({ report, html });
  } catch (error) {
    self.postMessage({ error: String(error?.message || error) });
  }
};
