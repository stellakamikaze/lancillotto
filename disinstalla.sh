#!/usr/bin/env bash
# disinstalla.sh: toglie Lancillotto da questo Mac.
#
# USO
#   ./disinstalla.sh                  toglie l'app, il comando e la skill; chiede se cancellare i dati
#   ./disinstalla.sh --dati           cancella anche i dati, senza chiedere
#   ./disinstalla.sh --solo-verifica  dice cosa farebbe, senza toccare niente
#
# Toglie solo ciò che è suo: un collegamento che punta altrove resta dov'è.

set -euo pipefail

RADICE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="org.stellakamikaze.lancillotto"
APP="$HOME/Applications/Lancillotto.app"
DATI="${LANCILLOTTO_DIR:-$HOME/Library/Application Support/Lancillotto}"
AGENTE="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

CANCELLA_DATI=0
SOLO_VERIFICA=0
for arg in "$@"; do
  case "$arg" in
    --dati) CANCELLA_DATI=1 ;;
    --solo-verifica) SOLO_VERIFICA=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $arg"; echo "Opzioni: --dati, --solo-verifica"; exit 2 ;;
  esac
done

ok()    { printf '  [ok] %s\n' "$1"; }
nota()  { printf '  [!]  %s\n' "$1"; }
farei() { printf '  [prova] farei: %s\n' "$1"; }

echo "Lancillotto: disinstallazione."

# --- 1. avvio automatico ----------------------------------------------------------
# Prima di chiudere l'app: con KeepAlive, launchd la riaprirebbe dopo il pkill.
echo
echo "1. Tolgo l'avvio automatico"
if [[ -f "$AGENTE" ]]; then
  if ((SOLO_VERIFICA)); then
    farei "togliere l'avvio al login $AGENTE"
  else
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -f "$AGENTE"
    ok "avvio al login tolto: $AGENTE"
  fi
else
  ((SOLO_VERIFICA)) || launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
  ok "nessun avvio al login da togliere"
fi

# --- 2. ferma l'app -------------------------------------------------------------
echo
echo "2. Fermo Lancillotto"
if pgrep -x Lancillotto >/dev/null 2>&1; then
  if ((SOLO_VERIFICA)); then
    farei "chiudere Lancillotto"
  else
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x Lancillotto >/dev/null 2>&1 || break
      sleep 1
    done
    pkill -x Lancillotto >/dev/null 2>&1 || true
    sleep 1
    if pgrep -x Lancillotto >/dev/null 2>&1; then
      nota "Lancillotto non si chiude: chiudilo dal suo menu (Esci) e rilancia."
      exit 1
    fi
    ok "Lancillotto fermato"
  fi
else
  ok "Lancillotto era già fermo"
fi

# --- 3. app -------------------------------------------------------------------------
echo
echo "3. Tolgo l'app"
if [[ -d "$APP" ]]; then
  ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$ID" != "$BUNDLE_ID" ]]; then
    nota "$APP non è Lancillotto (identificativo \"$ID\"): non lo tocco."
  elif ((SOLO_VERIFICA)); then
    farei "cancellare $APP"
  else
    rm -rf "$APP"
    ok "app tolta: $APP"
  fi
else
  ok "nessuna app in $APP"
fi

# --- 4. collegamenti --------------------------------------------------------------
echo
echo "4. Tolgo il comando lancillotto e la skill"

# toglie DEST solo se è un collegamento verso questa copia, o un collegamento rotto verso un Lancillotto
togli_collegamento() { # destinazione sorgente-attesa nome
  local dest="$1" src="$2" nome="$3" ora
  [[ -L "$dest" ]] || { [[ -e "$dest" ]] && nota "$dest non è un nostro collegamento: non lo tocco."; return 0; }
  ora="$(readlink "$dest")"
  if [[ "$ora" == "$src" ]] || { [[ ! -e "$dest" ]] && [[ "$ora" == *lancillotto* ]]; }; then
    if ((SOLO_VERIFICA)); then
      farei "togliere $dest"
    else
      rm -f "$dest"
      ok "$nome: collegamento tolto ($dest)"
    fi
  else
    nota "$dest punta a $ora, non a questa copia di Lancillotto: non lo tocco."
  fi
}
togli_collegamento "$HOME/.local/bin/lancillotto" "$RADICE/bin/lancillotto" "comando"
togli_collegamento "$HOME/bin/lancillotto" "$RADICE/bin/lancillotto" "comando"
togli_collegamento "$HOME/.claude/skills/lancillotto" "$RADICE/skill" "skill"

# --- 5. dati ----------------------------------------------------------------------
echo
echo "5. Dati"
if [[ ! -d "$DATI" ]]; then
  ok "nessuna cartella dati in $DATI"
else
  if ((CANCELLA_DATI == 0)) && ((SOLO_VERIFICA == 0)) && [[ -t 0 ]]; then
    printf '  Vuoi cancellare anche il registro (%s)? Non si recupera. [s/N] ' "$DATI"
    read -r risposta || risposta=""
    case "$risposta" in s|S|si|sì|SI|Sì) CANCELLA_DATI=1 ;; esac
  fi
  if ((CANCELLA_DATI)); then
    case "$DATI" in
      ""|"/"|"$HOME"|"$HOME/") nota "cartella dati sospetta ($DATI): non la cancello."; exit 1 ;;
    esac
    if ((SOLO_VERIFICA)); then
      farei "cancellare la cartella dati $DATI"
    else
      tmutil removeexclusion "$DATI" >/dev/null 2>&1 || true
      rm -rf "$DATI"
      ok "dati cancellati: $DATI"
    fi
  else
    ok "i dati restano in $DATI. Per cancellarli dopo: ./disinstalla.sh --dati"
  fi
fi

# --- 6. permessi ------------------------------------------------------------------
echo
echo "6. Permessi di macOS"
echo "  macOS ricorda i permessi dati all'app. Per toglierli del tutto, scrivi nel Terminale:"
echo "    tccutil reset Accessibility $BUNDLE_ID"
echo "    tccutil reset ScreenCapture $BUNDLE_ID"
echo "  Oppure spegni e togli la voce Lancillotto in Impostazioni di Sistema > Privacy e sicurezza."
echo
if ((SOLO_VERIFICA)); then
  echo "Controllo finito. Non ho toccato niente."
else
  echo "Fatto. La cartella dei sorgenti ($RADICE) resta: cancellala a mano se non serve più."
fi
