// Servidor local: gera o site, serve dist/ e regera quando src/ ou public/ mudam.
//   npm run dev                -> http://localhost:4321 (com regeração)
//   npm run preview            -> só serve o que já está em dist/
import { createServer } from 'node:http';
import { createReadStream } from 'node:fs';
import { readdir, stat } from 'node:fs/promises';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

// Cada regeração roda num processo novo: módulos ES ficam em cache dentro do processo.
const build = () => promisify(execFile)(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'build.mjs')]).then(({ stdout }) => console.log(stdout.trim()));

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
const port = Number(process.env.PORT || 4321);
const watch = !process.argv.includes('--no-watch');
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webp': 'image/webp', '.woff2': 'font/woff2', '.txt': 'text/plain', '.xml': 'application/xml', '.gz': 'application/gzip', '.deb': 'application/vnd.debian.binary-package' };

if (watch || !(await stat(dist).catch(() => null))) await build();

createServer(async (req, res) => {
  let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  let file = normalize(join(dist, p));
  if (!file.startsWith(dist)) { res.writeHead(403).end(); return; }
  let st = await stat(file).catch(() => null);
  if (st?.isDirectory()) { file = join(file, 'index.html'); st = await stat(file).catch(() => null); }
  if (!st) { res.writeHead(404, { 'content-type': types['.html'] }); createReadStream(join(dist, '404.html')).pipe(res); return; }
  res.writeHead(200, { 'content-type': types[extname(file)] ?? 'application/octet-stream', 'content-length': st.size, 'cache-control': 'no-cache' });
  createReadStream(file).pipe(res);
}).listen(port, () => console.log(`http://localhost:${port}`));

if (watch) {
  // Node 18 não tem fs.watch recursivo no Linux: compara mtimes a cada 700 ms.
  const watched = ['src', 'public'].map((d) => join(root, d));
  const snap = async (dir) => {
    let sum = 0;
    for (const e of await readdir(dir, { withFileTypes: true })) {
      if (e.name === 'downloads') continue;
      const f = join(dir, e.name);
      sum += e.isDirectory() ? await snap(f) : (await stat(f)).mtimeMs;
    }
    return sum;
  };
  let last = (await Promise.all(watched.map(snap))).reduce((a, b) => a + b, 0);
  setInterval(async () => {
    const now = (await Promise.all(watched.map(snap))).reduce((a, b) => a + b, 0);
    if (now !== last) { last = now; try { await build(); } catch (e) { console.error(e); } }
  }, 700);
}
