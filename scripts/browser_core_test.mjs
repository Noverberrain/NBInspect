import assert from 'node:assert/strict';
import { nbinspect_analyze, nbinspect_render_report } from '../web/nbinspect.js';

const cell = (id, source) => ({ id, cell_type: 'code', source, metadata: {}, execution_count: null, outputs: [] });
const notebook = cells => JSON.stringify({ nbformat: 4, nbformat_minor: 5, metadata: {}, cells });
const before = notebook([cell('setup', 'x = 1\n'), cell('print', 'print(x)\n')]);
const after = notebook([cell('print', 'print(x + 1)\n'), cell('setup', 'x = 1\n')]);

const check = JSON.parse(nbinspect_analyze(before, '', 'all'));
assert.equal(check.kind, 'check');
assert.equal(check.cell_count, 2);
const diff = JSON.parse(nbinspect_analyze(before, after, 'all'));
assert.equal(diff.kind, 'diff');
assert.ok(diff.visible_changes >= 1);
assert.equal(diff.matches.length, 2);
const bad = JSON.parse(nbinspect_analyze('{', '', 'all'));
assert.ok(bad.error);
const html = nbinspect_render_report(JSON.stringify(diff));
assert.match(html, /<!doctype html>/i);
assert.match(html, /Matching evidence/);
console.log('Browser MoonBit bridge: check, diff, diagnostics, HTML passed');
