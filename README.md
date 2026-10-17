# SECADA Emulator — emulador Android nativo para Linux

O SECADA Emulator executa um **Android real (Android-x86 9.0, AOSP, x86-64)** numa máquina
virtual **QEMU acelerada por KVM** e mostra a tela do Android dentro de uma
janela desktop nativa feita em **Flutter (Material 3)**, com mouse, teclado,
instalação de APKs e configurações persistentes.

Não é um protótipo visual: o Android roda de fato, a imagem vem do framebuffer
da VM e os eventos de entrada vão para dispositivos virtuais da VM.

---

## Arquitetura

```
┌──────────────────────────── Processo "secada" (app desktop) ─────────────────────────────┐
│                                                                                        │
│  Flutter / Dart (lib/)                         Backend nativo C++ (linux/secada_core/)   │
│  ┌──────────────────────────────┐   canal      ┌────────────────────────────────────┐  │
│  │ ui/        janela, barra de  │  dev.secada/   │ VmProcess   fork/execve do QEMU,   │  │
│  │            título, lateral,  │◄───core────► │             PR_SET_PDEATHSIG, logs │  │
│  │            display, diálogos │  (métodos +  │ RfbClient   cliente VNC/RFB 3.8    │  │
│  │ vm/        VmController      │   eventos)   │             (thread própria)       │  │
│  │            (máquina estados),│              │ SecadaDisplayTexture → textura do    │  │
│  │            QMP, disco, ISO,  │              │             Flutter (sem cópia     │  │
│  │            linha de comando  │              │             para o Dart)           │  │
│  │ android/   ADB, APK, apps    │              │ HostProbe   KVM ioctl, CPU, RAM    │  │
│  │ input/     teclado→keysym    │              │ Janela      mover/redimensionar,   │  │
│  │ settings/  config+validação  │              │             tela cheia, DnD        │  │
│  └──────────────────────────────┘              └───────────────┬────────────────────┘  │
└───────────────────────────────────────────────────────────────┼────────────────────────┘
          │ ADB (127.0.0.1:6555)        QMP (socket UNIX)        │ VNC/RFB (socket UNIX)
          ▼                              ▼                        ▼
┌──────────────────── qemu-system-x86_64 (processo "secada-vm", KVM) ─────────────────────┐
│ CPU host · VGA/virtio-gpu · usb-tablet · teclado PS/2 · virtio-net (NAT) · virtio-blk│
│ kernel+initrd do Android-x86 · ISO como CD-ROM (system.sfs) · data.qcow2 = /data     │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

Separação de responsabilidades:

| Camada | Onde | Responsabilidade |
|---|---|---|
| Interface | `app/lib/src/ui/` | Janela, barra de título própria, barra lateral, display, configurações, apps, painel de instalação |
| Gerenciamento da VM | `app/lib/src/vm/` + `linux/secada_core/vm_process.*` | Imagem, disco QCOW2, linha de comando, ciclo de vida, QMP, desligamento seguro |
| Integração Android | `app/lib/src/android/` | ADB, detecção de boot, provisionamento, instalação/abertura/remoção de apps |
| Exibição | `linux/secada_core/dbus_display.*` + `rfb_client.*` + `app/lib/src/vm/gpu.dart` | GPU do host (VirGL) com quadros direto da GPU pelo display D-Bus; VNC como reserva |
| Entrada do usuário | `linux/secada_core/dbus_display.*`/`rfb_client.*` + `app/lib/src/input/` + `ui/display_view.dart` | Mouse/teclado pelo D-Bus (ou RFB na reserva), transformação de coordenadas |

### Exibição e entrada

* **GPU obrigatória sempre que existir**: o Android renderiza com OpenGL ES
  na GPU do host (VirGL). Na inicialização, o SECADA Emulator lista os nós
  `/dev/dri/renderD*`, prefere drivers Mesa (amdgpu, i915/xe, radeon,
  nouveau, virtio-gpu…) e deixa NVIDIA proprietário por último, e testa cada
  um com uma sonda do próprio QEMU (~0,1 s). Configurações antigas em modo
  por software são migradas para GPU.
* **Display D-Bus** (`-display dbus,p2p=yes,gl=on`): cada quadro do Android
  chega como dmabuf da GPU no instante em que fica pronto. O backend C++
  importa o dmabuf num contexto EGL próprio, no mesmo nó do QEMU, lê só a
  região alterada e libera o próximo quadro: **60 quadros/s**, contra ~26 do
  caminho egl-headless + VNC (limitado pelo timer de 30 ms do VNC do QEMU).
  Nesse modo mouse e teclado vão pelas interfaces `Mouse`/`Keyboard` do
  D-Bus (keysym → scancode XT en-us).
* **Reservas automáticas**, sem intervenção: se o display D-Bus/EGL falhar
  no host, a VM é reiniciada pelo caminho egl-headless + VNC (ainda na GPU);
  se nenhuma GPU puder ser usada (sem `/dev/dri`, sem permissão, driver sem
  GBM/EGL) ou o QEMU cair ao iniciar o VirGL, usa renderização por software
  e avisa o motivo.
* O QEMU também exporta a tela pelo seu **servidor VNC embutido num socket
  UNIX** (`$XDG_RUNTIME_DIR/secada/default/vnc.sock`, diretório 0700). Nenhuma
  porta de rede é aberta.
* O cliente RFB em C++ roda numa thread própria, decodifica Raw/CopyRect,
  acompanha mudanças de resolução (DesktopSize) e alimenta uma
  `FlPixelBufferTexture`. O Dart só exibe `Texture(textureId)` com a proporção
  preservada.
* Mouse: `PointerEvent` RFB → `usb-tablet` (absoluto). Clique, arrastar,
  botão direito, roda (botões 4/5). As coordenadas são normalizadas para a área
  exibida (funciona com redimensionamento, tela cheia e rotação).
* Teclado: `KeyEvent` RFB (keysyms X11) → teclado PS/2 virtual.
  Voltar/Início/Esc usam a extensão **QEMU Extended Key Event** (scancodes
  `e0 6a`/`e0 32` → `KEY_BACK`/`KEY_HOMEPAGE`), sem passar por ADB.
* **Console root serial** (ttyS0 do Android num socket UNIX privado): canal
  de controle disponível desde o início do boot, sem depender de rede. É usado
  para detectar as fases do boot (barra de progresso), provisionar o sistema
  (Wi-Fi, idioma, fuso, bateria) e desligar/reiniciar o Android.
* ADB (pelo Wi-Fi virtual, encaminhado só para 127.0.0.1) é usado para
  instalar, listar, abrir e desinstalar apps e para Recentes.

### Ciclo de vida e processos órfãos

* O QEMU é criado com `fork/execve` + `PR_SET_PDEATHSIG(SIGTERM)` e em grupo
  de processos próprio: se o SECADA Emulator morrer (até com `SIGKILL`), o kernel encerra
  o QEMU, que grava o QCOW2 antes de sair.
* Desligamento ordenado: `reboot -p` pelo console → botão ACPI (QMP
  `system_powerdown`) → QMP `quit` → `SIGTERM` → `SIGKILL`.
* Fechar a janela (botão, gerenciador de janelas, `SIGINT/SIGTERM/SIGHUP`)
  passa por esse fluxo antes de sair. Um `pidfile` permite encerrar uma VM
  remanescente na próxima abertura.
* Um *lock* (`flock`) impede duas instâncias usando a mesma VM.

---

## Dependências

Host: Linux x86-64 (testado em **Linux Mint 22.3 / base Ubuntu 24.04**,
kernel 7.0, AMD Ryzen 7 5700U), virtualização ativada na BIOS e acesso a
`/dev/kvm`.

| Uso | Pacotes |
|---|---|
| Executar (pacote `.tar.gz`) | GTK 3, `e2fsprogs` (já presentes no Mint/Ubuntu). QEMU e ADB vêm embarcados |
| Executar (sem o pacote) | `qemu-system-x86 qemu-utils adb e2fsprogs` |
| Compilar | Flutter (stable), `clang cmake ninja-build pkg-config libgtk-3-dev` |

Acesso ao KVM: `sudo usermod -aG kvm $USER` e reabrir a sessão (o Mint já
concede acesso via ACL ao usuário logado).

---

## Como compilar

Caminho padrão (com sudo):

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev qemu-system-x86 qemu-utils adb
cd app
flutter pub get
flutter build linux --release
```

Sem root (foi assim que este projeto foi desenvolvido): o script baixa os
`.deb` oficiais com `apt-get download`, extrai num *sysroot* local e baixa o
Flutter estável com verificação SHA-256:

```bash
scripts/setup-dev-userland.sh
source ~/.local/share/secada-dev/env.sh
cd app && flutter build linux --release
```

> Observação: o servidor de análise do Dart falha com caminhos contendo
> acentos (ex.: `Área de trabalho`). Compilar funciona; para `flutter analyze`
> use um symlink sem acentos.

Pacotes distribuíveis (`dist/*.tar.gz` portátil e `dist/*.deb`):

```bash
scripts/build-release.sh
```

Testes automáticos (linha de comando QEMU, configurações, parser de APK/AXML,
ZIP/XAPK, associações de arquivo, mapeador de teclas, ISO 9660, mensagens de
erro):

```bash
cd app && flutter test
```

---

## Como executar

**Pacote portátil (recomendado):**

```bash
tar -xzf secada-0.1.0-linux-x86_64.tar.gz
cd secada-0.1.0-linux-x86_64
./install.sh                          # ~/.local/opt/secada + atalho no menu (sem root)
~/.local/opt/secada/scripts/fetch-android-image.sh   # baixa a imagem Android (921 MB)
secada                                  # ou pelo menu: Acessórios → SECADA Emulator
```

**.deb:** `sudo apt install ./secada_0.1.0_amd64.deb`, depois
`/opt/secada/scripts/fetch-android-image.sh` e `secada`.

**A partir do código:** `cd app && flutter run -d linux`. Sem QEMU no sistema,
gere o runtime: `scripts/fetch-qemu-runtime.sh` e `scripts/fetch-adb-runtime.sh`.

Uso:

1. Abra o SECADA Emulator: o Android **inicia automaticamente** com uma tela de
   carregamento (etapas e progresso). O primeiro boot cria o disco de 32 GB
   (esparso), conecta o Wi-Fi e aplica idioma/fuso do computador (~40–60 s);
   os seguintes levam ~20–25 s até ficar pronto. A opção pode ser desligada em
   Configurações → "Iniciar o Android ao abrir o SECADA Emulator".
2. Use mouse e teclado direto na tela. **Esc** = Voltar (configurável),
   **F11** = tela cheia.
3. **Instalar APK / XAPK**: **dois cliques num arquivo `.apk` ou `.xapk` no
   gerenciador de arquivos** (veja abaixo), o botão ⊞ na lateral, ou arraste
   os arquivos para a janela. Ao terminar, clique em **Abrir**. A lista de
   apps (botão ▦) permite abrir e desinstalar.
4. Fechar a janela desliga o Android com segurança; apps e dados ficam no
   disco `~/.local/share/secada/vms/default/data.qcow2`.

Barra lateral: Instalar APK/XAPK · Aplicativos · Voltar · Início · Recentes · Girar
tela · **Mapeador de teclas** · Reiniciar Android · Ligar/Desligar ·
Configurações · Tela cheia.

---

## Abrir .apk e .xapk com dois cliques

O SECADA Emulator se registra como o programa que abre `.apk` e `.xapk` em qualquer Linux
que siga o padrão freedesktop.org (Mint, Ubuntu, Fedora, Arch, KDE, GNOME…):

* **SECADA Emulator fechado**: o arquivo abre o SECADA Emulator, que liga o Android e instala assim
  que ele fica pronto (a barra de progresso aparece no canto da janela).
* **SECADA Emulator aberto**: o arquivo vai para o SECADA Emulator que já está em execução (instância
  única) e a janela vem para a frente. Vários arquivos selecionados entram na
  fila.
* Também vale `secada arquivo.apk outro.xapk` no terminal (caminhos relativos e
  URIs `file://` são aceitos).

O registro é feito de três formas, conforme a instalação:

| Instalação | Como registra |
|---|---|
| `.deb` | `secada.desktop` com `MimeType` e `Exec=… %F`, tipo MIME do XAPK em `/usr/share/mime/packages` (os gatilhos do dpkg atualizam as bases) e o SECADA Emulator como padrão do sistema em `/etc/xdg/mimeapps.list` |
| `install.sh` (portátil) | os mesmos arquivos em `~/.local/share` e o padrão em `~/.config/mimeapps.list` |
| executando de qualquer pasta | na **primeira abertura** o próprio SECADA Emulator grava `~/.local/share/applications/secada.desktop`, o tipo MIME e, **uma única vez**, o padrão em `mimeapps.list`; se você escolher outro programa depois, a escolha é respeitada |

Se o seu gerenciador de arquivos ainda oferecer outro programa, use *Abrir com →
SECADA Emulator → Sempre*. `uninstall.sh` e a remoção do `.deb` retiram o SECADA Emulator dos padrões.

**XAPK** é um ZIP com o APK base, partes (split APKs) e, às vezes, arquivos
OBB/dados. O SECADA Emulator instala todas as partes numa única sessão do PackageManager,
ignora partes de ABI que o Android não usaria (só-ARM quando há x86; só-ARM64
quando vai rodar pela tradução ARM), e copia os OBB direto do ZIP para
`/sdcard/Android/obb/<app>/` (sem extrair em disco: costumam ter gigabytes).
Aceita ZIP64 e os formatos novo (`manifest.json` com `split_apks` e
`expansions`) e antigo (APK na raiz + pasta `Android/`). Só são aceitos destinos
em `Android/obb` e `Android/data`. Outros formatos de pacote (`.apks`, `.apkm`)
não são suportados.

## Como configurar a imagem Android

O SECADA Emulator usa a ISO **Android-x86 9.0-r2 64 bits** (`android-x86_64-9.0-r2.iso`,
MD5 `e9ba997cede7bf3514d2ba3e624ff767`, publicado pelo projeto Android-x86).

* `scripts/fetch-android-image.sh` baixa (em segmentos paralelos, de
  SourceForge/archive.org) e **verifica o MD5**, gravando em
  `~/.local/share/secada/images/`.
* Qualquer `*.iso` nessa pasta é detectada automaticamente (preferindo
  `x86_64`), ou escolha o arquivo em **Configurações → Sistema**.
* Validação ao iniciar: estrutura ISO 9660, presença de `kernel`,
  `initrd.img`, `ramdisk.img`, `system.sfs` e cabeçalho bzImage com
  `XLF_KERNEL_64` (kernel x86-64).
* Kernel e initrd são extraídos (leitor ISO 9660 próprio, sem 7z/xorriso) para
  `~/.local/share/secada/vms/default/boot/`; a ISO é anexada como CD-ROM
  somente leitura.
* Parâmetros de boot: `DATA=vda` (o QCOW2 vira `/data`), `video=LxA`
  (sempre paisagem), `DPI=`, `SETUPWIZARD=0` e `console=ttyS0`.
* O disco `/data` é criado como ext4 (`mke2fs` + `debugfs`, sem root) com
  `persist.adb.tcp.port=5555` semeado, para o adbd escutar em TCP desde o
  primeiro boot. O ADB é encaminhado **apenas** para `127.0.0.1`.

Detalhes e alternativas avaliadas: [docs/DECISOES.md](docs/DECISOES.md).

---

## Configurações

Persistidas em `~/.config/secada/settings.json` (escrita atômica) e validadas
contra o hardware antes de iniciar:

| Opção | Padrão | Validação |
|---|---|---|
| vCPUs | 4 | 1 … núcleos lógicos do host |
| RAM | 4096 MB | ≥ 2048 MB e ≤ total − 1024 MB (aviso se > livre) |
| Resolução | 1280×720 | 480–3840 × 480–2160, largura múltipla de 8 |
| DPI | 240 | 120–640 |
| Armazenamento | 32 GB | 8–1024 GB; só pode crescer (`qemu-img resize` + `resize2fs` no Android) |
| Gráficos | GPU do host (VirGL) | Software (VGA ou VirtIO 2D) só como compatibilidade; a GPU é escolhida e testada automaticamente |
| Esc = Voltar | ligado | — |
| Iniciar ao abrir | ligado | — |
| Android enxuto | desligado | opcional e reversível (ver "Integração com o Android") |
| Tradução ARM | ligada | baixa o libhoudini (~43 MB) na primeira vez; ARM64 se houver `houdini9_z.sfs` |
| Áudio | ligado | requer PulseAudio/PipeWire no host |
| Avançado | automático | caminho de QEMU/ADB/ISO, porta ADB local |

Alterações valem na próxima inicialização da VM.

---

## Integração com o Android

* **Android enxuto** (opcional, **desligado de fábrica**): a imagem Android-x86 vem com Google apps,
  telemetria (`org.android_x86.analytics`), Taskbar e ~30 apps
  pré-instalados. O SECADA Emulator os remove para o usuário (`pm uninstall --user 0`;
  o sistema em si é somente leitura): **100 → 50 pacotes**, sem nenhum
  processo do Google, **+380 MB de RAM livre** no Android e menos processos.
  Fica só o necessário: framework, SystemUI, Configurações, launcher,
  instalador/permissões, provedores, teclado, WebView (passa a ser o
  provedor, já que o Chrome sai), telefonia interna, rede e seletor de
  arquivos. Cartões de sugestão das Configurações também são desativados.
  Reversível em Configurações → "Android enxuto". Lista em
  `app/lib/src/android/lean_profile.dart`. Configurações antigas migram para
  o novo padrão (campo `defaultsRev` em `settings.json`); numa VM nova o modo
  desligado não restaura nada (não há o que restaurar).
* **Launcher padrão sem pop-up**: com o modo enxuto desligado, o Taskbar (um
  segundo launcher do Android-x86) voltava e o Android passava a perguntar
  "Usar como Página inicial". O Android guarda a preferência junto com o
  conjunto de launchers; quando o conjunto muda, ela se perde. A cada boot o
  SECADA Emulator desativa o componente HOME do Taskbar e, se o seletor ainda aparecer,
  define o Launcher3 como padrão. Launchers instalados por você e escolhidos
  com "Sempre" continuam valendo.
* **Tradução ARM** (ligada de fábrica; Configurações → "Tradução ARM"): roda
  apps feitos só para celulares ARM 32 bits (`armeabi-v7a`), que antes eram
  recusados. A imagem Android-x86 9 já traz o mecanismo ("native bridge":
  `libnb.so` + serviço `nativebridge`), mas não o tradutor, que é o
  **libhoudini da Intel** (proprietário). Na primeira vez o SECADA Emulator o baixa do
  espelho oficial do Android-x86 (`houdini9_y.sfs`, ~43 MB, SHA-256 fixo,
  guardado em `~/.local/share/secada/runtime/houdini/`), envia ao Android e
  liga `persist.sys.nativebridge`; nos boots seguintes ele já sobe ativo. O
  instalador aceita APK/XAPK ARM 32 bits com a opção ligada.
* **Sem apps de câmera**, com ou sem o modo enxuto: a VM não tem câmera, então
  Camera2 e Open Camera são removidos para o usuário em todo boot.
* **Apps pré-instalados**: navegador **Firefox** (Fennec F-Droid, x86_64,
  motor Gecko próprio — o WebView 75 da imagem é antigo demais para a web
  atual) e **Fossify Notes**. Os APKs oficiais do F-Droid são baixados com
  SHA-256 fixo por `scripts/fetch-guest-apps.sh`, embarcados em
  `runtime/apps` e instalados uma vez por VM (desinstalados, não voltam).
* **Modo desenvolvedor** já ativado no primeiro boot (opções do
  desenvolvedor e depuração USB).

* **Sempre paisagem**, com a tela do Android **preenchendo toda a área** da
  janela: a barra de navegação do Android é **desativada de vez**
  (`qemu.hw.mainkeys=1` em `/data/local.prop`, lido pelo `init` antes do
  system_server; os botões ficam na lateral do SECADA Emulator), a janela se ajusta à proporção da tela ao terminar um
  redimensionamento e, maximizada/tela cheia, a imagem é ampliada para
  preencher (cortando no máximo ~4% das bordas se a proporção do monitor for
  levemente diferente).
* **Wi-Fi**: o Android enxerga uma rede Wi-Fi de verdade ("VirtWifi", do
  Android-x86, sobre a placa virtio). No primeiro boot o SECADA Emulator a conecta pela
  própria tela de Wi-Fi do Android; depois ela reconecta sozinha.
* **Bateria**: espelha a bateria do computador (nível, carregando/na tomada),
  atualizada a cada minuto. Em desktops sem bateria, aparece cheia na tomada.
* **Idioma e fuso horário** do computador aplicados no primeiro boot.
* **Áudio**: Intel HDA ligado ao PulseAudio/PipeWire do host.
* Tela sempre ligada, sem tela de bloqueio, launcher padrão definido.

## Mapeador de teclas (jogos)

Botão 🎮 na barra lateral. Transforma teclado e mouse em **toques**, como nos
emuladores de jogos:

* **Direcional (WASD/setas)**: as teclas movem um joystick virtual (diagonais
  normalizadas) e soltar tudo levanta o dedo.
* **Toque**: a tecla (ou botão do mouse) toca num ponto da tela enquanto
  estiver pressionada. **Deslizar**: a tecla arrasta de A até B.
* **Mira com o mouse**: a tecla de mira (F1) esconde o cursor e o mouse arrasta
  a região da câmera; ao chegar na borda o dedo é levantado e recomeça do
  centro, e o cursor do sistema volta ao centro da tela (X11). Nesse modo o
  botão esquerdo/direito/roda disparam os toques mapeados (atirar, luneta…).
* **Multitoque real**: andar, mirar e atirar ao mesmo tempo (10 pontos). Fora
  da mira, o mouse é um dedo (clicar, arrastar, rolar).
* **Perfis por jogo**, trocados sozinhos conforme o app em primeiro plano. Já
  vêm perfis para Free Fire, PUBG Mobile/BGMI, Call of Duty: Mobile, Standoff
  2, Mobile Legends, Wild Rift, Asphalt 9, Subway Surfers, Minecraft e GTA San Andreas (também ativo para o Backstage), e
  modelos por gênero (tiro, MOBA, corrida, plataforma, deslizar). **As
  posições são pontos de partida** (disposição típica de cada gênero), não
  foram validadas dentro de cada jogo: ajuste com o editor.
* **Editor visual**: arraste os botões sobre a tela do Android, troque a tecla
  pressionando-a no teclado, redimensione o direcional e a região da câmera;
  perfis em `~/.config/secada/keymaps/*.json`. Editar um perfil embutido cria
  uma cópia sua; o seu tem prioridade sobre o embutido para o mesmo app.
* **F8** pausa o mapeamento para digitar (o mouse continua como dedo); **Esc**
  sai do modo de mira.

Como funciona: ligar o mapeador adiciona à VM uma tela de toque
(`virtio-multitouch-pci`) por hotplug e desligar a remove. Ela só existe
enquanto o mapeador está ligado porque, com ela presente, o QEMU pode entregar
os botões do mouse a ela em vez do tablet USB; por isso, nesse período todo o
ponteiro do SECADA Emulator vira toque. Os toques são injetados por QMP
(`input-send-event` com eventos `mtt`), que funciona igual com o display D-Bus
e com o VNC de reserva. Detalhes técnicos em `docs/DECISOES.md`.

## Trava do ponteiro (jogos com a câmera no mouse)

Alguns jogos do Android prendem o mouse (`View.requestPointerCapture`) para girar a câmera só movendo o mouse, sem apertar nada.
Com o tablet USB (posição absoluta) o cursor do computador saía da janela e a câmera parava na borda. Agora, quando o app pede a
trava, o SECADA Emulator:

* prende o cursor do computador no centro da área do Android (o cursor é reposto no centro quando sai da faixa central; X11) e
  envia o movimento como **deslocamento relativo** ao mouse PS/2 da VM (`input-send-event` com eventos `rel`); botões e roda seguem
  pelo tablet como sempre;
* solta tudo sozinho quando o app solta a trava (o jogo solta ao abrir um menu, ao segurar Alt ou apertar F1), quando a janela
  perde o foco, ou com **Ctrl+Alt+G** (liga/desliga a trava à mão).

Como o SECADA Emulator sabe: o app escreve no logcat, com a etiqueta `SecadaPointerLock`, `lock <n>` **a cada segundo**
enquanto estiver com o mouse preso (`Log.i("SecadaPointerLock", "lock 17")`, com `n` diferente a cada linha) e `unlock` ao soltar.
Se o `lock` parar de chegar por 3,5 s (app fechado, travado, Android reiniciado) o cursor é solto sozinho. O número é necessário: o
`logd` do Android suprime linhas idênticas repetidas ("chatty: identical N lines") e um `lock` sempre igual sumia depois das
primeiras repetições. Qualquer app pode usar o mesmo protocolo. Em Wayland o cursor não pode ser reposicionado: sem a trava, volta ao
ponteiro absoluto. Não depende do mapeador de teclas (que continua servindo para jogos sem suporte a mouse).

## Funcionalidades testadas

Testadas na prática neste ambiente (Mint 22.3, Ryzen 7 5700U, 16 GB), com o
app real dirigido por eventos X reais (xdotool/XTEST) e verificação pelo ADB
e por capturas de tela:

- [x] Detecção de KVM (ioctl `KVM_GET_API_VERSION`), CPU e memória
- [x] Localização/validação da ISO; extração de kernel/initrd
- [x] Criação do disco QCOW2 (32 GB esparso, ~7 MB reais) e boot via QEMU/KVM
- [x] Boot verificado por `sys.boot_completed=1` via ADB (1º boot ~30 s, depois ~18 s)
- [x] Tela real do Android na janela, proporção mantida, redimensionar, maximizar, tela cheia (F11)
- [x] Clique, arrastar (swipe abre a gaveta), roda do mouse (rolagem), diálogos
- [x] Digitação com maiúsculas, símbolos, Backspace, Ctrl+A
- [x] Voltar, Início, Recentes, Esc = Voltar
- [x] Início automático ao abrir, com tela de progresso (abrir → pronto em ~24 s)
- [x] Wi-Fi reconhecido pelo Android (VirtWifi conectado, reconecta após reboot)
- [x] Bateria espelhando o host; idioma pt-BR e fuso America/Bahia aplicados
- [x] Placa de som HDA reconhecida pelo Android
- [x] Tela preenchendo o container (janela, após redimensionar, maximizada e tela cheia)
- [x] Rotação rápida (janela vira retrato, mapeamento de toque correto)
- [x] Instalação por seletor de arquivos e por arrastar-e-soltar (do Nemo), com progresso real
- [x] Duplo clique (`gio open`) em `.apk`/`.xapk` com o SECADA Emulator aberto (arquivo entregue à instância em execução, caminho com espaços) e **com o SECADA Emulator fechado e a VM desligada** (abre, liga o Android e instala); caminho relativo e URI `file://` pela linha de comando
- [x] XAPK real com APK base + OBB de 6 MB: SHA-256 do OBB no Android idêntico ao original; sessão com várias partes validada com `adb` de mentira (o Android real só recebeu 1 parte, por falta de um XAPK com splits)
- [x] `install.sh`/`uninstall.sh` em HOME isolado: `xdg-mime` devolve o SECADA Emulator como padrão para os dois tipos e reconhece `*.xapk`
- [x] **Tradução ARM**: numa VM nova o SECADA Emulator baixou o libhoudini (SHA-256 conferido), ativou-o e o `Backstage.apk` (1,6 GB, só ARM: `armeabi-v7a` + `arm64-v8a`) instalou por duplo clique e abriu (`houdini 9.0.1b_y ... successfully`); após reiniciar, a tradução continua ativa sem novo download
- [x] Rejeição clara de APK só-ARM64, de ARM com a tradução desligada e de `minSdk` > 28
- [x] Abrir app instalado (Open Camera; VLC x86_64 com código nativo); listar e desinstalar
- [x] Persistência: apps instalados sobrevivem ao desligamento da VM e ao reinício do SECADA Emulator
- [x] Reiniciar Android (detecção via evento QMP `RESET`)
- [x] Desligamento pelo console em ~1 s; fallback ACPI → QMP quando o console não responde
- [x] Desligamento seguro ao fechar e com `SIGTERM`; `SIGKILL` no app não deixa QEMU órfão
- [x] Internet no Android (NAT do QEMU)
- [x] GPU (VirGL, GLES 3.1) com display D-Bus: 60 quadros/s entregues, 0% de quadros atrasados na rolagem (software: 97% atrasados, ~22 qps)
- [x] Mapeador de teclas: direcional + toque simultâneos (`P: 2/2` no overlay de ponteiros do Android), mira com o mouse, mouse como dedo, F8, editor visual, perfis salvos e reabertos; funciona com GPU (vinculado à placa de vídeo) e em software; ao desligar ou reiniciar o Android o dispositivo de toque some e o mouse volta ao normal
- [x] Launcher: sem o seletor "Usar como Página inicial" mesmo quando o Taskbar volta (reproduzido e corrigido)
- [x] Cores idênticas ao `screencap` do Android (diferença 0,00 por pixel) em GPU, reserva VNC e software
- [x] Reservas: falha do D-Bus → egl-headless + VNC; sem acesso à GPU → software com aviso
- [x] Configurações: validação e persistência
- [x] Android enxuto: remoção, restauração e reaplicação automática testadas; WebView standalone ativo
- [x] 86 testes automáticos (`flutter test`)

## Limitações atuais

- **Android 9 (API 28)**: apps que exigem Android 10+ não instalam (mensagem clara).
- **XAPK com várias partes**: testado no Android com um APK base + OBB; a sessão
  com várias partes foi validada só com um `adb` de mentira (não havia um XAPK
  com splits à mão). `.apks` e `.apkm` não são suportados.
- **Tradução ARM 64 bits só com o tradutor no computador**: apps com
  `armeabi-v7a` rodam pelo libhoudini de 32 bits, baixado automaticamente.
  ARM64 exige o `houdini9_z.sfs` em `~/.local/share/secada/runtime/houdini/`,
  que o Android-x86 nunca publicou e o SECADA Emulator não baixa; com ele, o SECADA Emulator
  anuncia `arm64-v8a` ao Android e o ativa sozinho (ver `docs/DECISOES.md`).
  Sem ele, apps que trazem as duas versões rodam a de 32 bits, que pode se
  comportar diferente do celular (é o caso do jogo do Backstage), e apps só
  ARM64 são recusados com aviso. Traduzir ARM custa desempenho e alguns apps
  com proteção anti-emulador podem não abrir.
- **Rotação**: o Android sempre inicia em paisagem. O botão Girar troca a
  geometria lógica (`wm size`), então em retrato a imagem usa uma área menor do
  framebuffer (menos nítida). Apps que forçam orientação não giram a janela
  sozinhos.
- **Wi-Fi virtual**: a rede é a NAT do QEMU (sem ICMP/ping); o ícone mostra
  sinal cheio sempre.
- O cartão "Concluir a configuração do seu dispositivo" nas Configurações do
  Android pode ser dispensado no X (resquício do assistente pulado).
- **NVIDIA proprietário** precisa de GBM (driver 495+ com
  `nvidia-drm.modeset=1`); sem isso o SECADA Emulator cai para software. Hosts sem GPU
  (VMs, servidores) rodam por software.
- **Teclado**: layout en-us no convidado; caracteres fora do ASCII (ç, acentos)
  não são digitados pelo teclado físico.
- Sem câmera, sensores ou GPS.
- **Mapeador**: a mira com o mouse precisa de X11 (em Wayland o cursor não
  pode ser reposicionado e a câmera para na borda da janela); jogos que leem
  sensores (giroscópio) não são cobertos.
- Uma única VM (`default`); sem multi-instância.
- Ponteiro: o Android desenha o próprio cursor (o do host fica oculto sobre a tela).
- Sem Google Play/Play Services no modo enxuto (na imagem eles nem funcionam
  sem atualização). Apps que exigem Play Services não rodam.
- A barra "Pesquisar" do Launcher3 é embutida no launcher e fica inerte sem o
  app Google (não dá para removê-la sem trocar de launcher).

## Próximos passos

1. Mapeamento por scancodes (Extended Key Event) para todos os teclados, com
   layout do host refletido no Android (ç, acentos).
2. Área de transferência compartilhada e microfone.
3. Importar o dmabuf direto na textura do Flutter (sem a leitura pela CPU) e
   Venus/Vulkan; avaliar BlissOS/Android 11–13.
4. Fonte distribuível para o tradutor ARM64 (o SECADA Emulator já o ativa quando o
   `houdini9_z.sfs` existe).
5. Multi-instância, snapshots QCOW2, mapeamento de teclas para jogos.
6. Rotação real acompanhando a orientação pedida pelo app.

---

## Estrutura do repositório

```
app/                      aplicativo Flutter
  lib/main.dart
  lib/src/{core,host,settings,vm,android,keymap,input,ui}/
  linux/secada_core/        backend C++ (VM, RFB, textura, KVM, janela, DnD)
  linux/runner/           executável GTK (janela sem decoração)
  test/                   testes unitários
  assets/secada*.png        ícone
scripts/
  setup-dev-userland.sh   toolchain sem root
  fetch-qemu-runtime.sh   QEMU relocável (sem root)
  fetch-adb-runtime.sh    ADB relocável (sem root)
  fetch-android-image.sh  ISO Android-x86 com verificação de MD5
  build-release.sh        build release + .tar.gz + .deb
packaging/                tipo MIME do XAPK e utilitário do mimeapps.list (.deb / install.sh)
docs/DECISOES.md          decisões técnicas e alternativas
THIRD_PARTY_NOTICES.md    licenças de terceiros
```

Arquivos em tempo de execução: configurações em `~/.config/secada/`, dados em
`~/.local/share/secada/` (`images/`, `vms/default/`, `logs/secada.log`,
`logs/qemu.log`, `logs/android-serial.log`), sockets em
`$XDG_RUNTIME_DIR/secada/default/`.
