import { esc } from '../lib.mjs';

const inline = (s) => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');

// Lê ../THIRD_PARTY_NOTICES.md (fonte única): blocos separados por linha em branco;
// o bloco que começa com "|" é a tabela, os demais são parágrafos.
export function terceiros(md) {
  const blocks = md.split(/\n\s*\n/).map((b) => b.trim()).filter((b) => b && !b.startsWith('#'));
  const tableBlock = blocks.find((b) => b.startsWith('|')) ?? '';
  const rows = tableBlock.split('\n').map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
  const [head = [], , ...body] = rows;
  const paras = blocks.filter((b) => !b.startsWith('|')).map((b) => b.replace(/\s*\n\s*/g, ' '));
  return `
<div class="wrap" style="padding-block:clamp(40px,6vw,80px) clamp(64px,9vw,120px)">
  <article class="doc" style="max-width:980px">
    <header><h1>Componentes de terceiros</h1><p>${inline(paras[0] ?? '')}</p></header>
    <section class="notices"><div class="tbl-scroll"><table>
      <thead><tr>${head.map((h) => `<th scope="col" style="width:auto">${esc(h)}</th>`).join('')}</tr></thead>
      <tbody>${body.map((r) => `<tr><th scope="row">${inline(r[0])}</th>${r.slice(1).map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody>
    </table></div>
    ${paras.slice(1).map((p) => `<p>${inline(p)}</p>`).join('')}
    </section>
  </article>
</div>`;
}
