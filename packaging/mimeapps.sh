#!/bin/sh
# Define (ou retira) o SECADA Emulator como programa padrão para .apk e .xapk num arquivo
# mimeapps.list (padrão freedesktop.org).
#
# Uso: mimeapps.sh add|remove <arquivo>
#   add     coloca secada.desktop à frente em [Default Applications] e
#           (trocando o anux.desktop do programa antigo, se houver) em
#           [Added Associations], preservando todo o resto do arquivo
#   remove  tira secada.desktop dessas linhas (e apaga as que ficarem vazias)
#
# Usado pelo install.sh/uninstall.sh (arquivo do usuário) e pelos scripts do
# pacote .deb (/etc/xdg/mimeapps.list, o padrão do sistema).
set -e
ACTION="${1:-}"
FILE="${2:-}"
[ -n "$ACTION" ] && [ -n "$FILE" ] || { echo "uso: $0 add|remove <mimeapps.list>" >&2; exit 2; }

case "$ACTION" in
  add)
    mkdir -p "$(dirname "$FILE")"
    [ -f "$FILE" ] || : > "$FILE"
    TMP="$FILE.secada-tmp"
    awk '
      function want_section(s) { return s == "Default Applications" || s == "Added Associations" }
      function flush_blanks() { while (blanks > 0) { print ""; blanks-- } }
      function emit_missing(s,   i) {
        for (i = 1; i <= n; i++)
          if (!((s SUBSEP types[i]) in seen)) print types[i] "=" desk ";"
        done[s] = 1
      }
      BEGIN {
        desk = "secada.desktop"
        types[1] = "application/vnd.android.package-archive"
        types[2] = "application/x-xapk"
        n = 2
        sec = ""
        blanks = 0
      }
      # Linhas em branco ficam em espera para que as chaves que faltam entrem
      # logo depois da última chave da seção, antes do espaçamento.
      /^[ \t]*$/ { blanks++; next }
      /^\[.*\]/ {
        if (want_section(sec) && !(sec in done)) emit_missing(sec)
        flush_blanks()
        sec = substr($0, 2, length($0) - 2)
        seen_sec[sec] = 1
        print
        next
      }
      {
        flush_blanks()
        if (want_section(sec)) {
          for (i = 1; i <= n; i++) {
            t = types[i]
            if (index($0, t "=") == 1) {
              seen[sec SUBSEP t] = 1
              value = substr($0, length(t) + 2)
              m = split(value, apps, ";")
              out = desk ";"
              for (j = 1; j <= m; j++) if (apps[j] != "" && apps[j] != desk && apps[j] != "anux.desktop") out = out apps[j] ";"
              print t "=" out
              next
            }
          }
        }
        print
      }
      END {
        if (want_section(sec) && !(sec in done)) emit_missing(sec)
        flush_blanks()
        split("Default Applications|Added Associations", all, "|")
        for (k = 1; k <= 2; k++) {
          s = all[k]
          if (!(s in seen_sec)) {
            print ""
            print "[" s "]"
            emit_missing(s)
          }
        }
      }
    ' "$FILE" > "$TMP"
    mv "$TMP" "$FILE"
    ;;
  remove)
    [ -f "$FILE" ] || exit 0
    TMP="$FILE.secada-tmp"
    awk '
      BEGIN { desk = "secada.desktop" }
      {
        if ((index($0, "application/vnd.android.package-archive=") == 1 ||
             index($0, "application/x-xapk=") == 1) && index($0, desk) > 0) {
          eq = index($0, "=")
          key = substr($0, 1, eq - 1)
          m = split(substr($0, eq + 1), apps, ";")
          out = ""
          for (j = 1; j <= m; j++) if (apps[j] != "" && apps[j] != desk) out = out apps[j] ";"
          if (out != "") print key "=" out
          next
        }
        print
      }
    ' "$FILE" > "$TMP"
    mv "$TMP" "$FILE"
    ;;
  *)
    echo "ação desconhecida: $ACTION" >&2
    exit 2
    ;;
esac
