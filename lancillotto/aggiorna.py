"""lancillotto aggiorna: porta la copia di Lancillotto all'ultima versione del suo repository.

Perché esiste: Lancillotto gira sui Mac di persone che non aprono il Terminale. Le correzioni devono
arrivare da sole, come in Arturo.

Cosa fa, una volta al giorno (l'app lo lancia con --se-serve dal suo timer orario):
  git fetch del ramo main -> nessuna novità: fine.
  copia con modifiche locali o divergente -> "bloccato", non tocca niente (è la copia di chi sviluppa).
  avanti veloce (git merge --ff-only) -> la CLI e la skill sono già nuove, perché sono collegamenti al repo.
  se è cambiato registratore/ (il binario Swift) -> ./installa.sh --aggiorna in una sessione staccata:
    ricompila, rimette l'app, toglie la voce vecchia dei permessi; al riavvio la guida riapre da sola il
    passo dell'Accessibilità. Succede di rado, perché costa un gesto alla persona.
L'esito va in telemetria (evento "aggiorna"). La rete la usa git, non questo modulo.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

from . import percorsi

RADICE = Path(__file__).resolve().parent.parent
RAMO = "main"


def _git(radice: Path, *argomenti, timeout=60):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="true")
    return subprocess.run(["git", "-C", str(radice)] + list(argomenti), capture_output=True, text=True,
                          timeout=timeout, env=env)


def _stato_file() -> Path:
    return percorsi.cartella_dati() / "aggiorna.json"


def _segna(esito: str, dettaglio: str = "") -> dict:
    out = {"esito": esito, "dettaglio": dettaglio, "quando": time.strftime("%Y-%m-%d %H:%M")}
    try:
        p = _stato_file()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(dict(out, ultimo_controllo=time.time()), ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass
    try:
        from . import telemetria
        telemetria.registra("aggiorna", esito)
    except Exception:
        pass
    return out


def serve() -> bool:
    """Vero se l'ultimo controllo è di più di 20 ore fa."""
    try:
        d = json.loads(_stato_file().read_text(encoding="utf-8"))
        return time.time() - float(d.get("ultimo_controllo") or 0) > 20 * 3600
    except (OSError, ValueError):
        return True


def aggiorna(se_serve: bool = False, installa: bool = True, radice: Path = RADICE) -> dict:
    if se_serve and not serve():
        return {"esito": "rimandato", "dettaglio": "controllato da meno di 20 ore"}
    if not (radice / ".git").exists():
        return _segna("bloccato", "la cartella di Lancillotto non è un repository git")
    try:
        if _git(radice, "fetch", "--quiet", "origin", RAMO).returncode != 0:
            return _segna("fallito", "git fetch non riuscito: rete assente o accesso al repository negato")
        locale = _git(radice, "rev-parse", "HEAD").stdout.strip()
        remoto = _git(radice, "rev-parse", "origin/" + RAMO).stdout.strip()
        if not remoto or locale == remoto:
            return _segna("nessuno", "già all'ultima versione")
        if _git(radice, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            return _segna("bloccato", "ci sono modifiche locali: non aggiorno una copia di sviluppo")
        if _git(radice, "merge-base", "--is-ancestor", "HEAD", "origin/" + RAMO).returncode != 0:
            return _segna("bloccato", "la copia locale ha commit suoi: non aggiorno")
        cambiati = _git(radice, "diff", "--name-only", "HEAD", "origin/" + RAMO).stdout.split()
        if _git(radice, "merge", "--ff-only", "--quiet", "origin/" + RAMO).returncode != 0:
            return _segna("fallito", "git merge --ff-only non riuscito")
    except (OSError, subprocess.TimeoutExpired) as e:
        return _segna("fallito", "git: %s" % e)
    binario = any(c.startswith("registratore/") or c == "installa.sh" for c in cambiati)
    if binario:
        if not installa:  # i test: niente installatore vero
            return _segna("binario", "%d file nuovi, installatore non lanciato" % len(cambiati))
        log = percorsi.cartella_dati() / "aggiorna.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as f:
            # Sessione nuova: l'installatore ferma e riavvia l'app che ci ha lanciato, e non deve portarci con sé.
            subprocess.Popen(["/bin/bash", str(radice / "installa.sh"), "--aggiorna"], cwd=str(radice),
                             stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
        return _segna("binario", "%d file nuovi, ricompilo l'app (poi va ridato il permesso di Accessibilità)" % len(cambiati))
    return _segna("applicato", "%d file nuovi" % len(cambiati))
