# Decisões técnicas

## Sistema convidado: Android-x86 9.0-r2 (x86_64)

Avaliadas:

| Opção | Resultado |
|---|---|
| **Android-x86 9.0-r2** | Escolhida. AOSP, x86-64, boot comprovado em QEMU puro com VGA padrão, virtio-gpu e VirGL; ISO de 921 MB com MD5 oficial; adbd sem autenticação (build userdebug). Mesmo Android 9 usado pelo LDPlayer 9. |
| Imagens do Android Emulator (goldfish/ranchu) | Dependem de dispositivos goldfish do QEMU forkado do Google; não sobem em QEMU upstream sem patches. |
| Cuttlefish | Requer crosvm/infra própria; fora do escopo de um app desktop simples. |
| BlissOS 14–16 (Android 11–13) | Viável e mais novo, porém ISO 2–3× maior e relatos de tela preta sem VirGL; candidato para evolução. |
| Waydroid/Anbox | Proibidos pelo escopo (não são VM). |

Problemas encontrados no Android-x86 e soluções:

1. **Rede**: o `init.sh` renomeia `eth0` para `wifi_eth` e cria um
   `virt_wifi` (`wlan0`) que só ganha IP depois de o Android se conectar à
   rede "VirtWifi". A primeira versão usava `VIRT_WIFI=0` (Ethernet direta),
   mas aí os apps não viam Wi-Fi. Solução atual: manter o virt_wifi e, no
   primeiro boot, conectar a VirtWifi **pela própria tela de Wi-Fi do
   Android** (`uiautomator dump` + toque), via console root serial — o canal
   que funciona antes de haver rede. Tentativas de semear o
   `WifiConfigStore.xml` foram descartadas: o Android 9 o rejeitava em
   silêncio e travava o carregamento das redes salvas.
2. **adbd só USB**: o adbd do Android 9 lê `persist.adb.tcp.port`. O SECADA Emulator
   cria o `/data` (ext4) já com `/data/property/persist.adb.tcp.port=5555`
   (formato legado, root:root 0600 via `debugfs`), importado no primeiro boot
   antes de o adbd iniciar.
3. **Botão de energia ACPI** só apaga a tela → desligamento via `reboot -p`.
4. **`user_rotation` ignorado** → rotação rápida por `wm size`; boot sempre
   em paisagem.
6. **Bateria ausente** ("!") → `dumpsys battery set` espelhando o host.
7. **Barra de navegação** ocupava 72 px à direita. O modo imersivo
   (`policy_control immersive.navigation=*`) só a escondia: um deslize na
   borda a trazia de volta. Solução definitiva: `qemu.hw.mainkeys=1`, que faz
   o WindowManager tratar o aparelho como tendo teclas físicas e nem criar a
   barra. Como a propriedade precisa existir antes do system_server e o
   `/system` é somente leitura, ela vai em `/data/local.prop` (o `init` do
   build userdebug do Android-x86 o carrega no post-fs-data), semeado com
   `debugfs` ao criar o disco e garantido a cada boot.
8. **Relógio**: com `-rtc base=localtime` o Android exibia a hora com o fuso
   aplicado em dobro até sincronizar pela rede; com `base=utc` a hora sai certa
   já no boot.
9. **Idioma/fuso** → `persist.sys.locale`/`persist.sys.timezone` no primeiro
   boot, seguido de um reinício.
5. **Cursor absoluto normalizado**: o *Cursor Input Mapper* do Android-x86
   escala o tablet para a geometria **lógica**; por isso o ponteiro é enviado
   como fração da área exibida.

## Exibição: GPU (VirGL) + display D-Bus do QEMU; VNC como reserva

| Opção | Avaliação |
|---|---|
| **Display D-Bus ponto a ponto (`-display dbus,p2p=yes,gl=on`)** | Escolhida para o modo GPU. O QEMU entrega cada quadro como dmabuf (`ScanoutDMABUF`/`UpdateDMABUF`) assim que o convidado termina e espera a resposta antes do próximo. O SECADA Emulator importa o dmabuf num contexto EGL próprio (GBM no mesmo nó do QEMU; alternativa: `EGL_EXT_platform_device`), lê só a região alterada com `glReadPixels` e responde. Medido: 60 quadros/s e 0% de quadros atrasados na rolagem. |
| VNC com `egl-headless` | Reserva. O VNC do QEMU 8.2 envia no máximo a cada 30 ms (~26 quadros/s medidos) e a cópia síncrona fazia 61% dos quadros do Android atrasarem. |
| VNC com VGA/VirtIO 2D (software) | Último recurso: o Android desenha na CPU (mediana de 44 ms por quadro, 97% atrasados). |
| SPICE | Exigiria libspice-client-glib e integração GTK dentro do Flutter. |
| Janela GTK/SDL do QEMU | Janela externa — proibido pelo escopo. |

Detalhes que custaram depuração:

* **Conexão p2p**: um socketpair é entregue ao QEMU por um segundo QMP
  (`getfd` com `SCM_RIGHTS` + `add_client protocol=@dbus-display`); depois
  outro socketpair vira o Listener em `RegisterListener`. A conexão do
  Listener é criada com `DELAY_MESSAGE_PROCESSING` para registrar o objeto
  antes de o QEMU chamar os métodos.
* **Entrada**: com o display D-Bus ativo, o VNC do QEMU para de injetar
  eventos (nenhum evento chega ao convidado); mouse e teclado vão pelas
  interfaces `org.qemu.Display1.Mouse`/`Keyboard` (scancodes XT).
* **Orientação**: no QEMU, `y0_top=false` significa linha 0 da memória no
  topo (o gtk-egl dele inverte quando `!y0_top`).
* **Buffers**: o Android alterna 2–3 buffers e cada quadro chega com um novo
  descritor; as EGLImages ficam em cache pelo inode do dmabuf.
* **Cores**: nos modos por software o Android-x86 desenha BGR num
  framebuffer XRGB e o QEMU entrega R/B trocados (o cliente RFB compensa); no
  VirGL (gralloc gbm) as cores já chegam certas. A versão anterior aplicava a
  troca só no VirGL — exatamente ao contrário. Validado comparando com o
  `screencap` do Android (diferença 0,00 por pixel).
* **Escolha da GPU**: nós `/dev/dri/renderD*`, drivers Mesa primeiro, NVIDIA
  por último, vgem ignorado; cada nó passa por uma sonda do QEMU (placa
  `virtio-vga-gl` + display D-Bus, sem convidado, ~0,1 s). Falhas viram aviso
  e caem para a próxima opção, nunca para tela preta.

O quadro vai direto para uma `FlPixelBufferTexture` (C++), sem passar pelo
isolate Dart.

## Launcher padrão

Com o perfil enxuto desligado existem dois launchers (Launcher3 e o HOME do
Taskbar do Android-x86). `cmd package set-home-activity` grava a preferência
junto com o *conjunto* de atividades HOME; se o conjunto muda depois (o
Taskbar volta por `install-existing`), a preferência é descartada e
`resolve-activity` passa a devolver `ResolverActivity` — o pop-up "Usar como
Página inicial". Reproduzido removendo e restaurando o Taskbar. Solução: a
cada boot, desativar o componente HOME do Taskbar (só o console root consegue;
o `pm disable <componente>` do shell do ADB é recusado com
`SecurityException`) e redefinir o Launcher3 apenas se o seletor ainda
aparecer, para não atropelar um launcher que o usuário tenha escolhido.

## Mapeador de teclas

Requisito: andar e atirar ao mesmo tempo, o que o `usb-tablet` (um ponteiro
só) não permite. Opções avaliadas:

| Opção | Resultado |
|---|---|
| **`virtio-multitouch-pci` + `input-send-event` (QMP)** | Escolhida. O kernel 4.19 do Android-x86 carrega o `virtio_input` sob demanda, o Android classifica o dispositivo como `touchScreen` multitoque (10 pontos) e o overlay "Localização do ponteiro" confirma `P: 2/2`. |
| App Android com serviço de acessibilidade | Exigiria compilar APK (sem SDK no ambiente) e `dispatchGesture` tem multitoque contínuo limitado no API 28. |
| `input swipe`/`sendevent` via ADB | Um dedo por comando e latência de processo por evento. |
| Só o `usb-tablet` | Um ponteiro; mouse e direcional brigariam. |

Armadilhas que custaram depuração:

* **`BTN_TOUCH`**: o dispositivo declara `BTN_TOUCH`; sem o botão `touch`
  pressionado o Android recebe `isHovering=true` e ignora o toque (aparecia em
  `dumpsys input` com a posição certa). O lote do primeiro `begin` inclui o
  botão e o do último `end` o solta.
* **`end` exige `tracking-id = -1`** no QEMU 8.2 (o handler repassa o valor);
  `axis`/`value` são obrigatórios até nos eventos `begin`/`end` do QAPI.
* **Filtro do kernel**: valores iguais ao último do mesmo slot não geram
  evento; ao capturar com `dd` parece perda, mas o Android guarda a posição.
* **Roteamento de botões**: `qemu_input_find_handler` entrega `btn` ao
  primeiro manipulador com a máscara BTN, e o dispositivo recém-ativado vai
  para a frente da lista, *roubando os cliques do tablet USB* enquanto
  existir (e a ordem muda a cada reinício do convidado, pois o USB só se
  reativa uma vez). Por isso o dispositivo só existe com o mapeador ligado
  (`device_add`/`device_del`), nesse período o ponteiro inteiro vira toque, e
  ele é vinculado à placa de vídeo (`display=vga0` + `device=vga0` nos
  eventos) para o roteamento não depender da ordem. No modo VGA padrão
  (`-vga std`, sem id) usa a ordem de ativação, que logo após o hotplug é a
  correta — testado.
* `getevent` perde a saída quando terminado por `timeout` (buffer em pipe):
  para inspecionar o dispositivo, `dd if=/dev/input/eventN bs=24 count=N | od`.
* O subconjunto da fonte de ícones do Flutter (`build/flutter_assets`) pode
  ficar preso na versão anterior em builds incrementais e os ícones novos
  somem; o `build-release.sh` apaga a pasta antes de compilar.

Mira: o Flutter só recebe posições absolutas; no modo de mira o deslocamento
vem da diferença entre eventos e o cursor do sistema é reposto no centro
(`gdk_device_warp`, X11) ao chegar perto da borda, descartando os eventos até
chegar o do próprio salto. O dedo da câmera é levantado 110 ms após o mouse
parar e recomeça do centro da região (o jogo só vê deslocamentos).

## Abrir APK/XAPK pelo gerenciador de arquivos

* **Instância única**: o runner GTK usava `G_APPLICATION_NON_UNIQUE`; agora é
  `G_APPLICATION_HANDLES_COMMAND_LINE`. O segundo processo (iniciado pelo
  gerenciador de arquivos) entrega a linha de comando à instância principal
  pelo D-Bus de sessão e termina; a principal resolve caminhos relativos
  (`g_application_command_line_get_cwd`), aceita URIs `file://` e enfileira os
  arquivos no plugin até o Dart avisar que está pronto (`app.ready`), pois no
  primeiro lançamento o Flutter ainda está subindo. Sem D-Bus de sessão o
  GApplication cai para instância própria, como antes.
* **Se o Android não está pronto** (arquivo aberto de fora): a fila liga a VM
  se ela estiver desligada e espera até 10 min, em vez de recusar como
  acontece com arrastar-e-soltar (onde o usuário já está olhando a janela).
* **XAPK**: ZIP próprio (`zip_reader.dart`, sem dependências: ZIP64 e
  descompactação em blocos). Os APKs são extraídos para `~/.cache/secada/` só
  para serem inspecionados (ABI, minSdk); os OBB vão em fluxo do ZIP para o
  `cat >` no Android. Sessão do PackageManager: `pm install-create` →
  `install-write -S <bytes> <sessão> <nome> -` por parte (stdin) →
  `install-commit`, com `install-abandon` em caso de erro.
* **O `adb shell` junta os argumentos com espaços** e o Android executa o
  resultado com `sh -c`: `['sh','-c','mkdir -p … && cat > …']` virava
  `sh -c mkdir -p …` e o OBB nunca chegava (só um teste no Android real
  mostrou; o `adb` de mentira dos testes registra os argumentos, não os
  executa). O script vai como um único argumento.
* **Registro do tipo de arquivo**: `application/vnd.android.package-archive`
  já existe no shared-mime-info; o XAPK não, então o SECADA Emulator define
  `application/x-xapk` (`*.xapk`, subclasse de `application/zip`). Para o
  duplo clique abrir o SECADA Emulator e não o gerenciador de compactados (o APK é um
  ZIP), ele precisa ser o padrão em `mimeapps.list`: o `.deb` o põe no padrão
  do sistema (`/etc/xdg/mimeapps.list`, por script e não por arquivo do
  pacote, para não colidir com outro pacote) e o app/`install.sh` no do
  usuário, uma vez (`packaging/mimeapps.sh` e `FileAssociations.mergeMimeApps`
  fazem a mesma edição, preservando o resto do arquivo).

## Tradução ARM

O Android-x86 9.0-r2 já vem preparado: `ro.dalvik.vm.native.bridge=libnb.so`,
`ro.product.cpu.abilist=x86_64,x86,armeabi-v7a,armeabi` e, no
`init.android_x86_64.rc`, `on property:persist.sys.nativebridge=1 → start
nativebridge`. O `libnb.so` só carrega o tradutor se essa propriedade estiver
ligada, e o serviço (`/system/bin/enable_nativebridge`) espera o arquivo
`houdini9_y.sfs` em `/data/arm` ou `/data/media/0/arm`, monta-o em
`/system/lib/arm`, liga o `libhoudini.so` real (o de `/system` tem 0 bytes) e
registra `arm_exe`/`arm_dyn` no `binfmt_misc`.

* **O que faltava era o arquivo**: os links do script são encurtadores
  (`t.cn`, `tinyurl`); os do `tinyurl` ainda levam a
  `dl.android-x86.org/houdini.php?v=9_y` → espelho. Só HTTP (o HTTPS do
  domínio tem certificado errado), por isso o SHA-256 é fixo no código.
* **Onde colocar**: direto em `/data/media/0/arm` (dono `media_rw`). Se o
  serviço já estiver em execução, ele está num laço tentando montar o arquivo
  *dessa* pasta; um arquivo em `/data/arm` só seria movido na partida
  seguinte do serviço.
* **Não reexecutar o serviço com o tradutor ativo**: o script desmonta e mata
  os processos que usam a montagem (apps ARM abertos). O SECADA Emulator só o inicia se
  `binfmt_misc/arm_exe` ainda não existe.
* **Sem reinício**: processos novos já carregam o tradutor (testado: o app ARM
  abriu logo após a ativação).
* **ARM64 (`houdini9_z.sfs`)**: o `enable_nativebridge` já aceita `64` (monta
  em `/system/lib64/arm64`, liga `/system/lib64/libhoudini.so`, registra
  `arm64_exe`/`arm64_dyn`), mas nenhum serviço o chama, o `abilist64` da
  imagem é só `x86_64` e o Android-x86 nunca publicou o arquivo (`9_z` dá 404
  no espelho e no Wayback). O SECADA Emulator faz a parte dele quando o arquivo existe em
  `~/.local/share/secada/runtime/houdini/houdini9_z.sfs` (não é baixado):
  * **initrd complementar**: o initrd da ISO executa `/scripts/*` dentro de
    `/android` (tmpfs gravável) e o kernel aceita cpios concatenados; o SECADA Emulator
    anexa um cpio com `scripts/99-secada-arm64` a uma cópia do initrd
    (`boot/initrd-secada.img`). O script acrescenta as ABIs com `arm64-v8a` ao
    `default.prop` (lido antes do `build.prop`; no Android 9 uma `ro.*` vale
    pela primeira definição) e o serviço `nativebridge64` ao
    `init.android_x86_64.rc`, disparado quando o de 32 bits termina.
  * envia o arquivo para `/data/media/0/arm` e reinicia o serviço.
  * se a ativação falha, grava `arm64-failed` com tamanho/data do arquivo e
    não anuncia ARM64 nos próximos boots (senão o PackageManager instalaria a
    versão ARM64 dos apps, que não abriria).
  Testado com um arquivo falso: ABIs `x86_64,arm64-v8a` e serviço rodando no
  1º boot, falha detectada, e no 2º boot `abilist64` volta a `x86_64`.
* **CPU "GenuineIntel"**: o houdini64 (9.0.5c_z) recusa CPUs que não sejam
  Intel ("Initialize Houdini ... failed", sem nenhuma chamada de sistema antes:
  é checagem por CPUID). Num host AMD, com o tradutor ARM64 presente, a VM usa
  `-cpu host,vendor=GenuineIntel`. Só isso deixava o boot em ~370 s: com
  fabricante Intel o kernel faz as chamadas de sistema de 32 bits por
  `SYSENTER`, que o AMD não tem em modo 64 bits e o KVM emula uma a uma. Com
  `vdso32=0` a bionic de 32 bits usa `int 0x80` e o boot volta a ~21 s.
  Verificado: um ELF ARM64 mínimo roda ("arm64 ok") e o Backstage instala
  como `arm64-v8a`.
* **Por que importa**: o PackageManager escolhe a primeira ABI da lista que o
  APK traz. Sem ARM64, apps com as duas versões (como o Backstage) rodam a de
  32 bits, que no celular nunca é usada. O jogo do Backstage, em 32 bits sob o
  houdini 9.0.1b, para depois de `Loading popcycle.dat..` (menu nativo
  desenhado, lógica parada) e, quando passa, entra num laço de SIGSEGV em
  `libsamp.so+0xE907E`; a tela de carregamento do app expira em 90 s e revela o
  menu nativo do GTA. A rede da VM não tem culpa: a consulta SA-MP ao servidor
  responde em ~55 ms e o servidor registrou o "join".
* **Causa raiz do Backstage (vale para 32 e 64 bits)**: na versão ARM64 o
  jogo para no mesmo ponto. O log mostra `shadowhook version 2.0.1 ...
  init-errno: 12` = "Init linker mod failed": o ShadowHook procura
  `soinfo::call_constructors()` no linker ARM, que sob o houdini é emulado, e
  aborta a inicialização inteira. Sem ShadowHook os hooks do `libsamp` no
  `libGTASA` não entram (não pula o menu; quando entra, lê um ponteiro global
  nunca preenchido a cada quadro). A correção é no app: compilar o ShadowHook
  2.0.1 com o módulo do linker opcional (ele só serve para hooks em
  bibliotecas carregadas depois e callbacks de init/fini). No celular nada
  muda, porque lá o módulo inicializa.

## Android enxuto

Medido com `dumpsys meminfo` no Android recém-iniciado: Play Services
(200 MB), Play Store (160 MB), app Google (~200 MB), Gmail e o assistente de
configuração somavam ~750 MB de PSS, sem funcionar (o Play Services exige
atualização). Como a partição de sistema é squashfs somente leitura, os
pacotes são removidos para o usuário 0 (`pm uninstall -k --user 0`), o que é
reversível com `cmd package install-existing`. Detalhes:

* O Play Services é administrador do dispositivo e recusa a remoção; o
  fallback é `pm disable-user`.
* No Android 9 o WebView é servido pelo Chrome; removido o Chrome, o pacote
  `com.google.android.webview` é habilitado e definido como provedor.
* Após remover, os dados do Launcher3 são limpos para não sobrarem atalhos e o
  widget de busca órfão.
* A verificação a cada boot usa uma única listagem de pacotes, então custa
  pouco quando o perfil já está aplicado.

## Console serial como canal de controle

O kernel recebe `console=ttyS0` e o Android-x86 abre um shell root nele. O
QEMU expõe a serial como socket UNIX (com log em
`logs/android-serial.log`). Os comandos são delimitados por marcadores de
início/fim (o eco do terminal é descartado) e o código de saída vem no
marcador final. Desligar o eco com `stty` foi descartado: deixava o terminal
do Android-x86 num estado inutilizável.

## Janela com a proporção do Android

As dicas de proporção do ICCCM não servem: o Muffin (Cinnamon) ignora o
*base size* e aplicaria a proporção à janela inteira (com barra de título e
lateral). O SECADA Emulator ajusta a altura da janela ao fim de cada redimensionamento
e, em maximizado/tela cheia, usa preenchimento por *cover* quando a diferença
de proporção é de até ~4%.

## Teclas de navegação por scancode

O QEMU 8.2 trunca keysyms para 16 bits na tabela de layout VNC
(`XF86Back` 0x1008FF26 vira 0xFF26 → "no scancode found"). O cliente anuncia
a pseudo-codificação **QEMU Extended Key Event (−258)** e envia os scancodes
XT `e0 6a` (KEY_BACK) e `e0 32` (KEY_HOMEPAGE), mapeados pelo `Generic.kl` do
Android para BACK e HOME. Esc via KEYCODE_ESCAPE não serve como "voltar" em
apps que consomem Esc (ex.: busca do Google).

## Backend C++ embutido no runner (não Rust, não processo separado)

* O executável Flutter Linux já é C++/GTK; o backend roda no mesmo processo,
  com acesso direto ao registro de texturas e à janela GTK.
* `fork/execve` com `PR_SET_PDEATHSIG` garante ausência de órfãos mesmo em
  crash — algo que `Process.start` do Dart não oferece.
* Orquestração (QMP JSON, ADB, arquivos) ficou em Dart: assíncrona, testável
  com `flutter test` e sem bibliotecas JSON em C++.

## Ambiente sem root

O host de desenvolvimento não tinha `sudo` sem senha nem QEMU/Flutter/GTK-dev.
Tudo foi obtido sem root e com verificação de integridade:

* `apt-get download` + `dpkg -x` dos pacotes oficiais do Ubuntu (QEMU 8.2.2,
  clang 18, cmake, ninja, headers GTK) — `scripts/setup-dev-userland.sh`;
* Flutter estável oficial com SHA-256 do `releases_linux.json`;
* QEMU e ADB relocáveis (`runtime/`), também embarcados no pacote final.

## Segurança

* Display e QMP só em sockets UNIX dentro de `$XDG_RUNTIME_DIR/secada` (0700).
* ADB encaminhado apenas para `127.0.0.1` (porta 6555 por padrão; outra livre
  é escolhida se ocupada).
* QEMU com `-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny`.
* Arrastar-e-soltar aceita somente `text/uri-list` com ação COPY (o arquivo de
  origem nunca é movido) e só caminhos locais.
* Nenhum script remoto é executado; downloads verificados por MD5/SHA-256.

## Trava do ponteiro

* **Problema**: o tablet USB é absoluto; com a captura de ponteiro do Android o jogo recebe a posição, e o cursor do computador
  sai da janela (a câmera para na borda). Dentro do Android não há como reposicionar o cursor do computador.
* **Solução**: o app avisa por logcat (`SecadaPointerLock`: `lock <n>` a cada segundo e `unlock`); o `PointerLockWatcher` lê o `adb logcat`
  e solta o cursor se o batimento parar por 3,5 s (sem `dumpsys`) e o `DisplayView` prende o cursor no centro
  (mesmo `gdk_device_warp` da mira do mapeador), enviando `rel` ao mouse PS/2 pelo QMP. Os botões continuam no tablet (o QEMU
  entrega `btn` ao tablet e `rel` ao PS/2).
* **Armadilhas**: sob captura o tablet absoluto é entregue ao app como "relativo" com coordenadas absolutas (o app distingue por
  dispositivo); o LatinIME do Android-x86 abre o painel de emoji ao soltar a tecla Alt, então o jogo desconecta o IME enquanto
  joga (`FLAG_ALT_FOCUSABLE_IM`); a faixa de recentralização é grande (30% do menor lado) para uma varrida rápida não escapar entre
  dois eventos.
* **Bug que custou horas (16/10)**: o aviso era só `lock`, uma vez e depois a cada 15 s por `dumpsys`; a câmera "funcionava uma vez e
  parava". Causa: o `logd` suprime linhas **idênticas** repetidas (`chatty: uid=... identical N lines`), então o batimento sumia por
  7 a 15 s, o emulador soltava o cursor (que fugia da janela) e a câmera não tinha mais movimento. Cada linha precisa de texto único
  (`lock 17`, `lock 18`...). Para achar: `adb logcat -d | grep chatty | grep <pacote>` e comparar com as linhas que chegam ao PC.
