#!/usr/bin/env bash
# Baixa a imagem Android-x86 9.0-r2 (x86_64) e verifica o MD5 oficial
# publicado pelo projeto no SourceForge.
#
# Uso: scripts/fetch-android-image.sh [diretório]
#   diretório padrão: ~/.local/share/secada/images
#
# O download usa vários segmentos em paralelo (alguns espelhos limitam a
# velocidade por conexão) e alterna entre fontes que hospedam o mesmo arquivo.
# A integridade é garantida pelo MD5, não pela fonte.
set -euo pipefail

DIR="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/secada/images}"
NAME="android-x86_64-9.0-r2.iso"
SIZE=965738496
MD5="e9ba997cede7bf3514d2ba3e624ff767"
SOURCES=(
  "https://downloads.sourceforge.net/project/android-x86/Release%209.0/$NAME"
  "https://archive.org/download/android-x86_64-9.0-r2/$NAME"
  "https://archive.org/download/android-x86-v9.0-r2-32bit-64bit-iso-files/$NAME"
)
SEGMENTS=16

mkdir -p "$DIR"
if [ -f "$DIR/$NAME" ] && echo "$MD5  $DIR/$NAME" | md5sum -c --status; then
  echo "Imagem já presente e válida: $DIR/$NAME"; exit 0
fi

PARTS="$DIR/.$NAME.parts"
mkdir -p "$PARTS"
SEG=$(( (SIZE + SEGMENTS - 1) / SEGMENTS ))
echo "==> Baixando $NAME (921 MB) em $SEGMENTS segmentos"
for i in $(seq 0 $((SEGMENTS-1))); do
  s=$((i*SEG)); e=$((s+SEG-1)); [ $e -ge $SIZE ] && e=$((SIZE-1)); want=$((e-s+1))
  ( k=0
    while :; do
      have=$(stat -c %s "$PARTS/$i" 2>/dev/null || echo 0)
      [ "$have" -ge "$want" ] && break
      [ $k -ge 30 ] && { echo "segmento $i falhou"; exit 1; }
      url=${SOURCES[$(( (i+k) % ${#SOURCES[@]} ))]}
      curl -sfL --max-time 1200 -r $((s+have))-$e "$url" >> "$PARTS/$i" || true
      k=$((k+1))
    done ) &
done
while [ "$(jobs -rp | wc -l)" -gt 0 ]; do
  done_bytes=$(du -cb "$PARTS" 2>/dev/null | tail -1 | cut -f1)
  printf '\r    %3d%%' $(( done_bytes * 100 / SIZE ))
  sleep 2
done
wait
echo
for i in $(seq 0 $((SEGMENTS-1))); do cat "$PARTS/$i"; done > "$DIR/$NAME.tmp"
if echo "$MD5  $DIR/$NAME.tmp" | md5sum -c --status; then
  mv "$DIR/$NAME.tmp" "$DIR/$NAME"; rm -rf "$PARTS"
  echo "==> OK (MD5 verificado): $DIR/$NAME"
else
  rm -f "$DIR/$NAME.tmp"; rm -rf "$PARTS"
  echo "ERRO: MD5 não confere; tente novamente."; exit 1
fi
