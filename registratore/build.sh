#!/usr/bin/env bash
# build.sh: compila Lancillotto e crea il bundle firmato ad-hoc.
#
# USO
#   bash registratore/build.sh               architettura di questa macchina -> registratore/build/Lancillotto.app
#   bash registratore/build.sh --universale  arm64 + x86_64 uniti con lipo
#   bash registratore/build.sh --veleno      -D VELENO -> registratore/build-veleno/Lancillotto.app
#                                            (filtri e redattore spenti: SOLO per i banchi)
#
# PASSI
#   1. genera Sorgenti/SchemaIncorporato.swift da schema.sql (il binario non legge Resources);
#   2. swiftc -O -swift-version 5 -target <arch>-apple-macos13, un solo modulo;
#   3. bundle con Info.plist, firma ad-hoc legata al cdhash (--identifier fisso).
# La build VELENO ha un bundle id diverso (.veleno), così non tocca i permessi della vera.
# Niente installazione: copiare in ~/Applications è compito di installa.sh.

set -euo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELENO=0
UNIVERSALE=0
for a in "$@"; do
  case "$a" in
    --veleno) VELENO=1 ;;
    --universale) UNIVERSALE=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "build.sh: argomento sconosciuto: $a" >&2; exit 2 ;;
  esac
done

SCHEMA="$QUI/schema.sql"
INCORPORATO="$QUI/Sorgenti/SchemaIncorporato.swift"
[[ -s "$SCHEMA" ]] || { echo "build.sh: manca $SCHEMA" >&2; exit 3; }
if grep -q '"""#' "$SCHEMA"; then
  echo "build.sh: schema.sql contiene la sequenza \"\"\"# e non si può incorporare" >&2
  exit 3
fi

# 1. Schema incorporato: si riscrive solo se cambia, così due build in parallelo non si pestano.
TMP_SCHEMA="$(mktemp "${TMPDIR:-/tmp}/lancillotto-schema.XXXXXX")"
{
  printf '// SchemaIncorporato.swift: generato da build.sh a partire da schema.sql. Non modificare a mano.\n\n'
  printf 'let schemaSQL = #"""\n'
  cat "$SCHEMA"
  printf '"""#\n'
} > "$TMP_SCHEMA"
if [[ -f "$INCORPORATO" ]] && cmp -s "$TMP_SCHEMA" "$INCORPORATO"; then
  rm -f "$TMP_SCHEMA"
else
  mv "$TMP_SCHEMA" "$INCORPORATO"
fi

if ((VELENO)); then
  USCITA="$QUI/build-veleno"
  IDENTIFICATORE="org.stellakamikaze.lancillotto.veleno"
  OPZIONI=(-D VELENO)
else
  USCITA="$QUI/build"
  IDENTIFICATORE="org.stellakamikaze.lancillotto"
  OPZIONI=()
fi

if ((UNIVERSALE)); then
  ARCHITETTURE=(arm64 x86_64)
else
  ARCHITETTURE=("$(uname -m)")
fi

mkdir -p "$USCITA/obj"
SORGENTI=("$QUI"/Sorgenti/*.swift)
BINARI=()
for arch in "${ARCHITETTURE[@]}"; do
  out="$USCITA/obj/Lancillotto-$arch"
  echo "build.sh: compilo $arch ${OPZIONI[*]:-}"
  swiftc -O -wmo -swift-version 5 -module-name Lancillotto \
    -target "$arch-apple-macos13" \
    ${OPZIONI[@]+"${OPZIONI[@]}"} \
    -o "$out" "${SORGENTI[@]}"
  BINARI+=("$out")
done

APP="$USCITA/Lancillotto.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
if ((${#BINARI[@]} > 1)); then
  lipo -create -output "$APP/Contents/MacOS/Lancillotto" "${BINARI[@]}"
else
  cp "${BINARI[0]}" "$APP/Contents/MacOS/Lancillotto"
fi
cp "$QUI/Info.plist" "$APP/Contents/Info.plist"
# I font OFL della famiglia di Arturo (DESIGN.md): li registra Stile.registraFont, solo per il processo.
mkdir -p "$APP/Contents/Resources/Font"
cp "$QUI"/Font/*.woff2 "$QUI/Font/OFL.txt" "$APP/Contents/Resources/Font/"
# L'icona: generata con Codex il 25/10/2026, prompt in Icona/icona-prompt.txt.
cp "$QUI/Icona/Lancillotto.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if ((VELENO)); then
  plutil -replace CFBundleIdentifier -string "$IDENTIFICATORE" "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "Lancillotto VELENO" "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Lancillotto VELENO" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - --identifier "$IDENTIFICATORE" "$APP"
codesign --verify --strict "$APP"
echo "build.sh: pronto $APP ($(lipo -archs "$APP/Contents/MacOS/Lancillotto"))"
