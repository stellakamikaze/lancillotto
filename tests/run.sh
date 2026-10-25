#!/usr/bin/env bash
# tests/run.sh: orchestratore unico dei test di Lancillotto.
#
# USO
#   bash tests/run.sh        (da qualunque cartella)
#
# PASSI
#   build            registratore/build.sh, poi controlla il binario prodotto
#   build-veleno     registratore/build.sh --veleno, binario in registratore/build-veleno/
#   banco            gate-run.sh: veleno rosso con "VELENO TROVATO", poi banco.sh verde
#   python-sistema   unittest di tests/python con /usr/bin/python3
#   python3          unittest di tests/python con python3 del PATH
#   integrazione     scenario sintetico Swift letto dalla CLI Python (analizza, routine, oggi,
#                    giorno, catene, cerca)
#   sintassi-bash    bash -n su ogni script .sh e sugli script bash senza estensione in bin/
#   sintassi-python  py_compile con entrambi i python e ast con feature_version 3.8
#
# Ogni passo scrive output ed exit code su file; l'esito si legge dal file, mai da una pipe.
# Un componente che non esiste ancora dà FAIL "manca X", senza fermare gli altri passi.
# Nessun passo avvia l'app in modo normale né scrive nella cartella dati reale:
# LANCILLOTTO_DIR punta sempre a una cartella temporanea.
#
# EXIT: 0 se tutti i passi sono PASS, 1 se almeno uno è FAIL.

set -uo pipefail

RADICE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_RUN="${GATE_RUN:-$HOME/.claude/scripts/gate-run.sh}"
APP_BIN="$RADICE/registratore/build/Lancillotto.app/Contents/MacOS/Lancillotto"
VELENO_BIN="$RADICE/registratore/build-veleno/Lancillotto.app/Contents/MacOS/Lancillotto"
CLI="$RADICE/bin/lancillotto"
BUILD="$RADICE/registratore/build.sh"
BANCO="$RADICE/registratore/banco.sh"
PY_SISTEMA=/usr/bin/python3
PY3="$(command -v python3 || true)"

LAVORO="$(mktemp -d "${TMPDIR:-/tmp}/lancillotto-test.XXXXXX")" || { echo "mktemp fallito"; exit 1; }
export LANCILLOTTO_DIR="$LAVORO/dati-vuoti"   # rete di sicurezza per ogni comando lanciato da qui
mkdir -p "$LANCILLOTTO_DIR"
export PYTHONDONTWRITEBYTECODE=1

NOMI=() ESITI=() NOTE=()

registra() { # nome esito nota
  NOMI+=("$1"); ESITI+=("$2"); NOTE+=("$3")
  printf '%-16s %s  %s\n' "$1" "$2" "$3"
}

# vero se il passo NOME è già registrato come PASS (un binario vecchio non basta)
passato() { # nome
  local i
  for i in "${!NOMI[@]}"; do
    [[ "${NOMI[$i]}" == "$1" && "${ESITI[$i]}" == PASS ]] && return 0
  done
  return 1
}

# esegue un comando, output e exit code su file
esegui() { # nome cmd...
  local nome="$1"; shift
  "$@" >"$LAVORO/$nome.log" 2>&1 </dev/null
  printf '%s\n' "$?" >"$LAVORO/$nome.rc"
}
rc_di() { # nome
  local v=""
  [[ -s "$LAVORO/$1.rc" ]] && v="$(<"$LAVORO/$1.rc")"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '999'
}
coda_log() { # nome
  [[ -f "$LAVORO/$1.log" ]] && tail -n 12 "$LAVORO/$1.log" | sed 's/^/    | /'
}

echo "Lancillotto, test in $RADICE"
echo "log dei passi in $LAVORO"
echo

# --- build ---------------------------------------------------------------------
passo_build() { # nome binario [argomenti di build.sh]
  local nome="$1" bin="$2"; shift 2
  if [[ ! -f "$BUILD" ]]; then
    registra "$nome" FAIL "manca registratore/build.sh"; return
  fi
  esegui "$nome" bash "$BUILD" "$@"
  local rc; rc="$(rc_di "$nome")"
  if [[ "$rc" != 0 ]]; then
    registra "$nome" FAIL "build.sh $* esce $rc"; coda_log "$nome"; return
  fi
  if [[ ! -x "$bin" ]]; then
    registra "$nome" FAIL "manca il binario ${bin#"$RADICE"/}"; return
  fi
  registra "$nome" PASS "${bin#"$RADICE"/}"
}
passo_build build "$APP_BIN"
passo_build build-veleno "$VELENO_BIN" --veleno

# --- banco con veleno ----------------------------------------------------------
passo_banco() {
  local manca=""
  [[ -x "$GATE_RUN" ]] || manca="$GATE_RUN"
  [[ -f "$BANCO" ]] || manca="registratore/banco.sh"
  passato build || manca="il binario normale (passo build)"
  passato build-veleno || manca="il binario veleno (passo build-veleno)"
  if [[ -n "$manca" ]]; then registra banco FAIL "manca $manca"; return; fi
  # gate-run.sh boccia i file cambiati nella cartella corrente durante il veleno:
  # lo lanciamo da una cartella vuota, con path assoluti.
  local quieta="$LAVORO/quieta"
  mkdir -p "$quieta"
  local veleno; veleno="bash $(printf '%q' "$BANCO") $(printf '%q' "$VELENO_BIN")"
  ( cd "$quieta" && "$GATE_RUN" --poison "$veleno" --expect 'VELENO TROVATO' --pass 'BANCO VERDE' \
      --source "$BANCO" -- bash "$BANCO" "$APP_BIN" ) >"$LAVORO/banco.log" 2>&1 </dev/null
  printf '%s\n' "$?" >"$LAVORO/banco.rc"
  local rc; rc="$(rc_di banco)"
  case "$rc" in
    0) registra banco PASS "veleno rosso con VELENO TROVATO, banco verde" ;;
    1) registra banco FAIL "banco rosso sul binario normale"; coda_log banco ;;
    2) registra banco FAIL "il veleno non boccia per il motivo atteso"; coda_log banco ;;
    *) registra banco FAIL "gate-run guasto (exit $rc)"; coda_log banco ;;
  esac
}
passo_banco

# --- unittest Python -----------------------------------------------------------
passo_unittest() { # nome interprete
  local nome="$1" py="$2"
  if [[ -z "$py" || ! -x "$py" ]]; then registra "$nome" FAIL "manca l'interprete ${py:-python3}"; return; fi
  if [[ ! -d "$RADICE/tests/python" ]]; then registra "$nome" FAIL "manca tests/python"; return; fi
  if [[ ! -d "$RADICE/lancillotto" ]]; then registra "$nome" FAIL "manca il pacchetto lancillotto/"; return; fi
  ( cd "$RADICE" && PYTHONPATH="$RADICE" "$py" -m unittest discover -s tests/python -p 'test*.py' ) \
    >"$LAVORO/$nome.log" 2>&1 </dev/null
  printf '%s\n' "$?" >"$LAVORO/$nome.rc"
  local rc; rc="$(rc_di "$nome")"
  local ran; ran="$(grep -Eo '^Ran [0-9]+ test' "$LAVORO/$nome.log" | tail -n 1 | grep -Eo '[0-9]+')"
  local versione; versione="$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  if [[ -z "$ran" || "$ran" == 0 ]]; then
    registra "$nome" FAIL "nessun test trovato in tests/python (Python $versione)"; return
  fi
  if [[ "$rc" != 0 ]]; then
    registra "$nome" FAIL "$ran test, exit $rc (Python $versione)"; coda_log "$nome"; return
  fi
  registra "$nome" PASS "$ran test verdi (Python $versione)"
}
passo_unittest python-sistema "$PY_SISTEMA"
passo_unittest python3 "$PY3"

# --- integrazione Swift -> Python ----------------------------------------------
passo_integrazione() {
  if ! passato build; then registra integrazione FAIL "manca il binario normale (passo build)"; return; fi
  if [[ ! -f "$CLI" ]]; then registra integrazione FAIL "manca bin/lancillotto"; return; fi
  local dati="$LAVORO/integrazione-dati"
  mkdir -p "$dati"; chmod 700 "$dati"
  local cli=("$CLI")
  [[ -x "$CLI" ]] || cli=("${PY3:-$PY_SISTEMA}" "$CLI")

  esegui int-scenario env LANCILLOTTO_DIR="$dati" "$APP_BIN" --scenario-sintetico
  if [[ "$(rc_di int-scenario)" != 0 ]]; then
    registra integrazione FAIL "--scenario-sintetico esce $(rc_di int-scenario)"; coda_log int-scenario; return
  fi
  esegui int-analizza env LANCILLOTTO_DIR="$dati" "${cli[@]}" analizza
  if [[ "$(rc_di int-analizza)" != 0 ]]; then
    registra integrazione FAIL "lancillotto analizza esce $(rc_di int-analizza)"; coda_log int-analizza; return
  fi
  # lo scenario scrive il 20, 21 e 22/10/2026 in ora locale: 'giorno' e 'catene' guardano il 20
  local uscite=(routine "routine --json" oggi "oggi --json" giorno "giorno 2026-10-20 --json"
                catene "catene --giorno 2026-10-20 --tipo file --json" cerca "cerca Pagamento --json")
  local k nome
  for ((k = 0; k < ${#uscite[@]}; k += 2)); do
    nome="${uscite[$k]}"
    # shellcheck disable=SC2086
    env LANCILLOTTO_DIR="$dati" "${cli[@]}" ${uscite[$((k + 1))]} >"$LAVORO/int-$nome.json" 2>"$LAVORO/int-$nome.err" </dev/null
    printf '%s\n' "$?" >"$LAVORO/int-$nome.rc"
    if [[ "$(rc_di "int-$nome")" != 0 ]]; then
      registra integrazione FAIL "lancillotto ${uscite[$((k + 1))]} esce $(rc_di "int-$nome")"
      tail -n 12 "$LAVORO/int-$nome.err" | sed 's/^/    | /'; return
    fi
  done

  "${PY3:-$PY_SISTEMA}" -I -c '
import json, re, sys
routine_p, oggi_p, giorno_p, catene_p, cerca_p = sys.argv[1:6]
veleni = ["IT60X0542811101000000123456", "Cassaforte Personale", "Segreta123!Veleno", "VELENOTOKEN",
          "frammento", "VELENOCHIAVE", "VelenoPrivato", "VelenoBanca", "portale.fornitore-esempio.it"]
problemi = []
def carica(p, nome):
    try:
        with open(p, encoding="utf-8") as f:
            testo = f.read()
        return testo, json.loads(testo)
    except (OSError, ValueError) as e:
        problemi.append("%s non è JSON valido: %s" % (nome, e))
        return "", None
def stringhe(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for k, v in x.items():
            yield str(k)
            for s in stringhe(v):
                yield s
    elif isinstance(x, list):
        for v in x:
            for s in stringhe(v):
                yield s
r_testo, r_json = carica(routine_p, "routine --json")
o_testo, o_json = carica(oggi_p, "oggi --json")
g_testo, g_json = carica(giorno_p, "giorno --json")
c_testo, c_json = carica(catene_p, "catene --json")
s_testo, s_json = carica(cerca_p, "cerca --json")
catena = re.compile(r"Mail\b.*>.*Anteprima\b.*>.*Chrome\b")
if r_json is not None:
    trovate = [r for r in r_json.get("routine") or [] if catena.search(r.get("schema") or "")]
    if not trovate:
        problemi.append("routine --json non contiene la routine Mail > Anteprima > Chrome")
    elif not any((r.get("legami_tra_app") or 0) > 0 for r in trovate):
        problemi.append("routine Mail > Anteprima > Chrome senza legami degli appunti fra app")
if c_json is not None:
    archi = {(c.get("da"), c.get("a")) for c in c_json.get("catene") or []}
    if ("File:scarica:pdf", "Anteprima:apri:pdf") not in archi:
        problemi.append("catene --json senza il file scaricato aperto in Anteprima: %s" % sorted(archi))
if s_json is not None and not s_json.get("schermo"):
    problemi.append("cerca non trova la riga di schermo \"Pagamento a 30 giorni\"")
# niente path completi né URL in uscita: solo nomi brevi, estensioni e domini pseudonimi
completi = re.compile(r"(/Users/|/Library/|/private/|https?://|file://)")
uscite = (("oggi --json", o_testo), ("routine --json", r_testo), ("giorno --json", g_testo),
          ("catene --json", c_testo), ("cerca --json", s_testo))
for nome, testo in uscite:
    for v in veleni:
        if v in testo:
            problemi.append("VELENO TROVATO in %s: %s" % (nome, v))
    m = completi.search(testo)
    if m:
        problemi.append("path o URL completo in %s: %s" % (nome, testo[max(0, m.start() - 20):m.end() + 40]))
for p in problemi:
    print(p)
print("routine: %d byte, oggi: %d byte, giorno: %d byte" % (len(r_testo), len(o_testo), len(g_testo)))
sys.exit(1 if problemi else 0)
' "$LAVORO/int-routine.json" "$LAVORO/int-oggi.json" "$LAVORO/int-giorno.json" "$LAVORO/int-catene.json" \
    "$LAVORO/int-cerca.json" >"$LAVORO/int-controllo.log" 2>&1 </dev/null
  printf '%s\n' "$?" >"$LAVORO/int-controllo.rc"
  if [[ "$(rc_di int-controllo)" != 0 ]]; then
    registra integrazione FAIL "$(head -n 1 "$LAVORO/int-controllo.log")"; coda_log int-controllo; return
  fi
  registra integrazione PASS "routine Mail > Anteprima > Chrome con legami, catena del download, cerca sullo schermo, nessun veleno né path"
}
passo_integrazione

# --- sintassi bash -------------------------------------------------------------
passo_sintassi_bash() {
  local script=() f
  while IFS= read -r f; do script+=("$f"); done < <(
    find "$RADICE" \( -name .git -o -name build -o -name build-veleno \) -prune -o -type f -name '*.sh' -print | sort)
  if [[ -d "$RADICE/bin" ]]; then
    for f in "$RADICE"/bin/*; do
      [[ -f "$f" ]] && head -n 1 "$f" | grep -Eq '^#!.*(ba)?sh' && script+=("$f")
    done
  fi
  local attesi=(installa.sh disinstalla.sh registratore/banco.sh tests/run.sh registratore/build.sh)
  local mancanti=() a
  for a in "${attesi[@]}"; do [[ -f "$RADICE/$a" ]] || mancanti+=("$a"); done
  local rotti=()
  for f in "${script[@]}"; do
    bash -n "$f" >"$LAVORO/sintassi-bash.log" 2>&1
    printf '%s\n' "$?" >"$LAVORO/sintassi-bash.rc"
    [[ "$(rc_di sintassi-bash)" == 0 ]] || rotti+=("${f#"$RADICE"/}")
  done
  if ((${#rotti[@]})); then
    registra sintassi-bash FAIL "bash -n rosso su: ${rotti[*]}"; return
  fi
  if ((${#mancanti[@]})); then
    registra sintassi-bash FAIL "${#script[@]} script ok, manca ${mancanti[*]}"; return
  fi
  registra sintassi-bash PASS "${#script[@]} script"
}
passo_sintassi_bash

# --- sintassi Python -----------------------------------------------------------
passo_sintassi_python() {
  local file=() f
  while IFS= read -r f; do file+=("$f"); done < <(
    find "$RADICE/lancillotto" "$RADICE/tests" -type f -name '*.py' 2>/dev/null | sort)
  [[ -f "$CLI" ]] && file+=("$CLI")
  if ((${#file[@]} == 0)); then registra sintassi-python FAIL "manca il codice Python (lancillotto/, bin/lancillotto)"; return; fi
  local py rc errori=""
  for py in "$PY_SISTEMA" "$PY3"; do
    [[ -n "$py" && -x "$py" ]] || continue
    "$py" -I -c '
import ast, os, py_compile, sys, tempfile
cartella = tempfile.mkdtemp()
male = []
for i, p in enumerate(sys.argv[1:]):
    try:
        py_compile.compile(p, cfile=os.path.join(cartella, "%d.pyc" % i), doraise=True)
    except py_compile.PyCompileError as e:
        male.append("%s: %s" % (p, e.msg.strip().splitlines()[-1]))
        continue
    with open(p, encoding="utf-8") as f:
        src = f.read()
    try:
        ast.parse(src, filename=p, feature_version=(3, 8))
    except SyntaxError as e:
        male.append("%s:%s: sintassi oltre Python 3.8 (%s)" % (p, e.lineno, e.msg))
    for n, riga in enumerate(src.splitlines(), 1):
        if ".removeprefix(" in riga or ".removesuffix(" in riga:
            male.append("%s:%d: removeprefix/removesuffix non esiste in Python 3.8" % (p, n))
for m in male:
    print(m)
sys.exit(1 if male else 0)
' "${file[@]}" >"$LAVORO/sintassi-python.log" 2>&1 </dev/null
    printf '%s\n' "$?" >"$LAVORO/sintassi-python.rc"
    rc="$(rc_di sintassi-python)"
    if [[ "$rc" != 0 ]]; then
      local primo pref="$RADICE/"
      primo="$(head -n 1 "$LAVORO/sintassi-python.log")"
      primo="${primo//$pref/}"   # path relativi; senza virgolette per bash 3.2
      errori="$errori $py: $primo;"
    fi
  done
  if [[ -n "$errori" ]]; then registra sintassi-python FAIL "${errori# }"; return; fi
  registra sintassi-python PASS "${#file[@]} file, compatibili con Python 3.8"
}
passo_sintassi_python

# --- tabella finale -------------------------------------------------------------
echo
echo "RIEPILOGO"
printf '%-16s %-5s %s\n' "passo" "esito" "nota"
printf '%-16s %-5s %s\n' "----------------" "-----" "----"
falliti=0
for i in "${!NOMI[@]}"; do
  printf '%-16s %-5s %s\n' "${NOMI[$i]}" "${ESITI[$i]}" "${NOTE[$i]}"
  [[ "${ESITI[$i]}" == PASS ]] || falliti=$((falliti + 1))
done
echo
if ((falliti == 0)); then
  echo "TUTTI VERDI (${#NOMI[@]} passi)"
  rm -rf "$LAVORO"
  exit 0
fi
echo "FALLITI: $falliti su ${#NOMI[@]} passi. Log in $LAVORO"
exit 1
