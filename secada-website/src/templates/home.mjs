import { esc, fmtSize, fmtDate, icon, primaryAsset, acronym } from '../lib.mjs';

// Página inicial enxuta: apresentar, mostrar, baixar. O resto vive na documentação.
export function home({ site, release, features }) {
  const dl = primaryAsset(release);
  const beta = release.channel === 'beta';
  const others = release.assets.filter((a) => a !== dl);
  const homeFeatures = features.highlights;

  return `
<section class="hero" aria-labelledby="h-hero">
  <img class="hero-art" src="img/keyart-claro.webp" alt="" width="1920" height="1080" aria-hidden="true">
  <div class="wrap hero-grid">
    <div class="hero-copy">
      ${site.acronym ? `<p class="acronym"><abbr title="${esc(site.acronym)}">SECADA</abbr> = ${acronym(site.acronym)}</p>` : ''}
      <h1 id="h-hero">Android numa janela do seu Linux.</h1>
      <p class="lead">Roda o Android 9 em uma máquina virtual e mostra a tela numa janela nativa. Mouse, teclado e APK com dois cliques.</p>
      <div class="hero-actions">
        <a class="btn btn-primary" href="${dl ? dl.url : '#downloads'}"${dl ? ' download' : ''}>${icon('download')}Baixar SECADA</a>
        <a class="link-arrow" href="recursos/">Conhecer o projeto</a>
      </div>
      <p class="hero-meta">${esc(release.version)}${beta ? ' beta' : ''} · Linux x86-64${dl ? ` · ${fmtSize(dl.sizeBytes)}` : ''}</p>
    </div>
    <figure class="shot">
      <img src="img/app-android.webp" srcset="img/app-android-668.webp 668w, img/app-android.webp 1336w" sizes="(max-width: 960px) 100vw, 60vw" width="1336" height="760" alt="Janela do SECADA mostrando a tela inicial do Android 9" fetchpriority="high">
    </figure>
  </div>
</section>

<section class="section" id="recursos" aria-labelledby="h-rec">
  <div class="wrap">
    <h2 id="h-rec">Recursos</h2>
    <ul class="feature-grid">
      ${homeFeatures.map((x) => `<li>${icon(x.icon, 'feat-icon')}<h3>${esc(x.title)}</h3><p>${esc(x.text)}</p></li>`).join('\n      ')}
    </ul>
    <p class="aside">O SECADA roda Android 9, sem câmera, sensores nem Google Play. <a href="recursos/#limites">Ver limitações</a> e <a href="recursos/#planejado">o que vem a seguir</a>.</p>
  </div>
</section>

<section class="section" id="downloads" aria-labelledby="h-dl">
  <div class="wrap"><div class="dl">
    <div>
      <h2 id="h-dl">Baixar</h2>
      <p class="dl-version">Versão ${esc(release.version)}${beta ? ' <span class="badge">Beta</span>' : ''} · ${esc(fmtDate(release.date))}</p>
      <div class="notice" id="platform-warning" hidden><b>Atenção:</b> <span id="platform-msg"></span> O SECADA só funciona em Linux com processador x86-64.</div>
    </div>
    <div>
      ${dl ? `<a class="btn btn-primary btn-lg" href="${esc(dl.url)}" download>${icon('download')}Baixar para Linux <small>.${esc(dl.format)} · ${fmtSize(dl.sizeBytes)}</small></a>` : '<p class="aside">Nenhum pacote configurado ainda.</p>'}
      ${others.length ? `<p class="dl-alt">${others.map((a) => `<a href="${esc(a.url)}" download>${esc(a.label)} (.${esc(a.format)}, ${fmtSize(a.sizeBytes)})</a>`).join(' · ')}</p>` : ''}
      <p class="dl-note">Na primeira abertura, o SECADA baixa a imagem do Android (${esc(release.androidImage.size)}). Veja <a href="downloads/">todas as opções e a instalação</a>.</p>
      <details class="verify">
        <summary>Verificar integridade (SHA-256)</summary>
        <dl>
          ${release.assets.map((a) => `<dt>${esc(a.file)}</dt><dd><code>${esc(a.sha256)}</code><button class="copy" type="button" data-copy="${esc(a.sha256)}" aria-label="Copiar SHA-256 de ${esc(a.file)}">${icon('copy')}<span class="copy-label">Copiar</span></button></dd>`).join('\n          ')}
        </dl>
      </details>
    </div>
  </div></div>
</section>

<section class="section" id="apoie" aria-labelledby="h-apoie">
  <div class="wrap"><div class="dl">
    <div><h2 id="h-apoie">Apoie o projeto</h2></div>
    <div>
      <p class="lead">O SECADA é gratuito. Se ele for útil para você, uma contribuição ajuda a manter o desenvolvimento. É opcional.</p>
      <p class="dl-alt" style="margin-top:24px"><a class="btn btn-ghost" href="apoie/">Como apoiar</a></p>
    </div>
  </div></div>
</section>
`;
}
