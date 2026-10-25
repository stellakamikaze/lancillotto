#!/usr/bin/env bash
# banco.sh: controlla un binario di Lancillotto senza avviarlo in modo normale.
#
# USO
#   registratore/banco.sh [BINARIO]
#
#   BINARIO  path del binario. Default: registratore/build/Lancillotto.app/Contents/MacOS/Lancillotto.
#            Un path relativo vale prima rispetto alla cartella corrente, poi rispetto al repo.
#
# CONTROLLI (tutti, anche dopo il primo rosso, così il motivo del rosso è completo)
#   1. nm -u: nessun simbolo di rete (_socket, _connect, _NSURLSession, URLSession, _nw_,
#      _CFSocket, _getaddrinfo, _CFStream).
#   2. otool -L: nessun Network.framework né CFNetwork.
#   3. --selftest esce 0.
#   4. --scenario-sintetico in una cartella temporanea (LANCILLOTTO_DIR) esce 0 e scrive un registro.
#      Poi cerca i VELENI in tutti i byte dei file della cartella e nei testi decompressi
#      (DEFLATE raw, zlib.decompress(b, -15)) di riga.testo_z, campo.valore_z e di ogni altro BLOB.
#   5. La cartella dati reale (~/Library/Application Support/Lancillotto) non cambia. Se Lancillotto
#      installato è acceso, il confronto si salta: la cartella cambia da sola.
#
#   Il binario non parte mai in modo normale: niente permessi, niente finestre, niente AX.
#   Il controllo lsof sul processo vivo (PIANO) non sta qui: richiede l'app avviata davvero.
#
# USCITA
#   "BANCO VERDE" ed exit 0, oppure "BANCO ROSSO: <motivi>" ed exit 1.
#   Un veleno trovato stampa anche "VELENO TROVATO: <parola>".
#   Con LANCILLOTTO_BANCO_TIENI=1 la cartella temporanea resta per l'ispezione.

set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RADICE="$(cd "$QUI/.." && pwd)"

VELENI=(
  "IT60X0542811101000000123456"
  "Cassaforte Personale"
  "Segreta123!Veleno"
  "VELENOTOKEN"
  "frammento"
  "VELENOCHIAVE"
  "VelenoPrivato"
  "VelenoBanca"
  "BANCAVELENO"
  "SCHEDAVELENO"
  "MENUVELENO"
  "QUERYVELENO"
  "PWDVELENO"
  "FILEVELENO"
  "BANCAURLVELENO"
  "PRIVATAVELENO"
  "ENVVELENO"
)

PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || PYTHON=/usr/bin/python3

# --- binario ---------------------------------------------------------------
BIN="${1:-registratore/build/Lancillotto.app/Contents/MacOS/Lancillotto}"
if [[ "$BIN" != /* ]]; then
  if [[ -e "$PWD/$BIN" ]]; then
    BIN="$PWD/$BIN"
  else
    BIN="$RADICE/$BIN"
  fi
fi

if [[ ! -f "$BIN" ]]; then
  echo "BANCO ROSSO: manca il binario $BIN (lancia prima registratore/build.sh)"
  exit 1
fi
if [[ ! -x "$BIN" ]]; then
  echo "BANCO ROSSO: il binario $BIN non è eseguibile"
  exit 1
fi

LAVORO="$(mktemp -d "${TMPDIR:-/tmp}/lancillotto-banco.XXXXXX")" || { echo "BANCO ROSSO: mktemp fallito"; exit 1; }
pulisci() {
  if [[ "${LANCILLOTTO_BANCO_TIENI:-0}" == 1 ]]; then
    echo "cartella del banco tenuta: $LAVORO"
  else
    rm -rf "$LAVORO"
  fi
}
trap pulisci EXIT

MOTIVI=()
RETE=0   # 1 se il binario importa funzioni di rete: allora non lo eseguiamo
rosso() { MOTIVI+=("$1"); echo "  ROSSO: $1"; }

# esegue un comando con tetto di secondi; scrive output e exit code su file, senza pipe
con_tetto() { # secondi out rcfile cmd...
  local sec="$1" out="$2" rcf="$3"; shift 3
  perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$sec" "$@" >"$out" 2>&1 </dev/null
  printf '%s\n' "$?" >"$rcf"
}
leggi_rc() { local v=""; [[ -s "$1" ]] && v="$(<"$1")"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '999'; }

echo "banco su $BIN"

# --- 5 (prima parte). stato della cartella dati reale ----------------------
REALE="$HOME/Library/Application Support/Lancillotto"
impronta_reale() {
  if [[ -e "$REALE" ]]; then
    find "$REALE" -maxdepth 1 -exec stat -f '%N %m %z' {} + 2>/dev/null | sort
  else
    echo "assente"
  fi
}
REALE_PRIMA="$(impronta_reale)"

# --- 1. simboli di rete ------------------------------------------------------
echo "1. simboli importati (nm -u)"
NM_OUT="$LAVORO/nm.txt" NM_RC="$LAVORO/nm.rc"
con_tetto 60 "$NM_OUT" "$NM_RC" nm -u "$BIN"
if [[ "$(leggi_rc "$NM_RC")" != 0 ]]; then
  rosso "nm -u fallito (exit $(leggi_rc "$NM_RC"))"
else
  trovati="$(grep -E '(^|[[:space:]])_(socket|connect|connectx|getaddrinfo)$|_NSURLSession|URLSession|(^|[[:space:]])_nw_|_CFSocket|_CFStream' "$NM_OUT" | sort -u | head -10 | tr '\n' ' ')"
  if [[ -n "$trovati" ]]; then
    rosso "simboli di rete nel binario: ${trovati% }"
    RETE=1
  else
    echo "  ok: nessun simbolo di rete su $(grep -c . "$NM_OUT") simboli"
  fi
fi

# --- 2. librerie collegate ---------------------------------------------------
echo "2. librerie collegate (otool -L)"
OT_OUT="$LAVORO/otool.txt" OT_RC="$LAVORO/otool.rc"
con_tetto 60 "$OT_OUT" "$OT_RC" otool -L "$BIN"
if [[ "$(leggi_rc "$OT_RC")" != 0 ]]; then
  rosso "otool -L fallito (exit $(leggi_rc "$OT_RC"))"
else
  trovati="$(grep -E 'Network\.framework|CFNetwork' "$OT_OUT" | sed 's/^[[:space:]]*//' | tr '\n' ' ')"
  if [[ -n "$trovati" ]]; then
    rosso "framework di rete collegati: $trovati"
  else
    echo "  ok: nessun framework di rete"
  fi
fi

# un binario con funzioni di rete non si esegue: potrebbe collegarsi davvero
if ((RETE)); then
  echo "3-4. salto --selftest e --scenario-sintetico: il binario importa funzioni di rete"
  elenco="$(printf '%s; ' "${MOTIVI[@]}")"
  echo "BANCO ROSSO: ${elenco%; }"
  exit 1
fi

# --- 3. selftest ---------------------------------------------------------------
echo "3. --selftest"
mkdir -p "$LAVORO/selftest-dati"
ST_OUT="$LAVORO/selftest.txt" ST_RC="$LAVORO/selftest.rc"
con_tetto 120 "$ST_OUT" "$ST_RC" env LANCILLOTTO_DIR="$LAVORO/selftest-dati" "$BIN" --selftest
st_rc="$(leggi_rc "$ST_RC")"
if [[ "$st_rc" != 0 ]]; then
  rosso "--selftest esce $st_rc"
  tail -n 15 "$ST_OUT" | sed 's/^/    | /'
else
  echo "  ok: $(tail -n 1 "$ST_OUT")"
fi

# --- 4. scenario sintetico e veleni ---------------------------------------
echo "4. --scenario-sintetico e ricerca dei veleni"
DATI="$LAVORO/dati"
mkdir -p "$DATI"
chmod 700 "$DATI"
SC_OUT="$LAVORO/scenario.txt" SC_RC="$LAVORO/scenario.rc"
con_tetto 300 "$SC_OUT" "$SC_RC" env LANCILLOTTO_DIR="$DATI" "$BIN" --scenario-sintetico
sc_rc="$(leggi_rc "$SC_RC")"
if [[ "$sc_rc" != 0 ]]; then
  rosso "--scenario-sintetico esce $sc_rc"
  tail -n 15 "$SC_OUT" | sed 's/^/    | /'
fi
if [[ ! -s "$DATI/registro.sqlite" ]]; then
  rosso "lo scenario non ha scritto $DATI/registro.sqlite"
fi

# la ricerca gira anche se lo scenario è rosso: un veleno scritto prima del guasto conta
VEL_OUT="$LAVORO/veleni.txt" VEL_RC="$LAVORO/veleni.rc"
con_tetto 120 "$VEL_OUT" "$VEL_RC" "$PYTHON" -I -c '
import os, sqlite3, sys, zlib
cartella = sys.argv[1]
veleni = sys.argv[2:]
trovati = {}
def segna(parola, dove):
    trovati.setdefault(parola, []).append(dove)
def cerca(testo_b, dove):
    for v in veleni:
        if v.encode("utf-8") in testo_b:
            segna(v, dove)
# 1. tutti i byte di tutti i file
nfile = 0
for base, _, nomi in os.walk(cartella):
    for n in nomi:
        p = os.path.join(base, n)
        try:
            with open(p, "rb") as f:
                b = f.read()
        except OSError as e:
            print("file illeggibile: %s (%s)" % (p, e))
            continue
        nfile += 1
        cerca(b, "byte di " + os.path.relpath(p, cartella))
# 2. testi compressi dentro il registro
reg = os.path.join(cartella, "registro.sqlite")
nblob = 0
if os.path.exists(reg):
    try:
        con = sqlite3.connect(reg)
        tabelle = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type=\"table\"")]
        for t in tabelle:
            colonne = [r[1] for r in con.execute("PRAGMA table_info(\"%s\")" % t)]
            for c in colonne:
                for (val,) in con.execute("SELECT \"%s\" FROM \"%s\" WHERE typeof(\"%s\")=\"blob\"" % (c, t, c)):
                    nblob += 1
                    for wbits in (-15, 15):
                        try:
                            cerca(zlib.decompress(val, wbits), "%s.%s decompresso" % (t, c))
                            break
                        except zlib.error:
                            pass
                    cerca(bytes(val), "%s.%s grezzo" % (t, c))
        con.close()
    except sqlite3.Error as e:
        print("registro illeggibile: %s" % e)
        sys.exit(2)
print("file letti: %d, blob letti: %d" % (nfile, nblob))
for v in veleni:
    if v in trovati:
        print("VELENO TROVATO: %s (in %s)" % (v, ", ".join(sorted(set(trovati[v]))[:4])))
sys.exit(1 if trovati else 0)
' "$DATI" "${VELENI[@]}"
vel_rc="$(leggi_rc "$VEL_RC")"
sed 's/^/  /' "$VEL_OUT"
case "$vel_rc" in
  0) echo "  ok: nessun veleno" ;;
  1) rosso "veleni nel registro: $(grep -c '^VELENO TROVATO' "$VEL_OUT")" ;;
  *) rosso "ricerca dei veleni guasta (exit $vel_rc)" ;;
esac

# --- 5. cartella dati reale invariata --------------------------------------
echo "5. cartella dati reale"
REALE_DOPO="$(impronta_reale)"
# Un Lancillotto installato e acceso scrive nella cartella reale ogni pochi secondi: il confronto non
# distingue le sue scritture da quelle del binario provato. Allora vale il passo 4, che vuole il registro
# dentro LANCILLOTTO_DIR.
if pgrep -x Lancillotto >/dev/null 2>&1; then
  echo "  saltato: Lancillotto installato è acceso e scrive qui da solo (LANCILLOTTO_DIR provata dal passo 4)"
elif [[ "$REALE_PRIMA" != "$REALE_DOPO" ]]; then
  rosso "il binario ha toccato la cartella dati reale $REALE: LANCILLOTTO_DIR ignorata"
else
  echo "  ok: invariata"
fi

# --- esito ---------------------------------------------------------------------
if ((${#MOTIVI[@]} == 0)); then
  echo "BANCO VERDE"
  exit 0
fi
elenco="$(printf '%s; ' "${MOTIVI[@]}")"
echo "BANCO ROSSO: ${elenco%; }"
exit 1
