import { esc } from '../lib.mjs';

// Cabeçalho padrão das páginas internas.
export function pageHead(title, lead, extra = '') {
  return `<header class="page-head"><div class="wrap"><h1>${esc(title)}</h1>${lead ? `<p class="lead">${lead}</p>` : ''}${extra}</div></header>`;
}
