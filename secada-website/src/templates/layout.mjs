import { esc, icon, primaryAsset } from '../lib.mjs';

const sprite = `<svg width="0" height="0" style="position:absolute" aria-hidden="true" focusable="false"><defs>
<symbol id="i-download" viewBox="0 0 24 24"><path d="M12 4v11m0 0-4-4m4 4 4-4M5 19.5h14"/></symbol>
<symbol id="i-copy" viewBox="0 0 24 24"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></symbol>
<symbol id="i-menu" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></symbol>
<symbol id="i-close" viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></symbol>
<symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
<symbol id="i-external" viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9M18 14v5H5V6h5"/></symbol>
<symbol id="i-window" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18"/></symbol>
<symbol id="i-box" viewBox="0 0 24 24"><path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5 12 12l8-4.5M12 12v9"/></symbol>
<symbol id="i-mouse" viewBox="0 0 24 24"><rect x="6" y="3" width="12" height="18" rx="6"/><path d="M12 7v4"/></symbol>
<symbol id="i-gamepad" viewBox="0 0 24 24"><path d="M6.5 8h11a4.5 4.5 0 0 1 4.4 5.4l-.6 2.8a2.4 2.4 0 0 1-4.2 1L15.5 15h-7l-1.6 2.2a2.4 2.4 0 0 1-4.2-1l-.6-2.8A4.5 4.5 0 0 1 6.5 8z"/><path d="M8 10.5v3M6.5 12h3M16 11h.01M18 13h.01"/></symbol>
<symbol id="i-chip" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="1.5"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/></symbol>
<symbol id="i-desktop" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></symbol>
<symbol id="i-gauge" viewBox="0 0 24 24"><path d="M4 16a8 8 0 1 1 16 0"/><path d="M12 16l4-5M4 16h2M18 16h2"/></symbol>
<symbol id="i-list" viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01"/></symbol>
<symbol id="i-sliders" viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/></symbol>
<symbol id="i-leaf" viewBox="0 0 24 24"><path d="M5 19c0-9 5-14 15-14 0 10-5 15-14 15"/><path d="M5 19l8-8"/></symbol>
<symbol id="i-arrow" viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></symbol>
</defs></svg>`;

export function layout({ site, release, root = '', page = 'home', title, description, canonicalPath = '', body, jsonLd }) {
  const dl = primaryAsset(release);
  const url = site.siteUrl ? new URL(canonicalPath, site.siteUrl.replace(/\/?$/, '/')).href : null;
  const ogImage = site.siteUrl ? new URL('img/og.png', site.siteUrl.replace(/\/?$/, '/')).href : `${root}img/og.png`;
  const nav = [
    ['Recursos', `${root}recursos/`, 'recursos'],
    ['Downloads', `${root}downloads/`, 'downloads'],
    ['Documentação', `${root}docs/`, 'docs'],
    ['Apoie o projeto', `${root}apoie/`, 'apoie']
  ];
  return `<!doctype html>
<html lang="${site.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta name="theme-color" content="#f6f7f8">
${url ? `<link rel="canonical" href="${esc(url)}">` : ''}
<link rel="icon" type="image/png" sizes="32x32" href="${root}img/favicon-32.png">
<link rel="apple-touch-icon" href="${root}img/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${esc(site.productName)}">
<meta property="og:locale" content="pt_BR">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:image" content="${esc(ogImage)}">
<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
${url ? `<meta property="og:url" content="${esc(url)}">` : ''}
<meta name="twitter:card" content="summary_large_image">
<link rel="preload" href="${root}fonts/sora-700-latin.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="${root}css/site.css">
${jsonLd ? `<script type="application/ld+json">${JSON.stringify(jsonLd)}</script>` : ''}
</head>
<body>
${sprite}
<a class="skip" href="#main">Ir para o conteúdo</a>
<header class="site-header">
  <div class="wrap">
    <a class="brand" href="${root || './'}" aria-label="${esc(site.productName)} — início"><img src="${root}img/secada-logo-escuro.svg" alt="SECADA" width="72" height="36"></a>
    <button class="menu-btn" type="button" aria-controls="nav" aria-expanded="false" aria-label="Abrir menu">${icon('menu', 'i-open')}${icon('close', 'i-close')}</button>
    <nav class="nav" id="nav" aria-label="Principal">
      ${nav.map(([label, href, key]) => `<a href="${href}"${page === key ? ' aria-current="page"' : ''}>${label}</a>`).join('\n      ')}
      <a class="btn btn-primary btn-sm" href="${dl ? root + dl.url : root + 'downloads/'}"${dl ? ' download' : ''}>${icon('download')}Baixar</a>
    </nav>
  </div>
</header>
<main id="main">
${body}
</main>
${footer({ site, release, root })}
<div id="live" class="sr-only" role="status" aria-live="polite" style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)"></div>
<script src="${root}js/site.js" defer></script>
</body>
</html>
`;
}

function footer({ site, release, root }) {
  const l = site.links;
  const ext = (href, label) => `<a href="${esc(href)}" rel="noopener">${label}</a>`;
  return `<footer class="site-footer">
  <div class="wrap">
    <div class="foot-row">
      <img src="${root}img/secada-logo-escuro.svg" alt="SECADA" width="68" height="34">
      <nav aria-label="Rodapé">
        <a href="${root}recursos/">Recursos</a>
        <a href="${root}downloads/">Downloads</a>
        <a href="${root}docs/">Documentação</a>
        <a href="${root}novidades/">Novidades</a>
        <a href="${root}faq/">Perguntas frequentes</a>
        <a href="${root}apoie/">Apoie o projeto</a>
        ${l.repository ? ext(l.repository, 'Repositório') : ''}
        ${l.issues ? ext(l.issues, 'Reportar um bug') : ''}
        ${l.discord ? ext(l.discord, 'Discord') : ''}
        ${l.contactEmail ? `<a href="mailto:${esc(l.contactEmail)}">Contato</a>` : ''}
        <a href="${root}privacidade/">Privacidade</a>
        <a href="${root}terceiros/">Componentes de terceiros</a>
      </nav>
    </div>
    <p class="legal">${esc(site.productName)} ${esc(release.version)}${l.license ? ` · <a href="${esc(l.license)}">${esc(l.licenseName ?? 'Licença')}</a>` : ''} · Android é marca da Google LLC. O SECADA não é afiliado à Google.</p>
  </div>
</footer>`;
}
