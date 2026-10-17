// Gera o site estático em dist/ a partir de src/ e public/. Sem dependências.
import { cp, link, mkdir, readFile, readdir, rm, stat, writeFile, copyFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { layout } from '../src/templates/layout.mjs';
import { home } from '../src/templates/home.mjs';
import { docs } from '../src/templates/docs.mjs';
import { terceiros } from '../src/templates/terceiros.mjs';
import { recursos } from '../src/templates/recursos.mjs';
import { downloads } from '../src/templates/downloads.mjs';
import { apoie } from '../src/templates/apoie.mjs';
import { novidades } from '../src/templates/novidades.mjs';
import { faq as faqPage } from '../src/templates/faq.mjs';
import { privacidade } from '../src/templates/privacidade.mjs';
import { primaryAsset, fmtSize } from '../src/lib.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(root, 'dist');
const json = async (n) => JSON.parse(await readFile(join(root, 'src', 'data', n), 'utf8'));

export async function build() {
  const t0 = Date.now();
  const [site, release, features, requirements, changelog, faq] = await Promise.all(
    ['site', 'release', 'features', 'requirements', 'changelog', 'faq'].map((n) => json(n + '.json'))
  );
  const data = { site, release, features, requirements, changelog, faq };
  const dl = primaryAsset(release);

  await rm(out, { recursive: true, force: true });
  await mkdir(join(out, 'css'), { recursive: true });
  await mkdir(join(out, 'js'), { recursive: true });

  // Estáticos: tudo de public/, exceto downloads/ (pacotes grandes: link físico em vez de cópia).
  for (const e of await readdir(join(root, 'public'), { withFileTypes: true })) {
    if (e.name === 'downloads') continue;
    await cp(join(root, 'public', e.name), join(out, e.name), { recursive: true });
  }
  const dlDir = join(root, 'public', 'downloads');
  const dlFiles = await readdir(dlDir).catch(() => []);
  if (dlFiles.length) await mkdir(join(out, 'downloads'), { recursive: true });
  for (const f of dlFiles) {
    try { await link(join(dlDir, f), join(out, 'downloads', f)); } catch { await copyFile(join(dlDir, f), join(out, 'downloads', f)); }
  }

  const fonts = await readFile(join(root, 'src', 'fonts.css'), 'utf8');
  await writeFile(join(out, 'css', 'site.css'), fonts + '\n' + (await readFile(join(root, 'src', 'site.css'), 'utf8')));
  await cp(join(root, 'src', 'site.js'), join(out, 'js', 'site.js'));

  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: site.productName,
    applicationCategory: 'UtilitiesApplication',
    operatingSystem: 'Linux (x86-64)',
    softwareVersion: release.version,
    description: site.description,
    inLanguage: 'pt-BR',
    ...(site.siteUrl && dl ? { downloadUrl: new URL(dl.url, site.siteUrl.replace(/\/?$/, '/')).href } : {}),
    ...(dl ? { fileSize: fmtSize(dl.sizeBytes) } : {})
  };

  const sub = (page, slug, title, description, body) => [`${slug}/index.html`, layout({ site, release, root: '../', page, title: `${title} — ${site.productName}`, description, canonicalPath: `${slug}/`, body })];
  const noticesMd = await readFile(resolve(root, '..', 'THIRD_PARTY_NOTICES.md'), 'utf8').catch(() => '| Componente | Uso | Licença |\n|---|---|---|\n');
  const pages = [
    ['index.html', layout({ site, release, root: '', page: 'home', title: site.title, description: site.description, canonicalPath: '', jsonLd, body: home(data) })],
    sub('recursos', 'recursos', 'Recursos', 'O que o SECADA já faz hoje, o que ele não faz e o que está planejado.', recursos(data)),
    sub('downloads', 'downloads', 'Downloads', 'Baixe o SECADA para Linux: pacote portátil (.tar.gz) e pacote Debian (.deb), com tamanho, SHA-256, instalação e requisitos.', downloads(data)),
    sub('docs', 'docs', 'Documentação', 'Como instalar, usar e resolver problemas no SECADA: instalação, APK e XAPK, configurações, mapeador de teclas e tradução ARM.', docs(data)),
    sub('apoie', 'apoie', 'Apoie o projeto', 'O SECADA é gratuito. Veja como contribuir de forma voluntária com o desenvolvimento.', apoie(data)),
    sub('novidades', 'novidades', 'Novidades', 'Histórico de versões do SECADA: novos recursos, mudanças e correções.', novidades(data)),
    sub('faq', 'faq', 'Perguntas frequentes', 'Perguntas frequentes sobre o SECADA: distribuições, instalação, APK, requisitos, gratuidade e bugs.', faqPage(data)),
    sub('privacidade', 'privacidade', 'Privacidade', 'O que o site e o programa SECADA fazem com a rede e os dados do usuário.', privacidade()),
    sub('terceiros', 'terceiros', 'Componentes de terceiros', 'Componentes de terceiros incluídos ou usados pelo SECADA e suas licenças.', terceiros(noticesMd))
  ];
  for (const [name, html] of pages) {
    await mkdir(dirname(join(out, name)), { recursive: true });
    await writeFile(join(out, name), html);
  }
  await writeFile(join(out, '404.html'), layout({ site, release, root: '/', page: '404', title: `Página não encontrada — ${site.productName}`, description: site.description, body: `<div class="wrap" style="padding-block:120px"><h1>Página não encontrada</h1><p class="lead" style="margin-top:16px;color:var(--muted)">O endereço não existe. <a href="/">Voltar ao início</a>.</p></div>` }));

  if (site.siteUrl) {
    const base = site.siteUrl.replace(/\/?$/, '/');
    await writeFile(join(out, 'robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${base}sitemap.xml\n`);
    await writeFile(join(out, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${['', 'recursos/', 'downloads/', 'docs/', 'apoie/', 'novidades/', 'faq/', 'privacidade/', 'terceiros/'].map((p) => `  <url><loc>${base}${p}</loc></url>`).join('\n')}\n</urlset>\n`);
  } else {
    await writeFile(join(out, 'robots.txt'), 'User-agent: *\nAllow: /\n');
  }
  console.log(`site gerado em dist/ (${Date.now() - t0} ms)`);
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('build.mjs')) await build();
