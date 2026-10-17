// Lê os pacotes gerados por ../scripts/build-release.sh (pasta ../dist), copia-os
// para public/downloads/ e atualiza src/data/release.json com versão, tamanho,
// data e SHA-256 reais. Rode depois de cada build de release do emulador.
//
//   npm run sync-release                 # copia os arquivos (links relativos)
//   npm run sync-release -- --no-copy    # só atualiza o JSON (arquivos hospedados fora)
//   npm run sync-release -- --base https://exemplo.com/releases/v0.1.0/
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { copyFile, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repo = resolve(root, '..');
const distDir = join(repo, 'dist');
const outDir = join(root, 'public', 'downloads');
const releaseFile = join(root, 'src', 'data', 'release.json');

const args = process.argv.slice(2);
const noCopy = args.includes('--no-copy');
const baseIdx = args.indexOf('--base');
const baseUrl = baseIdx >= 0 ? args[baseIdx + 1] : null;

const sha256 = (file) =>
  new Promise((ok, fail) => {
    const h = createHash('sha256');
    createReadStream(file).on('data', (c) => h.update(c)).on('end', () => ok(h.digest('hex'))).on('error', fail);
  });

const pubspec = await readFile(join(repo, 'app', 'pubspec.yaml'), 'utf8');
const version = /^version:\s*([0-9][^\s+]*)/m.exec(pubspec)?.[1];
if (!version) throw new Error('Versão não encontrada em app/pubspec.yaml');

const files = await readdir(distDir).catch(() => []);
const tar = files.find((f) => f === `secada-${version}-linux-x86_64.tar.gz`);
const deb = files.find((f) => f === `secada_${version}_amd64.deb`);
if (!tar && !deb) throw new Error(`Nenhum pacote ${version} em ${distDir}. Rode scripts/build-release.sh primeiro.`);

const release = JSON.parse(await readFile(releaseFile, 'utf8'));
const old = Object.fromEntries((release.assets ?? []).map((a) => [a.id, a]));
const meta = {
  tar: { kind: 'tar.gz', label: 'Pacote portátil', format: 'tar.gz', arch: 'x86-64', recommended: true,
    audience: 'Qualquer distribuição compatível. Instala na sua pasta pessoal, sem root.' },
  deb: { kind: 'deb', label: 'Pacote Debian', format: 'deb', arch: 'amd64',
    audience: 'Debian, Ubuntu e derivados (testado no Linux Mint 22.3). Instala em /opt/secada.' }
};

const assets = [];
for (const [id, file] of [['tar', tar], ['deb', deb]]) {
  if (!file) continue;
  const src = join(distDir, file);
  const info = await stat(src);
  if (!noCopy) {
    await mkdir(outDir, { recursive: true });
    await copyFile(src, join(outDir, file));
  }
  assets.push({
    ...meta[id], ...(old[id] ? { note: old[id].note } : {}), id, file,
    url: baseUrl ? new URL(file, baseUrl).href : `downloads/${file}`,
    sizeBytes: info.size,
    sha256: await sha256(src)
  });
  console.log(`${file}  ${(info.size / 1048576).toFixed(1)} MB`);
}

const newest = (await Promise.all(assets.map((a) => stat(join(distDir, a.file))))).reduce((m, s) => (s.mtime > m ? s.mtime : m), new Date(0));
release.version = version;
release.date = release.version === old.version && release.date ? release.date : newest.toISOString().slice(0, 10);
release.assets = assets;
await writeFile(releaseFile, JSON.stringify(release, null, 2) + '\n');
console.log(`release.json atualizado: ${version}`);
