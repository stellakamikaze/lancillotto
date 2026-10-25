#!/usr/bin/env bash
# installa.sh: installa Lancillotto su questo Mac.
#
# USO
#   ./installa.sh                  installa (o completa un'installazione già fatta)
#   ./installa.sh --solo-verifica  fa tutti i controlli e dice cosa farebbe, senza scrivere niente
#   ./installa.sh --aggiorna       ricompila e sostituisce l'app già installata
#
# Lanciarlo due volte non fa danni: ogni passo già fatto viene saltato.
# Non chiede la password di amministratore e non tocca file di sistema.

set -euo pipefail

RADICE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_ID="org.stellakamikaze.lancillotto"
APP_BUILD="$RADICE/registratore/build/Lancillotto.app"
APP_DEST="$HOME/Applications/Lancillotto.app"
DATI="${LANCILLOTTO_DIR:-$HOME/Library/Application Support/Lancillotto}"
CLI_SRC="$RADICE/bin/lancillotto"
SKILL_SRC="$RADICE/skill"

SOLO_VERIFICA=0
AGGIORNA=0
for arg in "$@"; do
  case "$arg" in
    --solo-verifica) SOLO_VERIFICA=1 ;;
    --aggiorna) AGGIORNA=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Opzione sconosciuta: $arg"; echo "Opzioni: --solo-verifica, --aggiorna"; exit 2 ;;
  esac
done

ok()     { printf '  [ok] %s\n' "$1"; }
nota()   { printf '  [!]  %s\n' "$1"; }
farei()  { printf '  [prova] farei: %s\n' "$1"; }
titolo() { printf '\n%s\n' "$1"; }
ferma()  { printf '\n%s\n' "$1"; exit 1; }

if ((SOLO_VERIFICA)); then
  echo "Lancillotto: controllo senza installare niente."
else
  echo "Lancillotto: installazione."
fi

# --- 1. sistema -----------------------------------------------------------------
titolo "1. Controllo il Mac"

[[ "$(uname -s)" == Darwin ]] || ferma "Lancillotto funziona solo su macOS."

VERSIONE_MAC="$(sw_vers -productVersion 2>/dev/null || echo 0)"
MAGGIORE="${VERSIONE_MAC%%.*}"
if ! [[ "$MAGGIORE" =~ ^[0-9]+$ ]] || ((MAGGIORE < 13)); then
  ferma "Questo Mac ha macOS $VERSIONE_MAC. Lancillotto vuole macOS 13 (Ventura) o più nuovo."
fi
ok "macOS $VERSIONE_MAC"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  ok "processore Apple (arm64)" ;;
  x86_64) ok "processore Intel (x86_64)" ;;
  *) ferma "Processore $ARCH non previsto: Lancillotto conosce solo arm64 e x86_64." ;;
esac

# Gli strumenti per compilare. Se mancano, xcode-select -p fallisce: in quel caso
# non chiamiamo swiftc, che aprirebbe da solo una finestra di installazione.
STRUMENTI_OK=1
if ! xcode-select -p >/dev/null 2>&1; then
  STRUMENTI_OK=0
elif ! command -v swiftc >/dev/null 2>&1 || ! swiftc --version >/dev/null 2>&1; then
  STRUMENTI_OK=0
fi
if ((STRUMENTI_OK == 0)); then
  cat <<'FINE'

Mancano gli strumenti di Apple per compilare (Command Line Tools).
Sono gratuiti e sono gli stessi che danno git e python3.

Per installarli:
  1. scrivi nel Terminale:  xcode-select --install
  2. premi "Installa" nella finestra che si apre e aspetta la fine (5-15 minuti);
  3. lancia di nuovo questo installatore.
FINE
  exit 0
fi
ok "strumenti di Apple presenti ($(swiftc --version 2>&1 | head -n 1))"

if command -v fdesetup >/dev/null 2>&1; then
  FV="$(fdesetup status 2>/dev/null || true)"
  case "$FV" in
    *"FileVault is On"*) ok "FileVault acceso: il disco è cifrato" ;;
    *"FileVault is Off"*)
      nota "FileVault è spento: il registro resta leggibile da chi prende il disco. Puoi accenderlo in Impostazioni di Sistema > Privacy e sicurezza > FileVault." ;;
    *) nota "Non riesco a leggere lo stato di FileVault. Lo puoi vedere in Impostazioni di Sistema > Privacy e sicurezza." ;;
  esac
fi

# --- 1b. il nome di prima ------------------------------------------------------
# Fino al 25/10/2026 Lancillotto si chiamava Ancillotto. Se ne trova una copia, la spegne,
# porta i suoi dati nella cartella nuova (con la chiave, così gli pseudonimi restano uguali)
# e toglie app, avvio al login, collegamenti e permessi vecchi.
VECCHIO_ID="org.stellakamikaze.ancillotto"
VECCHIA_APP="$HOME/Applications/Ancillotto.app"
VECCHI_DATI="$HOME/Library/Application Support/Ancillotto"
VECCHIO_AGENTE="$HOME/Library/LaunchAgents/$VECCHIO_ID.plist"
conta_eventi() { sqlite3 -readonly "$1/registro.sqlite" "SELECT count(*) FROM evento" 2>/dev/null || echo "?"; }

if [[ -e "$VECCHIA_APP" || -f "$VECCHIO_AGENTE" || -d "$VECCHI_DATI" ]]; then
  titolo "1b. Trovo l'Ancillotto, il nome di prima di Lancillotto, e lo sostituisco"
  if ((SOLO_VERIFICA)); then
    farei "fermare l'Ancillotto, spostare i suoi dati in $DATI e togliere app, avvio e collegamenti vecchi"
  else
    launchctl bootout "gui/$(id -u)/$VECCHIO_ID" >/dev/null 2>&1 || true
    rm -f "$VECCHIO_AGENTE"
    osascript -e "tell application id \"$VECCHIO_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do pgrep -x Ancillotto >/dev/null 2>&1 || break; sleep 1; done
    pkill -x Ancillotto >/dev/null 2>&1 || true
    if [[ -d "$VECCHI_DATI" && ! -e "$DATI" ]]; then
      PRIMA="$(conta_eventi "$VECCHI_DATI")"
      mkdir -p "$(dirname "$DATI")"
      mv "$VECCHI_DATI" "$DATI"
      DOPO="$(conta_eventi "$DATI")"
      [[ "$PRIMA" == "$DOPO" ]] || ferma "Lo spostamento dei dati non torna ($PRIMA eventi prima, $DOPO dopo). I file sono in $DATI: non cancellare niente e chiedi aiuto."
      ok "dati spostati in $DATI ($DOPO eventi)"
      MIGRATA=1
      # L'Ancillotto leggeva sempre il testo delle finestre: chi arriva da lì lo tiene acceso.
      /usr/bin/python3 - "$DATI/impostazioni.json" <<'PY' && ok "testo delle finestre lasciato acceso, come prima"
import json, os, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
if "testo_schermo" not in d:
    d["testo_schermo"] = True
    t = p + ".nuovo"
    with open(t, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
    os.chmod(t, 0o600)
    os.replace(t, p)
PY
    elif [[ -d "$VECCHI_DATI" ]]; then
      nota "ci sono sia $VECCHI_DATI sia $DATI: tengo la cartella nuova e lascio la vecchia dov'è"
    fi
    if [[ -d "$VECCHIA_APP" ]]; then
      VID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$VECCHIA_APP/Contents/Info.plist" 2>/dev/null || true)"
      if [[ "$VID" == "$VECCHIO_ID" ]]; then rm -rf "$VECCHIA_APP"; ok "tolta l'app vecchia"; fi
    fi
    for L in "$HOME/.local/bin/ancillotto" "$HOME/bin/ancillotto" "$HOME/.claude/skills/ancillotto"; do
      [[ -L "$L" ]] && rm -f "$L"
    done
    tccutil reset Accessibility "$VECCHIO_ID" >/dev/null 2>&1 || true
    tccutil reset ScreenCapture "$VECCHIO_ID" >/dev/null 2>&1 || true
    ok "l'Ancillotto non c'è più: da qui in avanti è Lancillotto"
  fi
fi

# --- 2. compilazione -----------------------------------------------------------
titolo "2. Compilo l'app"

APP_PRESENTE=0
[[ -d "$APP_DEST" ]] && APP_PRESENTE=1

if [[ ! -f "$RADICE/registratore/build.sh" ]]; then
  if ((SOLO_VERIFICA)); then
    nota "manca registratore/build.sh: così l'installazione vera si fermerebbe qui"
  else
    ferma "Manca registratore/build.sh: la cartella di Lancillotto è incompleta. Scaricala di nuovo."
  fi
fi

DA_COMPILARE=0
if ((AGGIORNA)) || ((APP_PRESENTE == 0)); then
  DA_COMPILARE=1
fi

if ((DA_COMPILARE == 0)); then
  ok "l'app è già installata: non la ricompilo (per una versione nuova usa --aggiorna)"
elif ((SOLO_VERIFICA)); then
  farei "bash registratore/build.sh (compilazione per $ARCH, circa un minuto)"
else
  echo "  Compilo. Ci vuole circa un minuto."
  if ! bash "$RADICE/registratore/build.sh"; then
    ferma "La compilazione non è riuscita. Il messaggio di errore è qui sopra: mandalo a chi ti ha dato Lancillotto."
  fi
  [[ -x "$APP_BUILD/Contents/MacOS/Lancillotto" ]] || ferma "La compilazione non ha prodotto l'app in registratore/build/."
  if ! codesign --verify --strict "$APP_BUILD" >/dev/null 2>&1; then
    ferma "L'app compilata non ha una firma valida. Rilancia l'installatore; se succede ancora, chiedi aiuto."
  fi
  ok "app compilata e firmata in locale"
fi

# --- 3. app in ~/Applications ---------------------------------------------------
titolo "3. Metto l'app nella tua cartella Applicazioni"

app_in_esecuzione() { pgrep -x Lancillotto >/dev/null 2>&1; }

chiudi_app() {
  # Prima fuori da launchd: con KeepAlive un pkill (uscita non pulita) lo farebbe ripartire
  # mentre l'app viene sostituita. Il passo 7 lo ricarica.
  launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
  app_in_esecuzione || return 0
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5; do
    app_in_esecuzione || return 0
    sleep 1
  done
  pkill -x Lancillotto >/dev/null 2>&1 || true
}

if ((DA_COMPILARE == 0)); then
  ok "già in $APP_DEST"
elif ((SOLO_VERIFICA)); then
  if ((APP_PRESENTE)); then
    farei "chiudere Lancillotto e sostituire $APP_DEST"
  else
    farei "creare ~/Applications se manca e copiare l'app in $APP_DEST"
  fi
else
  mkdir -p "$HOME/Applications"
  NUOVA="$HOME/Applications/.Lancillotto.app.nuova"
  rm -rf "$NUOVA"
  ditto "$APP_BUILD" "$NUOVA"
  if ((APP_PRESENTE)); then
    chiudi_app
    rm -rf "$APP_DEST"
  fi
  mv "$NUOVA" "$APP_DEST"
  ok "app in $APP_DEST"
fi

# --- 4. cartella dati -----------------------------------------------------------
titolo "4. Preparo la cartella dove Lancillotto annota"

if [[ -d "$DATI" ]]; then
  PERMESSI="$(stat -f '%Lp' "$DATI")"
  if [[ "$PERMESSI" == 700 ]]; then
    ok "cartella già pronta: $DATI"
  elif ((SOLO_VERIFICA)); then
    farei "rendere privata la cartella $DATI (permessi 700, ora $PERMESSI)"
  else
    chmod 700 "$DATI"
    ok "cartella resa privata: $DATI"
  fi
elif ((SOLO_VERIFICA)); then
  farei "creare la cartella privata $DATI (permessi 700)"
else
  mkdir -p "$DATI"
  chmod 700 "$DATI"
  ok "cartella creata: $DATI"
fi

if ((SOLO_VERIFICA)); then
  farei "escludere la cartella da Time Machine (tmutil addexclusion)"
elif tmutil addexclusion "$DATI" >/dev/null 2>&1; then
  ok "cartella esclusa da Time Machine"
else
  nota "non riesco a escludere la cartella da Time Machine: se usi Time Machine, il registro finisce nei backup"
fi

# --- 5. comando lancillotto ------------------------------------------------------
titolo "5. Collego il comando lancillotto"

nel_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

if nel_path "$HOME/.local/bin"; then
  CLI_DIR="$HOME/.local/bin"
elif nel_path "$HOME/bin"; then
  CLI_DIR="$HOME/bin"
else
  CLI_DIR="$HOME/.local/bin"
fi
CLI_DEST="$CLI_DIR/lancillotto"

# vero se il percorso è dentro una copia di Lancillotto (ha bin/lancillotto e skill/SKILL.md)
copia_lancillotto() { # destinazione del collegamento: .../bin/lancillotto oppure .../skill
  local p="$1" radice
  for radice in "$(dirname "$p")" "$(dirname "$(dirname "$p")")"; do
    [[ -f "$radice/bin/lancillotto" && -f "$radice/skill/SKILL.md" ]] && return 0
  done
  return 1
}

# collega SRC in DEST solo se DEST manca, è già nostro, è un nostro collegamento rotto,
# oppure (con --aggiorna) punta a un'altra copia di Lancillotto
collega() { # sorgente destinazione nome
  local src="$1" dest="$2" nome="$3" ora=""
  if [[ -L "$dest" ]]; then
    ora="$(readlink "$dest")"
    if [[ "$ora" == "$src" ]]; then
      ok "$nome: collegamento già a posto ($dest)"
      return 0
    fi
    if [[ ! -e "$dest" && "$ora" == *lancillotto* ]]; then
      if ((SOLO_VERIFICA)); then
        farei "rifare il collegamento rotto $dest (puntava a $ora)"
      else
        ln -sfn "$src" "$dest"
        ok "$nome: collegamento rifatto ($dest)"
      fi
      return 0
    fi
    if copia_lancillotto "$ora"; then
      if ((AGGIORNA)); then
        if ((SOLO_VERIFICA)); then
          farei "ricollegare $dest alla copia nuova $src (ora punta alla copia vecchia $ora)"
        else
          ln -sfn "$src" "$dest"
          ok "$nome: ricollegato alla copia nuova (prima puntava a $ora)"
        fi
      else
        nota "$dest punta a un'altra copia di Lancillotto ($ora): non lo tocco."
        echo "       Per usare questa copia rilancia con --aggiorna, oppure scrivi:  rm \"$dest\""
        echo "       e poi rilancia l'installatore."
      fi
      return 0
    fi
    nota "$dest punta già a $ora, che non è una copia di Lancillotto: non lo tocco."
    echo "       Se vuoi sostituirlo, scrivi:  rm \"$dest\"   e poi rilancia l'installatore."
    return 0
  fi
  if [[ -e "$dest" ]]; then
    nota "$dest esiste già e non è un nostro collegamento: non lo tocco."
    return 0
  fi
  if ((SOLO_VERIFICA)); then
    farei "collegare $dest -> $src"
  else
    mkdir -p "$(dirname "$dest")"
    ln -s "$src" "$dest"
    ok "$nome: collegamento creato ($dest)"
  fi
}

if [[ ! -f "$CLI_SRC" ]]; then
  nota "manca bin/lancillotto in questa cartella: salto il comando. L'app registra lo stesso."
else
  [[ -x "$CLI_SRC" ]] || nota "bin/lancillotto non è eseguibile: chi ti ha dato Lancillotto lo deve correggere."
  collega "$CLI_SRC" "$CLI_DEST" "comando lancillotto"
  if ! nel_path "$CLI_DIR"; then
    nota "la cartella $CLI_DIR non è nel PATH: il comando lancillotto non si trova da solo."
    echo "       Per aggiungerla, scrivi nel Terminale:"
    echo "       echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    echo "       Poi chiudi e riapri il Terminale."
  fi
fi

# --- 6. skill per Claude Code ---------------------------------------------------
titolo "6. Collego la skill per Claude Code"

if [[ ! -d "$HOME/.claude" ]]; then
  nota "Claude Code non risulta installato (manca ~/.claude): salto la skill. Rilancia l'installatore dopo."
elif [[ ! -f "$SKILL_SRC/SKILL.md" ]]; then
  nota "manca skill/SKILL.md in questa cartella: salto la skill."
else
  if [[ ! -d "$HOME/.claude/skills" ]]; then
    if ((SOLO_VERIFICA)); then
      farei "creare ~/.claude/skills"
    else
      mkdir -p "$HOME/.claude/skills"
    fi
  fi
  collega "$SKILL_SRC" "$HOME/.claude/skills/lancillotto" "skill lancillotto"
fi

# La telemetria (accesa salvo un no nella finestra): da dove arriva questa installazione. Solo in coda, senza rete.
if ((SOLO_VERIFICA == 0)); then
  if [[ -n "${MIGRATA:-}" ]]; then TIPO_INSTALLA=migrata
  elif ((APP_PRESENTE)); then TIPO_INSTALLA=aggiorna
  else TIPO_INSTALLA=nuova; fi
  "$CLI_SRC" telemetria registra installa "$TIPO_INSTALLA" >/dev/null 2>&1 || true
fi

# --- 7. avvio -------------------------------------------------------------------
titolo "7. Apro Lancillotto"

if ((SOLO_VERIFICA)); then
  farei "aprire $APP_DEST: compare la finestra dei permessi"
  echo
  echo "Controllo finito. Non ho scritto niente."
  exit 0
fi

if ((AGGIORNA && DA_COMPILARE)); then
  # Firma ad-hoc: macOS lega il permesso all'impronta del binario. Su macOS 26 spegnere e
  # riaccendere l'interruttore non aggiorna l'impronta (prova del 25/10/2026): resta "negato"
  # con l'interruttore acceso. Si cancella la voce, e la finestra dei permessi la ricrea.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || nota "voce di Accessibilità non cancellata: toglila con il tasto - nella lista"
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  cat <<'FINE'
  L'app è nuova: macOS la tratta come un'app diversa e il permesso di prima non vale più.
  Ho tolto la voce vecchia. Nella finestra di Lancillotto premi "Apri Accessibilità"
  e accendi Lancillotto nella lista. Poi la finestra ti guida per la Registrazione schermo.
FINE
fi

if app_in_esecuzione && ((DA_COMPILARE == 0)); then
  ok "Lancillotto è già acceso (icona nella barra dei menu in alto)"
else
  # Avvio con launchd: riparte da solo al login e dopo un crash. Se launchd rifiuta, si apre a mano.
  AGENTE="$("$APP_DEST/Contents/MacOS/Lancillotto" --scrivi-avvio-login 2>/dev/null || true)"
  if [[ -n "$AGENTE" && -f "$AGENTE" ]]; then
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$AGENTE" >/dev/null 2>&1; then
      ok "Lancillotto acceso, e si riaccende da solo al login: guarda l'icona nella barra dei menu in alto"
    else
      open "$APP_DEST"
      ok "Lancillotto aperto (si riaccenderà da solo dal prossimo login): guarda la barra dei menu in alto"
    fi
  else
    open "$APP_DEST"
    ok "Lancillotto aperto: guarda l'icona nella barra dei menu in alto"
  fi
fi

cat <<'FINE'

Cosa succede adesso:
  - si apre una finestra che chiede il permesso di Accessibilità: è l'unico obbligatorio.
    Lancillotto annota quale finestra usi, il testo della finestra e il valore dei campi
    quando ne esci, ripuliti da password e codici. Non registra i singoli tasti.
    Per non annotare i valori dei campi: "valori_campi": false in impostazioni.json.
  - macOS mostra la notifica "Elemento in background aggiunto": Lancillotto si riaccende
    da solo quando accendi il Mac e dopo un blocco. È normale. Se lo chiudi con "Esci"
    dal suo menu resta chiuso fino al prossimo accesso.
  - la Registrazione schermo è facoltativa: serve solo a leggere il testo delle app che
    non lo danno in altro modo. macOS la richiede di nuovo ogni mese.

Per vedere se registra:  lancillotto stato
Per chiedere a Claude:   "dove mi puoi aiutare?"
FINE
