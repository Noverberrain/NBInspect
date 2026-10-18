import { readFile, mkdir, writeFile, mkdtemp, unlink, rmdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createFrontend } from './frontend.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const usage = 'node tools/python-syntax/probe.mjs SOURCE.py [--backend js|native] [--mode syntax|bindings] [--output FILE]';
try {
  const args = process.argv.slice(2);
  if (!args.length || args[0] === '--help') { console.log(usage); process.exit(0); }
  const sourcePath = args.shift();
  let backend = 'js', mode = 'syntax', output;
  const seen = new Set();
  while (args.length) {
    const flag = args.shift(), value = args.shift();
    if (!value || seen.has(flag) || !['--backend', '--output', '--mode'].includes(flag)) throw Error(usage);
    seen.add(flag);
    if (flag === '--backend') backend = value; else if (flag === '--mode') mode = value; else output = value;
  }
  if (!['js', 'native'].includes(backend)) throw Error('backend must be js or native');
  if (!['syntax', 'bindings'].includes(mode)) throw Error('mode must be syntax or bindings');
  // Bounded reads also reject a file that grows after opening.
  const { open } = await import('node:fs/promises');
  const file = await open(sourcePath, 'r');
  let source;
  try {
    if (!(await file.stat()).isFile()) throw Error('source must be a regular file');
    const buffer = Buffer.alloc(1048577);
    let used = 0;
    while (used < buffer.length) {
      const { bytesRead } = await file.read(buffer, used, buffer.length - used, null);
      if (!bytesRead) break;
      used += bytesRead;
    }
    if (used > 1048576) throw Error('source exceeds 1 MiB');
    source = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(buffer.subarray(0, used));
  } finally { await file.close(); }
  const parse = await createFrontend(await readFile(new URL('./node_modules/tree-sitter-python/tree-sitter-python.wasm', import.meta.url)));
  const transport = JSON.stringify(parse(source));
  let result;
  if (backend === 'js') {
    const bridge = await import(new URL('../../_build/js/release/build/python_syntax/bridge/bridge.js', import.meta.url));
    result = JSON.parse((mode === 'bindings' ? bridge.nbinspect_python_bindings : bridge.nbinspect_python_syntax)(transport));
  } else {
    const directory = join(root, '_build', 'python-syntax');
    await mkdir(directory, { recursive: true });
    const temporary = await mkdtemp(join(directory, 'probe-'));
    const input = join(temporary, 'transport.json');
    try {
      await writeFile(input, transport, { flag: 'wx' });
      const executable = resolve(root, '_build/native/debug/build/cmd/python_syntax_probe/python_syntax_probe' + (process.platform === 'win32' ? '.exe' : ''));
      let stdout;
      try { stdout = execFileSync(executable, [input, ...(mode === 'bindings' ? ['--bindings'] : [])], { encoding: 'utf8', timeout: 10000, maxBuffer: 16777216, windowsHide: true }); }
      catch (error) { if (![1, 2].includes(error.status)) throw error; stdout = error.stdout; }
      result = JSON.parse(stdout);
    } finally { await unlink(input).catch(() => {}); await rmdir(temporary); }
  }
  if (result.error) throw Error(result.error);
  const json = JSON.stringify(result, null, 2) + '\n';
  if (output) await writeFile(output, json, { flag: 'wx' }); else process.stdout.write(json);
  process.exitCode = ['parse-errors', 'incomplete'].includes(result.status) ? 1 : 0;
} catch (error) {
  console.error('python syntax probe: ' + error.message + '\nPrepare first: pwsh -NoProfile -File scripts/prepare_python_syntax.ps1');
  process.exitCode = 2;
}
