export const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

export function fmtSize(bytes) {
  const mb = bytes / 1048576;
  return mb >= 1000 ? `${(mb / 1024).toFixed(1).replace('.', ',')} GB` : `${mb.toFixed(0)} MB`;
}

export function fmtDate(iso) {
  const [y, m, d] = iso.split('-').map(Number);
  const meses = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
  return `${d} de ${meses[m - 1]} de ${y}`;
}

export const icon = (name, cls = '') =>
  `<svg class="icon ${cls}" aria-hidden="true" focusable="false"><use href="#i-${name}"/></svg>`;

// Bloco de código com botão de copiar. `text` é o que vai para a área de transferência;
// `html` (opcional) é a versão com realce de comentários.
export function codeBlock(text, html) {
  return `<div class="code"><pre><code>${html ?? esc(text)}</code></pre>` +
    `<button class="copy" type="button" data-copy="${esc(text)}" aria-label="Copiar comandos">${icon('copy')}<span class="copy-label">Copiar</span></button></div>`;
}

// Linhas começando com # viram comentário esmaecido.
export function shell(lines) {
  const text = lines.join('\n');
  const html = lines.map((l) => (l.startsWith('#') ? `<span class="c">${esc(l)}</span>` : esc(l))).join('\n');
  const copyText = lines.filter((l) => !l.startsWith('#')).join('\n');
  return codeBlock(copyText || text, html);
}

export function primaryAsset(release) {
  return release.assets.find((a) => a.recommended) ?? release.assets[0];
}

// Preenche {{chave}} em textos de instalação.
export function vars(str, release) {
  const tar = release.assets.find((a) => a.id === 'tar');
  const deb = release.assets.find((a) => a.id === 'deb');
  return str
    .replaceAll('{{version}}', release.version)
    .replaceAll('{{tar}}', tar?.file ?? `secada-${release.version}-linux-x86_64.tar.gz`)
    .replaceAll('{{tarDir}}', `secada-${release.version}-linux-x86_64`)
    .replaceAll('{{deb}}', deb?.file ?? `secada_${release.version}_amd64.deb`);
}
