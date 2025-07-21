import fetch from 'node-fetch';
import { parse } from 'acorn';
import MagicString from 'magic-string';

async function inlineModule(url, seen = new Set()) {
  if (seen.has(url)) return '';
  seen.add(url);

  const res = await fetch(url);
  const source = await res.text();

  const ast = parse(source, {
    sourceType: 'module',
    ecmaVersion: 'latest',
    locations: true
  });

  const s = new MagicString(source);
  let inlined = '';

  for (const node of ast.body) {
    if (node.type === 'ImportDeclaration') {
      const depUrl = new URL(node.source.value, url).toString();
      inlined += await inlineModule(depUrl, seen);
      s.remove(node.start, node.end);
    }
    else if ((node.type === 'ExportNamedDeclaration' || node.type === 'ExportAllDeclaration')
      && node.source) {
      const depUrl = new URL(node.source.value, url).toString();
      inlined += await inlineModule(depUrl, seen);
      s.remove(node.start, node.end);
    }
  }

  return inlined + '\n' + s.toString();
}

async function run() {
  const [, , rawUrl] = process.argv;
  const url = decodeURIComponent(rawUrl);

  process.stdout.write(await inlineModule(url))
}

run()
