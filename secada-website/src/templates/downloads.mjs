import { esc, fmtSize, fmtDate, icon, shell, vars } from '../lib.mjs';
import { pageHead } from './common.mjs';

export function downloads({ release, requirements }) {
  const beta = release.channel === 'beta';
  const img = release.androidImage;
  const v = (s) => vars(s, release);
  const extra = `<p class="dl-version">Versão ${esc(release.version)}${beta ? ' <span class="badge">Beta</span>' : ''} · ${esc(fmtDate(release.date))}</p>
    ${beta ? `<p class="aside" style="margin-top:8px">${esc(release.channelNote)}</p>` : ''}
    <div class="notice" id="platform-warning" hidden><b>Atenção:</b> <span id="platform-msg"></span> O SECADA só funciona em Linux com processador x86-64.</div>`;
  return `
${pageHead('Downloads', 'Escolha o pacote para a sua distribuição. Os dois trazem o programa, o QEMU e o ADB.', extra)}

<section class="section tight" aria-labelledby="h-pkgs">
  <div class="wrap">
    <h2 id="h-pkgs" class="sr-only">Pacotes</h2>
    ${release.assets.length ? `<div class="lattice">${release.assets.map(pkg).join('')}</div>` : '<p class="empty-state">Nenhum pacote configurado. Rode <code>npm run sync-release</code> em secada-website/.</p>'}
  </div>
</section>

<section class="section tight" aria-labelledby="h-what">
  <div class="wrap">
    <h2 id="h-what">O que você está baixando</h2>
    <ol class="lattice steps">
      <li><span class="n">01</span><h3>O pacote do SECADA</h3><p>Cerca de 140 MB. Inclui o programa, o QEMU e o ADB: não é preciso instalar mais nada para a virtualização.</p></li>
      <li><span class="n">02</span><h3>A imagem do Android</h3><p>${esc(img.name)}, ${esc(img.size)}. Não vem no pacote: um script a baixa depois da instalação e confere o MD5.</p></li>
      <li><span class="n">03</span><h3>Abra e use</h3><p>O Android inicia sozinho. Dê dois cliques num .apk para instalar um app.</p></li>
    </ol>
  </div>
</section>

<section class="section tight" id="instalar" aria-labelledby="h-inst">
  <div class="wrap">
    <h2 id="h-inst">Instalar</h2>
    <div class="install-grid">
      <div>
        <h3>Pacote portátil (.tar.gz)</h3>
        <p>Instala em <code>~/.local/opt/secada</code>, sem root, e cria o atalho no menu de aplicativos.</p>
        ${shell([v('tar -xzf {{tar}}'), v('cd {{tarDir}} && ./install.sh'), '~/.local/opt/secada/scripts/fetch-android-image.sh', 'secada'])}
      </div>
      <div>
        <h3>Pacote Debian (.deb)</h3>
        <p>Para Debian, Ubuntu e derivados. Instala em <code>/opt/secada</code> e precisa de sudo.</p>
        ${shell([v('sudo apt install ./{{deb}}'), '/opt/secada/scripts/fetch-android-image.sh', 'secada'])}
      </div>
      <div>
        <h3>Acesso à virtualização</h3>
        <p>O usuário precisa acessar <code>/dev/kvm</code>. No Linux Mint isso já vem liberado; nos demais, adicione-se ao grupo e abra uma nova sessão.</p>
        ${shell(['sudo usermod -aG kvm $USER'])}
      </div>
      <div>
        <h3>Instalar um APK</h3>
        <p>Dê dois cliques no arquivo, arraste-o para a janela ou use o terminal. XAPK também funciona.</p>
        ${shell(['secada aplicativo.apk'])}
      </div>
    </div>
    <p class="aside" style="margin-top:28px">Passo a passo completo e solução de problemas na <a href="../docs/">documentação</a>.</p>
  </div>
</section>

<section class="section tight" id="requisitos" aria-labelledby="h-req">
  <div class="wrap">
    <h2 id="h-req">Requisitos</h2>
    <div class="tbl-scroll"><table class="req-table"><tbody>
      ${requirements.rows.map((r) => `<tr><th scope="row">${esc(r.label)}</th><td>${esc(r.value)}${r.status === 'a-definir' ? ' <span class="tag-warn">a definir</span>' : ''}</td></tr>`).join('\n      ')}
    </tbody></table></div>
  </div>
</section>

<section class="section tight" id="mais" aria-labelledby="h-more">
  <div class="wrap">
    <h2 id="h-more" class="sr-only">Mais informações</h2>
    <div class="lattice three">
      <div><h3>Versões anteriores</h3>${release.previous.length ? `<ul class="plain-list">${release.previous.map((p) => `<li><a href="${esc(p.url)}">${esc(p.version)}</a> · ${esc(p.date)}</li>`).join('')}</ul>` : '<p>Ainda não há. Esta é a primeira versão distribuível.</p>'}</div>
      <div><h3>Código-fonte</h3><p>O repositório público ainda não foi configurado. As instruções para compilar a partir do código estão na <a href="../docs/#compilar">documentação</a>.</p></div>
      <div><h3>Verificação</h3><p>Confira o SHA-256 de cada pacote com <code>sha256sum arquivo</code>. A imagem do Android é conferida pelo MD5:</p><code class="md5">${esc(img.md5)}</code></div>
    </div>
  </div>
</section>
`;
}

function pkg(a) {
  return `
      <article class="pkg-row">
        <div>
          <h3>${esc(a.label)} ${a.recommended ? '<span class="tag tag-accent">Recomendado</span>' : ''}<span class="tag">.${esc(a.format)}</span></h3>
          <p>${esc(a.audience)}</p>
        </div>
        <dl class="kv">
          <dt>Arquitetura</dt><dd>${esc(a.arch)}</dd>
          <dt>Tamanho</dt><dd>${fmtSize(a.sizeBytes)}</dd>
          <dt>SHA-256</dt><dd class="hash"><code title="${esc(a.sha256)}">${esc(a.sha256)}</code><button class="copy" type="button" data-copy="${esc(a.sha256)}" aria-label="Copiar SHA-256 de ${esc(a.file)}">${icon('copy')}<span class="copy-label">Copiar</span></button></dd>
        </dl>
        <a class="btn ${a.recommended ? 'btn-primary' : 'btn-ghost'}" href="${/^(https?:)?\/\//.test(a.url) ? esc(a.url) : '../' + esc(a.url)}" download>${icon('download')}Baixar .${esc(a.format)}</a>
      </article>`;
}
