import { esc, icon } from '../lib.mjs';
import { pageHead } from './common.mjs';

export function faq({ faq }) {
  return `
${pageHead('Perguntas frequentes', 'Respostas curtas. Para o passo a passo, veja a <a href="../docs/">documentação</a>.')}
<section class="section tight">
  <div class="wrap narrow">
    <div class="faq">
      ${faq.items.map((i) => `<details><summary>${esc(i.q)}${icon('plus')}</summary><p>${esc(i.a)}</p></details>`).join('\n      ')}
    </div>
    <p class="aside" style="margin-top:40px">Não achou sua dúvida? Veja a <a href="../docs/#problemas">solução de problemas</a>.</p>
  </div>
</section>
`;
}
