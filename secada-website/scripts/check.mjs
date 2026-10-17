// Verifica o site gerado: links internos, arquivos referenciados e IDs de âncora.
import { readFile, readdir, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const dist = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
const exists = (p) => stat(p).then(() => true, () => false);
const walk = async (d) => (await Promise.all((await readdir(d, { withFileTypes: true })).map((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)])))).flat();

const pages = (await walk(dist)).filter((f) => f.endsWith('.html') && !f.endsWith('404.html'));
let errors = 0;
const fail = (msg) => { errors++; console.error('✗', msg); };

const ids = {};
for (const p of pages) ids[p] = new Set([...(await readFile(p, 'utf8')).matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));

for (const page of pages) {
  const html = await readFile(page, 'utf8');
  const rel = page.slice(dist.length);
  for (const m of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    const url = m[1];
    if (/^(https?:|mailto:|data:|#$)/.test(url)) continue;
    const [pathPart, hash] = url.split('#');
    let target = pathPart ? resolve(dirname(page), pathPart) : page;
    if (!target.startsWith(dist)) { fail(`${rel}: ${url} sai do site`); continue; }
    if ((await stat(target).catch(() => null))?.isDirectory()) target = join(target, 'index.html');
    if (!(await exists(target))) { fail(`${rel}: ${url} não existe`); continue; }
    if (hash && target.endsWith('.html') && !ids[target]?.has(hash)) fail(`${rel}: âncora #${hash} não existe em ${target.slice(dist.length)}`);
  }
  const h1 = (html.match(/<h1[\s>]/g) ?? []).length;
  if (h1 !== 1) fail(`${rel}: esperado 1 <h1>, achei ${h1}`);
  for (const m of html.matchAll(/<img\b(?![^>]*\balt=)[^>]*>/g)) fail(`${rel}: <img> sem alt: ${m[0].slice(0, 60)}`);
}
console.log(errors ? `${errors} problema(s)` : `ok: ${pages.length} páginas, links e âncoras válidos`);
process.exit(errors ? 1 : 0);
