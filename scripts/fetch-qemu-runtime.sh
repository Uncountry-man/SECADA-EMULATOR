#!/usr/bin/env bash
# Monta um runtime QEMU relocável (sem root) a partir dos pacotes .deb oficiais
# do Ubuntu/Mint, para hosts onde "sudo apt install qemu-system-x86" não é
# possível ou desejado.
#
# Uso: scripts/fetch-qemu-runtime.sh [destino]
#   destino padrão: ~/.local/share/secada/runtime/qemu
#
# Layout gerado:
#   bin/qemu-system-x86_64  bin/qemu-img
#   lib/*.so*  (apenas bibliotecas ausentes no host)
#   lib/qemu/  (módulos: virtio-gpu-gl, egl-headless, ...)
#   share/qemu/ (firmware SeaBIOS/iPXE/VGA BIOS unificados)
#
# Licenças: QEMU (GPL-2.0), SeaBIOS (LGPL-3.0), iPXE (GPL-2.0). As fontes
# correspondentes estão disponíveis com "apt-get source <pacote>".
set -euo pipefail

DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/secada/runtime/qemu}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKGS=(qemu-system-x86 qemu-system-common qemu-system-data qemu-system-modules-opengl
      qemu-utils qemu-block-extra seabios ipxe-qemu)

command -v apt-get >/dev/null || { echo "apt-get não encontrado (requer Debian/Ubuntu/Mint)"; exit 1; }

echo "==> Resolvendo dependências ausentes no host"
mapfile -t MISSING < <(LANG=C apt-get -s install "${PKGS[@]}" 2>/dev/null \
  | awk '/^Inst/ && $3 !~ /^\[/ {print $2}' | grep -v ':i386' \
  | grep -vE '^(ovmf|mesa-|libgl1-mesa|libglx-mesa|libegl-mesa|libgbm1|msr-tools|cpu-checker|lib32|libc6-i386)' || true)
ALL=("${PKGS[@]}" "${MISSING[@]}")
mapfile -t ALL < <(printf '%s\n' "${ALL[@]}" | sort -u)

echo "==> Baixando ${#ALL[@]} pacotes (apt-get download, sem root)"
( cd "$WORK" && apt-get download "${ALL[@]}" >/dev/null )

echo "==> Extraindo"
mkdir -p "$WORK/root"
for d in "$WORK"/*.deb; do dpkg -x "$d" "$WORK/root"; done
R="$WORK/root"

rm -rf "$DEST.tmp" && mkdir -p "$DEST.tmp"/{bin,lib/qemu,share/qemu}
cp -a "$R/usr/bin/qemu-system-x86_64" "$R/usr/bin/qemu-img" "$DEST.tmp/bin/"
cp -a "$R/usr/lib/x86_64-linux-gnu/qemu/." "$DEST.tmp/lib/qemu/"

# Firmware: une os diretórios que o QEMU do Debian procura (firmwarepath).
for dir in "$R/usr/share/qemu" "$R/usr/share/seabios" "$R/usr/lib/ipxe/qemu"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    name="$(basename "$f")"
    if [ -L "$f" ]; then
      target="$(readlink "$f")"
      case "$target" in /*) src="$R$target" ;; *) src="$(dirname "$f")/$target" ;; esac
      [ -e "$src" ] && cp -aL "$src" "$DEST.tmp/share/qemu/$name"
    else
      cp -a "$f" "$DEST.tmp/share/qemu/$name"
    fi
  done
done

# Bibliotecas: copia apenas as que o host não tem.
copy_missing_libs() {
  local bin="$1"
  LD_LIBRARY_PATH="$DEST.tmp/lib:$R/usr/lib/x86_64-linux-gnu" ldd "$bin" 2>/dev/null \
    | awk '/=>/ {print $1, $3}' | while read -r soname path; do
      if ! ldconfig -p | grep -q "^\s*$soname "; then
        if [ -f "$path" ] && [[ "$path" == "$R"* ]]; then
          cp -aL "$path" "$DEST.tmp/lib/$soname"
        fi
      fi
    done
}
copy_missing_libs "$DEST.tmp/bin/qemu-system-x86_64"
copy_missing_libs "$DEST.tmp/bin/qemu-img"
for m in "$DEST.tmp"/lib/qemu/*.so; do copy_missing_libs "$m"; done

echo "==> Verificando"
export LD_LIBRARY_PATH="$DEST.tmp/lib" QEMU_MODULE_DIR="$DEST.tmp/lib/qemu"
if ldd "$DEST.tmp/bin/qemu-system-x86_64" | grep -q 'not found'; then
  ldd "$DEST.tmp/bin/qemu-system-x86_64" | grep 'not found'
  echo "ERRO: bibliotecas ausentes"; exit 1
fi
"$DEST.tmp/bin/qemu-system-x86_64" --version | head -1
"$DEST.tmp/bin/qemu-system-x86_64" -L "$DEST.tmp/share/qemu" -machine pc -display none \
  -nodefaults -S -qmp stdio <<<'{"execute":"qmp_capabilities"}
{"execute":"quit"}' >/dev/null

rm -rf "$DEST" && mv "$DEST.tmp" "$DEST"
echo "==> Runtime QEMU pronto em $DEST ($(du -sh "$DEST" | cut -f1))"
