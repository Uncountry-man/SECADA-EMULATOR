import { esc, fmtDate } from '../lib.mjs';
import { pageHead } from './common.mjs';

export function novidades({ changelog }) {
  const list = (title, cls, items) => (items?.length ? `<h3 class="kind ${cls}">${title}</h3><ul class="plain-list">${items.map((i) => `<li>${esc(i)}</li>`).join('')}</ul>` : '');
  return `
${pageHead('Novidades', 'O que mudou em cada versão do SECADA.')}
<section class="section tight">
  <div class="wrap">
    <div class="log">
      ${changelog.entries.map((e) => `
      <article class="log-entry" id="v${esc(e.version)}">
        <div><div class="ver">${esc(e.version)}</div><time datetime="${esc(e.date)}">${esc(fmtDate(e.date))}</time></div>
        <div>
          <h2>${esc(e.title)}</h2>
          ${list('Novos recursos', 'add', e.added)}${list('Mudanças', 'chg', e.changed)}${list('Correções', 'fix', e.fixed)}
        </div>
      </article>`).join('')}
    </div>
  </div>
</section>
`;
}
