#!/usr/bin/env bash
# Baixa os aplicativos que o SECADA Emulator pré-instala no Android (navegador e notas),
# direto do repositório oficial do F-Droid, com verificação SHA-256.
#
# Uso: scripts/fetch-guest-apps.sh [destino]
#   destino padrão: ~/.local/share/secada/runtime/apps
#
# Escolhas (Android 9, x86-64):
# * Navegador: Fennec F-Droid (Firefox, motor Gecko próprio). Navegadores
#   baseados em WebView ficariam presos ao WebView 75 (2019) da imagem
#   Android-x86, incompatível com boa parte da web atual.
# * Notas: Fossify Notes.
# Licenças: MPL-2.0 (Fennec) e GPL-3.0 (Fossify Notes); fontes no F-Droid.
set -euo pipefail

DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/secada/runtime/apps}"

# arquivo|sha256 (versões fixas; o F-Droid move as antigas para /archive)
APPS=(
  "org.mozilla.fennec_fdroid_1570010.apk|301a70e4fd88887806b69a938b9750cf7a70ae2445aeb1ecf7a6c5b2cbf14c60"
  "org.fossify.notes_13.apk|5a56e0e39cc488e1f3b947d3801006d3b7450ec73c67f03195c64c5fd3b6bced"
)
MIRRORS=(https://f-droid.org/repo https://f-droid.org/archive)

mkdir -p "$DEST"
for entry in "${APPS[@]}"; do
  file="${entry%%|*}"
  sum="${entry##*|}"
  out="$DEST/$file"
  if [ -f "$out" ] && echo "$sum  $out" | sha256sum -c --status; then
    echo "==> $file já presente"
    continue
  fi
  ok=0
  for m in "${MIRRORS[@]}"; do
    echo "==> Baixando $m/$file"
    if curl -fL --retry 3 --progress-bar -o "$out.part" "$m/$file" &&
       echo "$sum  $out.part" | sha256sum -c --status; then
      mv "$out.part" "$out"
      ok=1
      break
    fi
    rm -f "$out.part"
  done
  [ "$ok" = 1 ] || { echo "ERRO: não foi possível obter $file"; exit 1; }
done
echo "==> Apps prontos em $DEST"
