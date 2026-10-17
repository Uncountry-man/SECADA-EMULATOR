#!/usr/bin/env bash
# Compila o SECADA Emulator em modo release e gera os pacotes distribuíveis:
#   dist/secada-<versão>-linux-x86_64.tar.gz  (portátil, instalação sem root)
#   dist/secada_<versão>_amd64.deb            (instala em /opt/secada)
#
# Ambos incluem o runtime QEMU, o ADB (scripts/fetch-*-runtime.sh) e os apps
# pré-instalados no Android (scripts/fetch-guest-apps.sh), então o usuário só
# precisa da imagem Android (scripts/fetch-android-image.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
VERSION="$(awk '/^version:/ {split($2,a,"+"); print a[1]}' "$APP/pubspec.yaml")"
NAME="secada-$VERSION-linux-x86_64"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"

[ -f "$HOME/.local/share/secada-dev/env.sh" ] && ! command -v flutter >/dev/null && \
  . "$HOME/.local/share/secada-dev/env.sh"

echo "==> flutter build linux --release"
# O subconjunto da fonte de ícones fica em build/flutter_assets e, em builds
# incrementais, pode continuar com os ícones da versão anterior (ícones novos
# somem da interface). Removê-lo força a regeneração.
rm -rf "$APP/build/flutter_assets"
( cd "$APP" && flutter build linux --release )

echo "==> Montando $STAGE"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -a "$APP/build/linux/x64/release/bundle/." "$STAGE/"

RT="${XDG_DATA_HOME:-$HOME/.local/share}/secada/runtime"
[ -x "$RT/qemu/bin/qemu-system-x86_64" ] || "$ROOT/scripts/fetch-qemu-runtime.sh" "$RT/qemu"
[ -x "$RT/platform-tools/adb" ] || "$ROOT/scripts/fetch-adb-runtime.sh" "$RT/platform-tools"
"$ROOT/scripts/fetch-guest-apps.sh" "$RT/apps"
mkdir -p "$STAGE/runtime"
cp -a "$RT/qemu" "$RT/platform-tools" "$RT/apps" "$STAGE/runtime/"

mkdir -p "$STAGE/scripts"
cp "$ROOT/scripts/fetch-android-image.sh" "$STAGE/scripts/"
# Associação de .apk/.xapk ao SECADA Emulator: tipo MIME do XAPK e utilitário do
# mimeapps.list (usados pelo install.sh e pelo .deb).
cp "$ROOT/packaging/secada-xapk.xml" "$STAGE/share/"
cp "$ROOT/packaging/mimeapps.sh" "$STAGE/scripts/"
cp "$ROOT/README.md" "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/"

cat > "$STAGE/install.sh" <<'EOF'
#!/usr/bin/env bash
# Instala o SECADA Emulator para o usuário atual (sem root):
#   ~/.local/opt/secada, ~/.local/bin/secada e atalho no menu de aplicativos.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.local/opt/secada"
rm -rf "$DEST" && mkdir -p "$DEST" && cp -a "$SRC/." "$DEST/"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$HOME/.local/bin" "$DATA/applications" "$DATA/mime/packages"
ln -sfn "$DEST/secada" "$HOME/.local/bin/secada"
# %F: o gerenciador de arquivos entrega os .apk/.xapk selecionados ao SECADA Emulator.
cat > "$DATA/applications/secada.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=SECADA Emulator
GenericName=Emulador Android
Comment=Android 9 em máquina virtual QEMU/KVM
Exec="$DEST/secada" %F
Icon=$DEST/share/secada.png
Terminal=false
Categories=Utility;Emulator;
MimeType=application/vnd.android.package-archive;application/x-xapk;
StartupWMClass=dev.secada.secada
StartupNotify=true
DESK
# O APK já existe no shared-mime-info; o XAPK é registrado aqui.
cp "$DEST/share/secada-xapk.xml" "$DATA/mime/packages/secada-xapk.xml"
update-mime-database "$DATA/mime" >/dev/null 2>&1 || true
update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
# Programa padrão para .apk e .xapk (dois cliques instalam no SECADA Emulator).
"$DEST/scripts/mimeapps.sh" add "$CONF/mimeapps.list" || true
echo "SECADA Emulator instalado em $DEST (abre .apk e .xapk com dois cliques)"
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  echo "AVISO: sem acesso a /dev/kvm. Execute: sudo usermod -aG kvm \$USER e reinicie a sessão."
fi
if ! ls "${XDG_DATA_HOME:-$HOME/.local/share}"/secada/images/*.iso >/dev/null 2>&1; then
  echo "Falta a imagem Android. Baixe com: $DEST/scripts/fetch-android-image.sh"
fi
EOF
cat > "$STAGE/uninstall.sh" <<'EOF'
#!/usr/bin/env bash
# Remove o SECADA Emulator. Com --purge remove também imagens, disco virtual e configurações.
set -euo pipefail
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
# Retira o SECADA Emulator dos programas padrão de .apk/.xapk antes de apagar o script.
"$HOME/.local/opt/secada/scripts/mimeapps.sh" remove "$CONF/mimeapps.list" 2>/dev/null || true
rm -rf "$HOME/.local/opt/secada" "$HOME/.local/bin/secada" "$DATA/applications/secada.desktop" \
  "$DATA/mime/packages/secada-xapk.xml"
update-mime-database "$DATA/mime" >/dev/null 2>&1 || true
update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
if [ "${1:-}" = "--purge" ]; then
  rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/secada" "${XDG_CONFIG_HOME:-$HOME/.config}/secada"
  echo "SECADA Emulator e todos os dados removidos."
else
  echo "SECADA Emulator removido (dados preservados em ~/.local/share/secada; use --purge para apagar)."
fi
EOF
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/scripts/"*.sh

echo "==> Gerando tar.gz"
( cd "$DIST" && tar -czf "$NAME.tar.gz" "$NAME" )

echo "==> Gerando .deb"
DEB="$DIST/deb"
rm -rf "$DEB" && mkdir -p "$DEB/DEBIAN" "$DEB/opt/secada" "$DEB/usr/bin" \
  "$DEB/usr/share/applications" "$DEB/usr/share/icons/hicolor/256x256/apps" \
  "$DEB/usr/share/mime/packages"
cp -a "$STAGE/." "$DEB/opt/secada/"
rm -f "$DEB/opt/secada/install.sh" "$DEB/opt/secada/uninstall.sh"
ln -s /opt/secada/secada "$DEB/usr/bin/secada"
cp "$STAGE/share/secada.png" "$DEB/usr/share/icons/hicolor/256x256/apps/secada.png"
cat > "$DEB/usr/share/applications/secada.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SECADA Emulator
GenericName=Emulador Android
Comment=Android 9 em máquina virtual QEMU/KVM
Exec=/opt/secada/secada %F
Icon=secada
Terminal=false
Categories=Utility;Emulator;
MimeType=application/vnd.android.package-archive;application/x-xapk;
StartupWMClass=dev.secada.secada
StartupNotify=true
EOF
# Tipo MIME do XAPK: os gatilhos do dpkg atualizam a base de tipos e de atalhos.
cp "$ROOT/packaging/secada-xapk.xml" "$DEB/usr/share/mime/packages/secada-xapk.xml"
# Programa padrão do sistema para .apk/.xapk (o usuário pode mudar o dele).
cat > "$DEB/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ] && [ -x /opt/secada/scripts/mimeapps.sh ]; then
  /opt/secada/scripts/mimeapps.sh add /etc/xdg/mimeapps.list || true
fi
exit 0
EOF
cat > "$DEB/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] && [ -x /opt/secada/scripts/mimeapps.sh ]; then
  /opt/secada/scripts/mimeapps.sh remove /etc/xdg/mimeapps.list || true
fi
exit 0
EOF
chmod 755 "$DEB/DEBIAN/postinst" "$DEB/DEBIAN/prerm"
SIZE_KB=$(du -sk "$DEB" | cut -f1)
cat > "$DEB/DEBIAN/control" <<EOF
Package: secada
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $SIZE_KB
Depends: libgtk-3-0t64 | libgtk-3-0, e2fsprogs, libepoxy0, libgbm1, libegl1, libgles2
Maintainer: SECADA Emulator <noreply@secada.dev>
Description: Emulador Android nativo para Linux (QEMU/KVM)
 Executa o Android-x86 9 numa máquina virtual QEMU acelerada por KVM, com
 a tela integrada à janela, mouse/teclado nativos e instalação de APK/XAPK
 (dois cliques num arquivo .apk ou .xapk no gerenciador de arquivos).
 A imagem Android é baixada com /opt/secada/scripts/fetch-android-image.sh.
EOF
chmod -R go-w "$DEB"
dpkg-deb --root-owner-group --build "$DEB" "$DIST/secada_${VERSION}_amd64.deb" >/dev/null
rm -rf "$DEB"

ls -lh "$DIST"/*.tar.gz "$DIST"/*.deb
