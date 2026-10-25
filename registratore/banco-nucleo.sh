#!/usr/bin/env bash
# banco-nucleo.sh: banco del nucleo del registratore, con il veleno prima (gate-run.sh, A22).
#
# USO
#   bash registratore/banco-nucleo.sh            build vera e VELENO, selftest, veleni, rete
#   bash registratore/banco-nucleo.sh controlla BINARIO [--tutti]
#        lancia BINARIO --scenario-sintetico in una cartella temporanea e cerca i veleni in
#        ogni byte dei file del registro e nei testi compressi (testo_z, valore_z).
#        Senza --tutti: "PULITO" (exit 0) se nessun veleno c'è e le invarianti dello scenario
#        reggono, altrimenti "VELENO TROVATO: ..." (exit 1).
#        Con --tutti: "VELENO TROVATO 8/8" (exit 1) solo se compaiono tutti e otto.
#
# Non avvia mai l'app in modo normale e non scrive nella cartella dati reale.

set -euo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON:-/usr/bin/python3}"

controlla() {
  local binario="$1" modo="${2:-}"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/lancillotto-banco.XXXXXX")"
  local esito
  esito="$(LANCILLOTTO_DIR="$dir" "$binario" --scenario-sintetico 2>&1)" || {
    echo "GUASTO: lo scenario non parte: $esito"; rm -rf "$dir"; return 3; }
  case "$esito" in
    "SCENARIO OK eventi="*) echo "$esito" ;;
    *) echo "GUASTO: uscita inattesa: $esito"; rm -rf "$dir"; return 3 ;;
  esac
  local rc=0
  "$PY" -I - "$dir" "$modo" <<'PYEOF' || rc=$?
import os, sqlite3, sys, zlib

cartella, modo = sys.argv[1], sys.argv[2]
VELENI = ["IT60X0542811101000000123456", "Cassaforte Personale", "Segreta123!Veleno", "VELENOTOKEN",
          "frammento", "VELENOCHIAVE", "VelenoPrivato", "VelenoBanca"]
trovati = {}
# 1. Ogni byte di ogni file della cartella (registro, -wal, -shm, impostazioni, chiave).
for nome in sorted(os.listdir(cartella)):
    with open(os.path.join(cartella, nome), "rb") as f:
        dati = f.read()
    for v in VELENI:
        if v.encode() in dati:
            trovati.setdefault(v, []).append(nome)
# 2. I testi compressi, decompressi come fa Python (DEFLATE raw).
db = os.path.join(cartella, "registro.sqlite")
con = sqlite3.connect(db)
testi = [zlib.decompress(b, -15).decode("utf-8") for (b,) in con.execute("SELECT testo_z FROM riga")]
testi += [zlib.decompress(b, -15).decode("utf-8") for (b,) in con.execute("SELECT valore_z FROM campo WHERE valore_z IS NOT NULL")]
for t in testi:
    for v in VELENI:
        if v in t:
            trovati.setdefault(v, []).append("testo compresso")
uno = lambda sql: con.execute(sql).fetchone()[0]
invarianti = {
    "incolla cmd+v": (uno("SELECT COUNT(*) FROM evento WHERE tipo='comando' AND dettaglio LIKE '%cmd+v%' AND cc IS NOT NULL"), 72),
    "appunti": (uno("SELECT COUNT(*) FROM evento WHERE tipo='appunti'"), 72),
    "campo_focus Importo": (uno("SELECT COUNT(*) FROM evento WHERE tipo='campo_focus' AND dettaglio LIKE '%Importo%'"), 72),
    "campo_valore Importo": (uno("SELECT COUNT(*) FROM campo WHERE etichetta='Importo'"), 1),
    "allegati mail": (uno("SELECT COUNT(DISTINCT o.id) FROM evento e JOIN oggetto o ON o.id=e.ogg_id WHERE e.tipo='documento' AND o.cartella='mail_allegati'"), 12),
    "file_sposta": (uno("SELECT COUNT(*) FROM evento WHERE tipo='file_sposta' AND dettaglio LIKE '%\"da\"%'"), 3),
    "provenienza": (uno("SELECT COUNT(*) FROM oggetto WHERE provenienza='mail.google.com'"), 2 * 3),
    "giorni": (uno("SELECT COUNT(*) FROM giorno"), 3),
    "iban redatto": (uno("SELECT COUNT(*) FROM oggetto WHERE etichetta LIKE '%[IBAN#%'"), 1),
}
valore = con.execute("SELECT valore_z FROM campo WHERE etichetta='Importo'").fetchone()
con.close()
if modo == "--tutti":
    n = len(trovati)
    print("veleni trovati: " + ", ".join(sorted(trovati)) if trovati else "nessun veleno trovato")
    if n == len(VELENI):
        print("VELENO TROVATO %d/%d" % (n, len(VELENI)))
        sys.exit(1)
    print("VELENO PARZIALE %d/%d: mancano %s" % (n, len(VELENI), [v for v in VELENI if v not in trovati]))
    sys.exit(0)
rotte = ["%s: %s invece di %s" % (k, a, b) for k, (a, b) in invarianti.items() if a != b]
if valore is None or zlib.decompress(valore[0], -15).decode() != "1.234,56":
    rotte.append("valore Importo non leggibile come 1.234,56")
for v, dove in sorted(trovati.items()):
    print("VELENO TROVATO: %s in %s" % (v, sorted(set(dove))))
for r in rotte:
    print("INVARIANTE ROTTA: " + r)
if trovati or rotte:
    sys.exit(1)
print("invarianti dello scenario: %d su %d" % (len(invarianti) + 1, len(invarianti) + 1))
print("PULITO")
PYEOF
  rm -rf "$dir"
  return "$rc"
}

if [[ "${1:-}" == "controlla" ]]; then
  shift
  controlla "$@"
  exit $?
fi

VERO="$QUI/build/Lancillotto.app/Contents/MacOS/Lancillotto"
VEL="$QUI/build-veleno/Lancillotto.app/Contents/MacOS/Lancillotto"

echo "== build"
bash "$QUI/build.sh"
bash "$QUI/build.sh" --veleno

echo "== selftest (veleno prima: sulla build VELENO deve fallire)"
"$HOME/.claude/scripts/gate-run.sh" \
  --poison "'$VEL' --selftest" --expect "SELFTEST FALLITO" --pass "SELFTEST OK" \
  --source "$VERO" -- "$VERO" --selftest

echo "== veleni nello scenario sintetico"
"$HOME/.claude/scripts/gate-run.sh" \
  --poison "bash '$QUI/banco-nucleo.sh' controlla '$VEL' --tutti" --expect "VELENO TROVATO 8/8" --pass "PULITO" \
  --source "$VERO" -- bash "$QUI/banco-nucleo.sh" controlla "$VERO"

echo "== nessun simbolo di rete (nm -u)"
for b in "$VERO" "$VEL"; do
  simboli="$(nm -u "$b")"
  if grep -E '^(_socket|_connect|_getaddrinfo)$|_NSURLSession|^_nw_|_CFSocket' <<<"$simboli"; then
    echo "RETE TROVATA in $b"
    exit 1
  fi
  echo "nessun simbolo di rete in $b ($(wc -l <<<"$simboli" | tr -d ' ') simboli importati)"
done
echo "BANCO NUCLEO VERDE"
