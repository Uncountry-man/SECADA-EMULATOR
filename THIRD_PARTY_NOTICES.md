# Componentes de terceiros

O pacote distribuível do SECADA Emulator inclui ou utiliza os seguintes componentes. As
fontes correspondentes dos binários Debian/Ubuntu embarcados podem ser obtidas
com `apt-get source <pacote>` (Ubuntu 24.04 "noble").

| Componente | Uso | Licença |
|---|---|---|
| QEMU 8.2.2 (`qemu-system-x86`, `qemu-utils`, módulos) | Virtualização | GPL-2.0 (partes LGPL/BSD/MIT) |
| SeaBIOS | Firmware BIOS da VM | LGPL-3.0 |
| iPXE | ROMs de rede da VM | GPL-2.0 |
| libslirp, libfdt, libvirglrenderer, libspice-server, libcacard, libusbredirparser | Bibliotecas do QEMU ausentes no host | BSD-3-Clause / BSD-2/GPL-2 / MIT / LGPL-2.1 / LGPL-2.1 / LGPL-2.1 |
| ADB e bibliotecas `android-lib*` (Debian) | Comunicação com o Android | Apache-2.0 |
| Flutter engine e framework | Interface | BSD-3-Clause |
| Pacotes Dart `file_selector`, `path` | Seleção de arquivos, caminhos | BSD-3-Clause |
| Fennec F-Droid 157 (Firefox, `org.mozilla.fennec_fdroid`) | Navegador pré-instalado no Android | MPL-2.0 |
| Fossify Notes 1.7.0 (`org.fossify.notes`) | Bloco de notas pré-instalado no Android | GPL-3.0 |
| libhoudini 9.0.1b_y (Intel, proprietário) | Tradução ARM 32 bits, **não embarcado**: baixado sob demanda do espelho do Android-x86 (`dl.android-x86.org/houdini/9_y/houdini.sfs`) quando a opção "Tradução ARM" está ligada, como o próprio Android-x86 faz | Licença da Intel distribuída pelo projeto Android-x86 |
| Android-x86 9.0-r2 (não embarcado; baixado pelo usuário) | Sistema convidado | Apache-2.0 / GPL-2.0 (kernel) e licenças dos componentes |

Fennec F-Droid e Fossify Notes são os APKs oficiais do repositório F-Droid
(https://f-droid.org), sem modificações; as fontes estão listadas nas páginas
de cada app no F-Droid.

Os aplicativos Google presentes na imagem Android-x86 são de responsabilidade
do projeto Android-x86 e seus termos.
