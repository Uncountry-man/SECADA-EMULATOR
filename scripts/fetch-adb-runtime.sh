#!/usr/bin/env bash
# Monta um ADB relocável (sem root) a partir dos pacotes .deb do Ubuntu/Mint.
#
# Uso: scripts/fetch-adb-runtime.sh [destino]
#   destino padrão: ~/.local/share/secada/runtime/platform-tools
#
# Layout: adb (wrapper) · bin/adb · lib/*.so
# Licença: AOSP (Apache-2.0). Fontes: "apt-get source adb".
set -euo pipefail

DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/secada/runtime/platform-tools}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKGS=(adb android-libbase android-libboringssl android-libcutils android-liblog
      android-libziparchive)
# libprotobuf muda de nome entre versões (t64); pega o que o adb exige.
PROTO="$(apt-cache depends adb 2>/dev/null | awk '/Depends: libprotobuf/ {print $2; exit}')"
[ -n "$PROTO" ] && PKGS+=("$PROTO")

echo "==> Baixando ${PKGS[*]}"
( cd "$WORK" && apt-get download "${PKGS[@]}" >/dev/null )
mkdir -p "$WORK/root"
for d in "$WORK"/*.deb; do dpkg -x "$d" "$WORK/root"; done
R="$WORK/root"

rm -rf "$DEST.tmp" && mkdir -p "$DEST.tmp"/{bin,lib}
cp -aL "$R/usr/lib/android-sdk/platform-tools/adb" "$DEST.tmp/bin/adb"
cp -aL "$R"/usr/lib/x86_64-linux-gnu/android/*.so* "$DEST.tmp/lib/" 2>/dev/null || true
cp -aL "$R"/usr/lib/x86_64-linux-gnu/libprotobuf.so.* "$DEST.tmp/lib/" 2>/dev/null || true

cat > "$DEST.tmp/adb" <<'EOF'
#!/bin/sh
# Wrapper: usa as bibliotecas Android empacotadas ao lado do binário.
HERE="$(dirname "$(readlink -f "$0")")"
LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" exec "$HERE/bin/adb" "$@"
EOF
chmod +x "$DEST.tmp/adb"

if LD_LIBRARY_PATH="$DEST.tmp/lib" ldd "$DEST.tmp/bin/adb" | grep -q 'not found'; then
  LD_LIBRARY_PATH="$DEST.tmp/lib" ldd "$DEST.tmp/bin/adb" | grep 'not found'
  echo "ERRO: bibliotecas ausentes para o adb"; exit 1
fi
"$DEST.tmp/adb" version | head -1
rm -rf "$DEST" && mv "$DEST.tmp" "$DEST"
echo "==> ADB pronto em $DEST"
