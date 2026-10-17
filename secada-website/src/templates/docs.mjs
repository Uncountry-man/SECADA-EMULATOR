import { esc, shell, vars } from '../lib.mjs';

const sections = [
  ['requisitos', 'Requisitos'],
  ['instalar', 'Instalação'],
  ['primeiro-uso', 'Primeiro uso'],
  ['apk', 'Instalar APK e XAPK'],
  ['configuracoes', 'Configurações'],
  ['mapeador', 'Mapeador de teclas'],
  ['arm', 'Tradução ARM'],
  ['problemas', 'Solução de problemas'],
  ['arquivos', 'Arquivos e registros'],
  ['compilar', 'Compilar do código-fonte']
];

const settings = [
  ['vCPUs', '4', 'de 1 até o número de núcleos lógicos'],
  ['RAM', '4096 MB', 'mínimo 2048 MB e no máximo o total menos 1024 MB'],
  ['Resolução', '1280×720', '480–3840 × 480–2160, largura múltipla de 8'],
  ['DPI', '240', '120–640'],
  ['Armazenamento', '32 GB', '8–1024 GB; só pode crescer'],
  ['Gráficos', 'GPU do computador (VirGL)', 'Software só como compatibilidade; a GPU é escolhida e testada sozinha'],
  ['Esc = Voltar', 'ligado', '—'],
  ['Iniciar ao abrir', 'ligado', 'Liga o Android assim que o SECADA abre'],
  ['Android enxuto', 'desligado', 'Opcional e reversível'],
  ['Tradução ARM', 'ligada', 'Baixa o libhoudini (~43 MB) na primeira vez'],
  ['Áudio', 'ligado', 'Requer PulseAudio ou PipeWire']
];

const trouble = [
  ['O SECADA avisa que não consegue usar o KVM', 'Ligue a virtualização (Intel VT-x ou AMD-V) na BIOS e confirme que o seu usuário acessa /dev/kvm: <code>sudo usermod -aG kvm $USER</code>, depois encerre a sessão e entre de novo.'],
  ['Aparece “imagem Android não encontrada”', 'A imagem não vem no pacote. Rode o script <code>fetch-android-image.sh</code> (veja Instalação) ou escolha uma ISO em Configurações → Sistema. Qualquer *.iso em <code>~/.local/share/secada/images/</code> é detectada.'],
  ['Um app é recusado na instalação', 'O Android do SECADA é o 9 (API 28): apps que exigem Android 10 ou superior não instalam. Apps só ARM de 64 bits também são recusados. Apps ARM de 32 bits exigem a Tradução ARM ligada.'],
  ['A tela fica lenta ou aparece aviso de renderização por software', 'O SECADA testa as GPUs disponíveis e cai para software quando nenhuma serve. Com NVIDIA proprietário é preciso o driver 495 ou mais novo com <code>nvidia-drm.modeset=1</code>. Em máquinas virtuais e servidores sem GPU, o modo software é esperado.'],
  ['Não consigo digitar ç ou acentos', 'O Android usa layout en-us e ainda não reflete o teclado do computador. Caracteres fora do ASCII não são digitados pelo teclado físico.'],
  ['Sem som', 'O áudio depende de PulseAudio ou PipeWire no computador e da opção Áudio ligada nas Configurações.'],
  ['A mira com o mouse não funciona nos jogos', 'A mira do Mapeador de teclas precisa de X11. Em Wayland o cursor não pode ser reposicionado e a câmera para na borda da janela.'],
  ['O Android não inicia ou trava', 'Abra os registros em <code>~/.local/share/secada/logs/</code> (<code>secada.log</code>, <code>qemu.log</code> e <code>android-serial.log</code>). Eles trazem o motivo da maioria das falhas. Reiniciar o Android pela barra lateral também ajuda.']
];

export function docs({ release, requirements }) {
  const v = (s) => vars(s, release);
  return `
<div class="wrap doc-layout">
  <aside class="toc" aria-label="Nesta página">
    <h2>Nesta página</h2>
    <div>${sections.map(([id, t]) => `<a href="#${id}">${t}</a>`).join('')}</div>
  </aside>
  <article class="doc">
    <header>
      <h1>Documentação</h1>
      <p>Como instalar, usar e resolver problemas no SECADA ${esc(release.version)}. Tudo aqui descreve o que o programa faz hoje. Veja também as <a href="../faq/">perguntas frequentes</a>, as <a href="../novidades/">novidades</a> e as <a href="../recursos/#limites">limitações</a>.</p>
    </header>

    <section id="requisitos">
      <h2>Requisitos</h2>
      <div class="tbl-scroll"><table><tbody>
        ${requirements.rows.map((r) => `<tr><th scope="row">${esc(r.label)}</th><td>${esc(r.value)}${r.status === 'a-definir' ? ' <span class="tag-warn">a definir</span>' : ''}</td></tr>`).join('')}
      </tbody></table></div>
    </section>

    <section id="instalar">
      <h2>Instalação</h2>
      <p>Antes de começar, confira os requisitos acima: o computador precisa ser x86-64 com virtualização (KVM) ativada na BIOS.</p>
      <h3>Pacote portátil (.tar.gz)</h3>
      ${shell([v('tar -xzf {{tar}}'), v('cd {{tarDir}}'), './install.sh', '# baixa a imagem do Android (921 MB) e confere o MD5', '~/.local/opt/secada/scripts/fetch-android-image.sh', 'secada'])}
      <p>O <code>install.sh</code> copia o programa para <code>~/.local/opt/secada</code>, cria <code>~/.local/bin/secada</code>, o atalho no menu (Acessórios → SECADA Emulator) e registra o SECADA para abrir .apk e .xapk. O <code>uninstall.sh</code> desfaz tudo.</p>
      <h3>Pacote Debian (.deb)</h3>
      ${shell([v('sudo apt install ./{{deb}}'), '/opt/secada/scripts/fetch-android-image.sh', 'secada'])}
      <p>O pacote depende de GTK 3, e2fsprogs, libepoxy, libgbm, libegl e libgles2. QEMU e ADB já vêm incluídos.</p>
      <h3>Acesso ao KVM</h3>
      ${shell(['sudo usermod -aG kvm $USER'])}
      <p>Depois, encerre a sessão e entre de novo. O Linux Mint já concede acesso ao usuário logado.</p>
    </section>

    <section id="primeiro-uso">
      <h2>Primeiro uso</h2>
      <ol>
        <li>Abra o SECADA. O Android <strong>inicia sozinho</strong>, com uma tela de carregamento. O primeiro boot cria o disco de 32 GB (esparso), conecta o Wi-Fi virtual e aplica idioma e fuso do computador, o que leva de 40 a 60 s. Os seguintes levam cerca de 20 a 25 s.</li>
        <li>Use o mouse e o teclado direto na tela. <strong>Esc</strong> volta e <strong>F11</strong> alterna a tela cheia.</li>
        <li>A barra lateral reúne: instalar APK, aplicativos, Voltar, Início, Recentes, girar a tela, mapeador de teclas, reiniciar o Android, ligar ou desligar, configurações e tela cheia.</li>
        <li>Fechar a janela desliga o Android com segurança. Apps e dados ficam no disco da VM, em <code>~/.local/share/secada/vms/default/data.qcow2</code>.</li>
      </ol>
    </section>

    <section id="apk">
      <h2>Instalar APK e XAPK</h2>
      <p>Há quatro caminhos, todos com fila e barra de progresso:</p>
      <ul class="dots">
        <li><strong>Dois cliques</strong> num arquivo .apk ou .xapk no gerenciador de arquivos. Se o SECADA estiver fechado, ele abre, liga o Android e instala; se estiver aberto, o arquivo vai para a instância em execução.</li>
        <li><strong>Arrastar e soltar</strong> os arquivos para a janela.</li>
        <li><strong>Botão de instalar</strong> na barra lateral, com o seletor de arquivos.</li>
        <li><strong>Terminal</strong>: <code>secada arquivo.apk outro.xapk</code>.</li>
      </ul>
      <p>Ao terminar, clique em <strong>Abrir</strong>. O botão de aplicativos, na barra lateral, lista os instalados e permite abrir e desinstalar.</p>
      <p><strong>XAPK</strong> é um ZIP com o APK base, partes e, às vezes, arquivos OBB. O SECADA instala as partes numa única sessão e copia os OBB direto para <code>/sdcard/Android/obb/</code>. Os formatos <code>.apks</code> e <code>.apkm</code> não são suportados.</p>
      <p>Se o gerenciador de arquivos oferecer outro programa, use Abrir com → SECADA Emulator → Sempre.</p>
    </section>

    <section id="configuracoes">
      <h2>Configurações</h2>
      <p>Ficam em <code>~/.config/secada/settings.json</code> e são validadas contra o hardware. As alterações valem na próxima inicialização da VM.</p>
      <div class="tbl-scroll"><table>
        <thead class="sr-only"><tr><th>Opção</th><th>Padrão</th><th>Limites</th></tr></thead>
        <tbody>${settings.map(([a, b, c]) => `<tr><th scope="row">${esc(a)}</th><td>${esc(b)}</td><td>${esc(c)}</td></tr>`).join('')}</tbody>
      </table></div>
    </section>

    <section id="mapeador">
      <h2>Mapeador de teclas</h2>
      <p>O botão do controle, na barra lateral, transforma teclado e mouse em toques. Há direcional (WASD ou setas), toque, deslizar, mira com o mouse e multitoque real, com perfis por jogo trocados conforme o app em primeiro plano.</p>
      <ul class="dots">
        <li>Os perfis incluídos são pontos de partida por gênero e por jogo; <strong>as posições ainda não foram validadas dentro de cada jogo</strong>. Ajuste com o editor visual.</li>
        <li><strong>F8</strong> pausa o mapeamento para digitar e <strong>Esc</strong> sai do modo de mira.</li>
        <li>Os seus perfis ficam em <code>~/.config/secada/keymaps/</code> e têm prioridade sobre os incluídos.</li>
        <li>A mira com o mouse exige X11.</li>
      </ul>
    </section>

    <section id="arm">
      <h2>Tradução ARM</h2>
      <p>Apps feitos só para celulares ARM de 32 bits (<code>armeabi-v7a</code>) rodam pelo libhoudini, da Intel. Ele não vem no pacote: o SECADA o baixa do espelho do Android-x86 na primeira vez (cerca de 43 MB, com SHA-256 conferido).</p>
      <p>A tradução custa desempenho e alguns apps com proteção contra emulador podem não abrir. Apps só ARM de 64 bits são recusados com aviso.</p>
    </section>

    <section id="problemas">
      <h2>Solução de problemas</h2>
      <dl class="trouble">${trouble.map(([q, a]) => `<dt>${esc(q)}</dt><dd>${a}</dd>`).join('')}</dl>
    </section>

    <section id="arquivos">
      <h2>Arquivos e registros</h2>
      <div class="tbl-scroll"><table><tbody>
        <tr><th scope="row">Configurações</th><td><code>~/.config/secada/settings.json</code></td></tr>
        <tr><th scope="row">Perfis do mapeador</th><td><code>~/.config/secada/keymaps/</code></td></tr>
        <tr><th scope="row">Imagem do Android</th><td><code>~/.local/share/secada/images/</code></td></tr>
        <tr><th scope="row">Disco do Android</th><td><code>~/.local/share/secada/vms/default/data.qcow2</code></td></tr>
        <tr><th scope="row">Registros</th><td><code>~/.local/share/secada/logs/</code></td></tr>
      </tbody></table></div>
    </section>

    <section id="compilar">
      <h2>Compilar do código-fonte</h2>
      <p>O repositório público ainda não foi configurado. Com o código em mãos, o caminho padrão é:</p>
      ${shell(['sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev qemu-system-x86 qemu-utils adb', 'cd app', 'flutter pub get', 'flutter build linux --release'])}
      <p>Para gerar os pacotes distribuíveis (.tar.gz e .deb) use <code>scripts/build-release.sh</code>; para rodar os testes, <code>flutter test</code>.</p>
    </section>
  </article>
</div>`;
}
