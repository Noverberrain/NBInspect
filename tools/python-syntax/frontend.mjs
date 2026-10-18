import { Parser, Language } from './node_modules/web-tree-sitter/tree-sitter.js';

export const parserVersion = 'tree-sitter-python@0.25.0/web-tree-sitter@0.25.10';
export const limits = Object.freeze({ sourceBytes: 1048576, nodes: 50000, depth: 256 });

// The same WASM grammar is used in Node and the browser. No source is evaluated.
export async function createFrontend(grammarBytes) {
  await Parser.init();
  const language = await Language.load(grammarBytes);
  return source => {
    if (typeof source !== 'string' || !source.isWellFormed()) throw Error('source must be a well-formed Unicode string');
    if (source.length > limits.sourceBytes || new TextEncoder().encode(source).length > limits.sourceBytes) throw Error('source exceeds 1 MiB');
    const offsets = new Uint32Array(source.length + 1);
    const lines = [0];
    let bytes = 0;
    for (let i = 0; i < source.length;) {
      const code = source.codePointAt(i);
      const width = code > 0xffff ? 2 : 1;
      offsets[i] = bytes;
      if (width === 2) offsets[i + 1] = 0xffffffff;
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
      if (code === 10) lines.push(i + 1);
      i += width; offsets[i] = bytes;
    }
    const position = index => {
      if (!Number.isInteger(index) || index < 0 || index > source.length || offsets[index] === 0xffffffff) throw Error('parser returned an invalid UTF-16 boundary');
      let low = 0, high = lines.length;
      while (low + 1 < high) {
        const mid = low + Math.floor((high - low) / 2);
        if (lines[mid] <= index) low = mid; else high = mid;
      }
      return { byte_offset: offsets[index], line: low, column: offsets[index] - offsets[lines[low]] };
    };
    const parser = new Parser();
    let tree, cursor;
    try {
      parser.setLanguage(language);
      const deadline = performance.now() + 1000;
      tree = parser.parse(source, null, { progressCallback: () => performance.now() > deadline });
      if (!tree) throw Error('parser timed out or returned no tree');
      cursor = tree.walk();
      const nodes = [], ancestors = [];
      let active = true;
      while (active) {
        const depth = cursor.currentDepth;
        if (depth > limits.depth) throw Error('syntax depth exceeds 256');
        if (nodes.length >= limits.nodes) throw Error('syntax node count exceeds 50000');
        ancestors.length = depth;
        nodes.push({ parent: depth ? ancestors[depth - 1] : null, kind: cursor.nodeType,
          field_name: cursor.currentFieldName, named: cursor.nodeIsNamed, missing: cursor.nodeIsMissing,
          start: position(cursor.startIndex), end: position(cursor.endIndex) });
        ancestors[depth] = nodes.length - 1;
        if (cursor.gotoFirstChild()) continue;
        while (!cursor.gotoNextSibling()) {
          if (!cursor.gotoParent()) { active = false; break; }
        }
      }
      return { schema_version: 1, parser: parserVersion, source, root_has_error: tree.rootNode.hasError, nodes };
    } finally {
      cursor?.delete(); tree?.delete(); parser.delete();
    }
  };
}
