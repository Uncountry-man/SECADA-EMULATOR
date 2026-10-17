import { esc, icon } from '../lib.mjs';
import { pageHead } from './common.mjs';

export function recursos({ features }) {
  return `
${pageHead('Recursos', 'Tudo o que está nesta lista foi implementado e testado com o aplicativo real. O que ainda não existe aparece separado, mais abaixo.')}
<section class="section tight" aria-labelledby="h-impl">
  <div class="wrap">
    <h2 id="h-impl" class="sr-only">Disponível hoje</h2>
    <ul class="feature-grid cols-2">
      ${features.implemented.map((x) => `<li>${icon(x.icon, 'feat-icon')}<h3>${esc(x.title)}</h3><p>${esc(x.text)}</p></li>`).join('\n      ')}
    </ul>
  </div>
</section>

<section class="section tight" id="limites" aria-labelledby="h-lim">
  <div class="wrap two">
    <div><h2 id="h-lim">Limitações atuais</h2><p class="aside">O que o SECADA não faz hoje.</p></div>
    <ul class="plain-list">${features.limits.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>
  </div>
</section>

<section class="section tight" id="planejado" aria-labelledby="h-plan">
  <div class="wrap two">
    <div><h2 id="h-plan">Planejado</h2><p class="aside">Ainda não disponível. Sem datas: são intenções, não promessas.</p></div>
    <ul class="plain-list">${features.planned.map((p) => `<li><strong>${esc(p.title)}.</strong> ${esc(p.text)}</li>`).join('')}</ul>
  </div>
</section>

<section class="section cta-band">
  <div class="wrap"><a class="btn btn-ghost" href="../downloads/">Ir para os downloads ${icon('arrow')}</a></div>
</section>
`;
}
