#!/usr/bin/env bash
# Prepara um ambiente de desenvolvimento SEM root (para quem não pode usar
# "sudo apt install clang cmake ninja-build libgtk-3-dev"):
#   * baixa os .deb de clang/cmake/ninja/GTK-dev com "apt-get download" e os
#     extrai em ~/.local/share/secada-dev/sysroot;
#   * baixa o Flutter SDK estável oficial;
#   * gera ~/.local/share/secada-dev/env.sh (source antes de compilar).
#
# Com sudo disponível, prefira o caminho padrão descrito no README.
set -euo pipefail

DEV="${SECADA_DEV:-$HOME/.local/share/secada-dev}"
SYSROOT="$DEV/sysroot"
mkdir -p "$DEV/debs" "$DEV/dl"

echo "==> Resolvendo pacotes de compilação ausentes"
mapfile -t PKGS < <(LANG=C apt-get -s install clang cmake ninja-build libgtk-3-dev \
    liblzma-dev libstdc++-12-dev 2>/dev/null | awk '/^Inst/ && $3 !~ /^\[/ {print $2}' \
    | grep -v ':i386' | grep -vE '^(mesa-|libgl1-mesa|libglx-mesa|libegl-mesa|libgbm1|lib32|libc6-i386)')
if [ ${#PKGS[@]} -gt 0 ]; then
  ( cd "$DEV/debs" && apt-get download "${PKGS[@]}" )
  mkdir -p "$SYSROOT"
  for d in "$DEV"/debs/*.deb; do dpkg -x "$d" "$SYSROOT"; done
  # Symlinks .so -> bibliotecas já instaladas no sistema.
  find "$SYSROOT/usr/lib" -xtype l | while read -r l; do
    t=$(readlink "$l"); c="$(dirname "/${l#"$SYSROOT"/}")/$t"
    [ -e "$c" ] && ln -sf "$c" "$l"
  done
  # Usa o GCC do sistema (evita headers de libstdc++ sem a biblioteca).
  rm -rf "$SYSROOT"/usr/lib/gcc/x86_64-linux-gnu/12 "$SYSROOT"/usr/include/c++/12 \
         "$SYSROOT"/usr/include/x86_64-linux-gnu/c++/12
fi

if [ ! -x "$DEV/flutter/bin/flutter" ]; then
  echo "==> Baixando Flutter (canal estável)"
  read -r ARCHIVE SHA < <(curl -s https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json \
    | python3 -c "import json,sys; d=json.load(sys.stdin); h=d['current_release']['stable']; r=[x for x in d['releases'] if x['hash']==h][0]; print(r['archive'], r['sha256'])")
  curl -fL -o "$DEV/dl/flutter.tar.xz" "https://storage.googleapis.com/flutter_infra_release/releases/$ARCHIVE"
  echo "$SHA  $DEV/dl/flutter.tar.xz" | sha256sum -c
  tar -xf "$DEV/dl/flutter.tar.xz" -C "$DEV"
fi

CMAKE_DIR=$(ls -d "$SYSROOT"/usr/share/cmake-* 2>/dev/null | head -1 || true)
cat > "$DEV/env.sh" <<EOF
# Ambiente de desenvolvimento userland do SECADA Emulator (sem root)
export SECADA_DEV="$DEV"
export SECADA_SYSROOT="$SYSROOT"
export PATH="\$SECADA_DEV/flutter/bin:\$SECADA_SYSROOT/usr/bin:\$PATH"
export LD_LIBRARY_PATH="\$SECADA_SYSROOT/usr/lib/x86_64-linux-gnu:\$SECADA_SYSROOT/usr/lib/llvm-18/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export PKG_CONFIG_SYSROOT_DIR="\$SECADA_SYSROOT"
export PKG_CONFIG_PATH="\$SECADA_SYSROOT/usr/lib/x86_64-linux-gnu/pkgconfig:\$SECADA_SYSROOT/usr/share/pkgconfig"
${CMAKE_DIR:+export CMAKE_ROOT="$CMAKE_DIR"}
EOF
. "$DEV/env.sh"
flutter config --no-analytics --enable-linux-desktop >/dev/null
flutter doctor -v 2>&1 | sed -n '/Linux toolchain/,/^$/p'
echo "==> Pronto. Use: source $DEV/env.sh"
