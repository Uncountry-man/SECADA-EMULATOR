# Introdução do SECADA

Abertura animada de 14 segundos, feita só com HTML, CSS, SVG e JavaScript (sem bibliotecas e sem vídeo). Usa o logotipo oficial (`app/assets/secada-logo-transparente.svg`) separado em partes, com a geometria original intacta.

## Como assistir

Sirva a pasta `secada-website/` e abra `/intro/`:

```bash
cd secada-website
python3 -m http.server 8080      # ou qualquer servidor estático
# http://localhost:8080/intro/
```

Abrir o `index.html` direto do disco (`file://`) também funciona.

Clique, `Esc`, `Enter` ou espaço pulam a introdução (saída suave de 0,45 s). Ao terminar aparece um botão discreto para assistir de novo.

## Roteiro

| Tempo | O que acontece |
| --- | --- |
| 0–2 s | Ponto central acende; régua, marcações, grade de pontos e cantoneiras inicializam a composição. |
| 2–5 s | A régua se divide em dois trilhos que delimitam o nome; planos inclinados no ângulo do símbolo deslizam e os contornos das duas metades do "S" são traçados. |
| 5–8 s | As metades recuam, avançam até o lugar e são preenchidas por máscaras inclinadas em sentidos opostos; as letras sobem por trás do trilho, uma a uma, e a barra do E desce do trilho de cima. |
| 8–11 s | Trilhos e cantoneiras se recolhem; a marca respira, uma passagem de luz recortada pelo logotipo a atravessa e um brilho suave se acende. |
| 11–14 s | Traço de acento sob a marca, composição final em repouso e saída com fade para o próximo estágio. |

## Parâmetros

- `?next=../` ao terminar (ou ao pular), segue para esse endereço. Só aceita endereços do mesmo site.
- `?t=7.5` congela o quadro desse instante, para revisar a composição.

## Integração

Ao terminar, a página dispara `secada:intro-end` em `window` (com `detail.skipped`) e, dentro de um iframe ou WebView, envia `postMessage({ type: 'secada:intro-end' })` para a janela pai. `window.SecadaIntro` expõe `play()`, `skip()`, `seek(t)` e `duration`.

Quem pede menos movimento no sistema (`prefers-reduced-motion`) vê só a composição final, com fade de entrada e saída, em 3,2 s.

## Arquivos

- `index.html` estrutura e o SVG da cena, com as partes do logotipo em `<defs>`.
- `intro.css` fundo, camadas de luz, grão e vinheta.
- `intro.js` a linha do tempo (cada elemento é função do tempo, então qualquer quadro é reproduzível), as partículas em canvas e o enquadramento responsivo.

A pasta não entra no build do site (`scripts/build.mjs` só copia `public/`). Para publicá-la no GitHub Pages, basta movê-la para `public/intro/` e trocar o caminho do favicon.
