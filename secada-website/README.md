# secada-website

Site oficial de download do SECADA Emulator. É um site **estático e sem dependências**: HTML, CSS e um pouco de JavaScript gerados por scripts Node.js (18 ou mais novo). Não há `npm install`, bundler nem framework, e nada aqui toca o código do emulador (`app/`, `scripts/`, `packaging/`).

Por que assim: o conteúdo é uma página de produto com três páginas e dados que mudam pouco. Um gerador de 100 linhas é mais fácil de manter e hospedar do que um framework, e o resultado carrega rápido (sem JS obrigatório, fontes e imagens locais).

## Estrutura

```
secada-website/
  src/
    data/               <- tudo que muda com frequência (edite aqui)
      site.json           links oficiais, doações, e-mail de contato
      release.json        versão, data, pacotes (gerado em parte por sync-release)
      features.json       recursos implementados, planejados e limitações
      requirements.json   requisitos de sistema
      changelog.json      histórico de versões
      faq.json            perguntas frequentes
    templates/          uma função por página (home, recursos, downloads, docs, apoie, novidades, faq, privacidade, terceiros) + layout
    lib.mjs             utilitários (formatação, blocos de código)
    site.css            estilos (tokens no topo)
    fonts.css           @font-face das fontes locais
    site.js             menu móvel, copiar, aviso de plataforma, link ativo
  public/               copiado como está para dist/
    img/ fonts/ downloads/
  scripts/
    build.mjs           gera dist/
    serve.mjs           servidor local com regeração automática
    sync-release.mjs    copia os pacotes de ../dist e preenche release.json
    check.mjs           verifica links, âncoras, <h1> e alt das imagens
  dist/                 saída (não versionada)
```

Páginas geradas: `/` (início enxuta: apresentar, mostrar, baixar), `/recursos/`, `/downloads/` (pacotes, SHA-256, instalação, requisitos), `/docs/` (uso e solução de problemas), `/apoie/`, `/novidades/` (changelog), `/faq/`, `/privacidade/` e `/terceiros/` (lida de `../THIRD_PARTY_NOTICES.md`), mais `404.html`. Itens não configurados (repositório, canal de bugs, Discord, licença) simplesmente não aparecem no rodapé até serem preenchidos.

## Rodar localmente

Não há dependências para instalar. Basta ter Node 18+.

```bash
cd secada-website
npm run dev
```

Abre em http://localhost:4321 e regera o site quando algo em `src/` ou `public/` muda (recarregue a aba). `PORT=8080 npm run dev` troca a porta.

## Gerar a versão de produção

```bash
npm run build
npm run check      # opcional: valida links e âncoras
```

O resultado fica em `dist/`, pronto para publicar. `npm run preview` serve o `dist/` já gerado, sem regerar.

## Atualizar a versão do SECADA

1. No projeto principal, gere os pacotes: `scripts/build-release.sh` (grava em `../dist/`). A versão vem de `app/pubspec.yaml`.
2. Aqui, rode:

   ```bash
   npm run sync-release
   ```

   Isso copia `secada-<versão>-linux-x86_64.tar.gz` e `secada_<versão>_amd64.deb` para `public/downloads/` e atualiza em `src/data/release.json` a versão, o tamanho e o **SHA-256** reais de cada arquivo. Os botões de download passam a apontar para eles.
3. Edite `src/data/changelog.json` e acrescente a nova entrada no topo (versão, data, `added`, `changed`, `fixed`).
4. Se a versão anterior continua disponível, mova-a para `previous` em `release.json`: `{ "version": "0.1.0", "date": "2026-10-15", "url": "https://..." }`.
5. `npm run build`.

Outros campos de `release.json` editados à mão: `channel` (`"beta"` mostra o selo e o aviso; use `"stable"` para remover), `channelNote` e `androidImage` (nome, tamanho e MD5 da ISO do Android).

### Hospedar os pacotes fora do site

Os pacotes têm cerca de 270 MB juntos. Em hospedagens com limite de tamanho, publique-os num lugar próprio (por exemplo, a página de releases do repositório) e rode:

```bash
npm run sync-release -- --no-copy --base https://exemplo.com/releases/v0.1.0/
```

Os links passam a ser `https://exemplo.com/releases/v0.1.0/<arquivo>`; o tamanho e o SHA-256 continuam calculados a partir de `../dist`.

## Configurar links oficiais e doações

Tudo em `src/data/site.json`. **Campos `null` aparecem no site como "ainda não configurado"; nada é inventado.**

| Campo | O que faz |
|---|---|
| `siteUrl` | URL pública do site. Habilita `canonical`, `og:url`, `sitemap.xml` e URLs absolutas no JSON-LD. |
| `links.repository` | Rodapé: "Repositório oficial". |
| `links.issues` | Rodapé: "Reportar um bug". |
| `links.discord` | Rodapé: "Comunidade no Discord". |
| `links.contactEmail` | Rodapé: "Contato". |
| `links.license` e `links.licenseName` | Rodapé: licença do código (hoje "ainda não definida"). |
| `donate.methods` | Lista de meios de contribuição, abaixo. |

Cada item de `donate.methods` aceita dois formatos:

```json
{ "id": "pix", "label": "Pix", "type": "pix", "key": "SUA-CHAVE-PIX", "holder": "Nome do recebedor" }
{ "id": "github", "label": "GitHub Sponsors", "type": "link", "url": "https://github.com/sponsors/usuario" }
```

Itens `link` viram um botão "Abrir"; itens `pix` mostram a chave com botão de copiar. Sem nenhum item, a seção mostra apenas "Em breve.".

Outros arquivos de dados:

- `features.json`: `highlights` são os seis itens curtos da página inicial; `implemented` (com o campo `evidence`, que aponta onde o repositório comprova a funcionalidade), `limits` e `planned` aparecem na documentação. Só mova um item de `planned` para `implemented` depois de testá-lo.
- `requirements.json`: `status` pode ser `testado`, `definido` ou `a-definir`. Itens `a-definir` aparecem na documentação com a marca "a definir".
- `faq.json` e `changelog.json`: listas simples.

## Publicar

`dist/` é um site estático; qualquer hospedagem de arquivos serve (GitHub Pages, Cloudflare Pages, Netlify, nginx).

- **Servidor próprio (nginx):** copie `dist/` para a raiz do site. `404.html` já está incluído (`error_page 404 /404.html;`).
- **GitHub Pages / Cloudflare Pages / Netlify:** comando de build `node scripts/build.mjs` dentro de `secada-website/`, diretório de saída `dist`. Como `public/downloads/` não é versionado, hospede os pacotes à parte e use `sync-release -- --no-copy --base ...` (veja acima).
- Os caminhos dos arquivos são relativos, então o site também funciona numa subpasta.
- Cabeçalhos recomendados: `Cache-Control: public, max-age=31536000, immutable` para `/fonts/` e `/img/`, e `max-age` curto para o HTML.

## Decisões de conteúdo

- Todas as afirmações vêm do `README.md`, de `docs/DECISOES.md` e de `scripts/` do projeto. O que não está confirmado (licença, repositório, canal de bugs, Pix, requisito mínimo de RAM do computador) aparece como pendente.
- A página inicial não traz números de desempenho; as medições registradas no README (60 quadros/s, ≈ 24 s de inicialização, num Ryzen 7 5700U) ficam na documentação do projeto.
- As capturas de tela em `public/img/` são do aplicativo real, tiradas do SECADA 0.1.0 em execução. Para atualizá-las, substitua `app-android.webp`, e `app-android-668.webp`.
- O logo vem de `../app/assets/` (versão SVG sem fundo, em branco). `secada-logo-cinza.svg` é a versão para fundos claros.
- Fontes (Sora, IBM Plex Sans e IBM Plex Mono, licença OFL) estão em `public/fonts/`, sem chamadas a serviços externos.
- A única lógica no navegador é opcional: se o visitante não estiver em Linux x86-64, um aviso aparece na seção de download.
