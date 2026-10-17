import { esc, icon } from '../lib.mjs';
import { pageHead } from './common.mjs';

const uses = [
  ['Desenvolvimento e manutenção', 'Tempo para evoluir o programa e acompanhar as versões do QEMU, do Flutter e das distribuições.'],
  ['Correção de bugs', 'Investigar e resolver o que os usuários encontram.'],
  ['Testes de compatibilidade', 'Verificar apps, jogos e distribuições além do ambiente em que o SECADA foi testado.'],
  ['Infraestrutura e distribuição', 'Hospedar os pacotes e o site.'],
  ['Melhorias futuras', 'Os itens da lista de recursos planejados.']
];

export function apoie({ site }) {
  const methods = site.donate.methods ?? [];
  const method = (m) => m.type === 'link'
    ? `<li><span><b>${esc(m.label)}</b></span><a class="btn btn-primary btn-sm" href="${esc(m.url)}" rel="noopener">${icon('external')}Apoiar por ${esc(m.label)}</a></li>`
    : `<li><span><b>${esc(m.label)}</b>${m.holder ? ` <span class="tag">${esc(m.holder)}</span>` : ''}</span><span class="hash"><code title="${esc(m.key)}">${esc(m.key)}</code><button class="copy" type="button" data-copy="${esc(m.key)}" aria-label="Copiar chave ${esc(m.label)}">${icon('copy')}<span class="copy-label">Copiar</span></button></span></li>`;
  return `
${pageHead('Apoie o projeto', 'O SECADA é gratuito. Contribuições voluntárias ajudam a mantê-lo e a melhorá-lo.')}

<section class="section tight" aria-labelledby="h-free">
  <div class="wrap two">
    <div><h2 id="h-free">É opcional</h2></div>
    <p class="body-lg">Todos os recursos podem ser usados sem contribuir, e nada deixa de funcionar por falta de doação. Se o SECADA for útil para você e quiser ajudar, estas são as formas.</p>
  </div>
</section>

<section class="section tight" aria-labelledby="h-how">
  <div class="wrap two">
    <div><h2 id="h-how">Como contribuir</h2></div>
    <div>
      ${methods.length
        ? `<ul class="method-list">${methods.map(method).join('')}</ul>`
        : '<p class="empty-state">Os meios de contribuição ainda não foram definidos. Quando existirem (Pix, GitHub Sponsors, Open Collective ou outros), aparecem aqui.</p>'}
      <!-- Mantenedor: preencher donate.methods em src/data/site.json -->
    </div>
  </div>
</section>

<section class="section tight" aria-labelledby="h-uses">
  <div class="wrap two">
    <div><h2 id="h-uses">Para onde vai</h2><p class="aside">O que as contribuições sustentam.</p></div>
    <ul class="lattice uses-lattice">${uses.map(([t, d]) => `<li><h3>${esc(t)}</h3><p>${esc(d)}</p></li>`).join('')}</ul>
  </div>
</section>

<section class="section tight" aria-labelledby="h-other">
  <div class="wrap two">
    <div><h2 id="h-other">Outras formas de ajudar</h2></div>
    <ul class="plain-list">
      <li>Reportar bugs com os registros de <code>~/.local/share/secada/logs/</code> anexados.</li>
      <li>Testar apps e jogos e contar o que funcionou.</li>
      <li>Divulgar o projeto para quem usa Android no Linux.</li>
    </ul>
  </div>
</section>
`;
}
