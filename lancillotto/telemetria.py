"""lancillotto telemetria: i dati d'uso che Lancillotto manda a chi lo mantiene, per migliorarlo.

Perché esiste: Lancillotto gira sui Mac di persone che non sanno dire dove si inceppa. Senza un ritorno
chi lo mantiene non vede il passo della guida dove ci si ferma, il permesso che manca, il sensore che si
rompe dopo un aggiornamento di macOS, il browser di cui non legge l'indirizzo.

Cosa esce, e solo questo: un id di installazione casuale e stabile, la versione di Lancillotto, la versione
di macOS (macos-NN) e gli eventi di EVENTI con il solo giorno. I numeri escono in fasce (FASCE), mai
esatti. Mai app, siti, titoli, nomi di file, testo, campi o percorsi: il registro resta sul Mac. L'id è
casuale, ma chi mantiene Lancillotto può sapere chi c'è dietro se conosce la persona: non sono dati anonimi.
Il server è quello di Arturo (server/lancillotto.js), che li tiene in una tabella loro per 12 mesi e non
salva l'IP.

Si spegne con `lancillotto telemetria spegni`, con "telemetria": false in impostazioni.json (lo scrive la
finestra), con LANCILLOTTO_TELEMETRIA=0 o con lo standard DO_NOT_TRACK=1. Spegnerla cancella la coda.
`lancillotto telemetria mostra` fa vedere l'id e la coda: si vede esattamente cosa parte.

Due tempi, come in Arturo: `registra` aggiunge una riga alla coda senza rete; `invia` la manda in lotti.
Il registratore Swift non ha funzioni di rete: ogni ora lancia `lancillotto telemetria invia`, che prima
aggiunge i numeri del giorno (una volta al giorno) e poi spedisce.
Questo è l'unico modulo del pacchetto che usa la rete (tests/python/test_varie.py lo controlla).
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import platform
import re
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from . import VERSIONE, impostazioni, percorsi

URL = "https://arturo-dati.stellakamikaze.org/v1/lancillotto/eventi"
CODA_MASSIMA = 2000
LOTTO = 500
SPENTI = {"0", "no", "off", "false", "spenta"}

_BROWSER = ("com.apple.Safari|com.apple.SafariTechnologyPreview|com.google.Chrome|com.google.Chrome.canary|"
            "company.thebrowser.Browser|com.brave.Browser|com.microsoft.edgemac|org.mozilla.firefox|"
            "org.chromium.Chromium|com.vivaldi.Vivaldi|com.operasoftware.Opera").replace(".", r"\.")
_SENSORI = "app|ax|input|schermo|ocr|testo|file|appunti|avvio_login|menu"
_VERBI = ("stato|oggi|giorno|settimana|routine|episodi|episodio|catene|cerca|conta|verifica|testo|conferma|rifiuta|"
          "automatizzata|rivedi|mostra|raggiungo|pausa|riprendi|escludi|dimentica|cancella-tutto|telemetria|aggiorna|"
          "precedenti|analizza")

# L'elenco chiuso, uguale a EVENTI_LANCILLOTTO in arturo/server/lancillotto.js (caso L03 del server).
EVENTI = {
    "installa": r"^(nuova|aggiorna|migrata)$",
    "guida": r"^(benvenuto|accessibilita|testo|schermo|telemetria|fatto):(ok|saltato|si|no)$",
    "permesso": r"^(ax|schermo):(si|no)$",
    "impostazione": r"^(testo|valori|telemetria):(si|no)$",
    "giorno": r"^(eventi|mb|ore):[0-5]$",
    "sensore": r"^(" + _SENSORI + r"):(guasto|degradato)$",
    "url_assente": r"^(" + _BROWSER + r")$",
    "riavvio": r"^[0-9]{1,3}$",
    "costo": r"^(ocr|ax|cpu):[0-4]$",
    "finestra": r"^(oggi|claude|privacy|arturo|guida)$",
    "comando": r"^(" + _VERBI + r")$",
    "routine": r"^(proposte:[0-9]{1,2}|confermata|rifiutata|automatizzata)$",
    "errore": r"^(cli|registro|analisi|invio|permessi|avvio)$",
    "aggiorna": r"^(applicato|binario|nessuno|bloccato|fallito)$",
}
_REGOLE = {k: re.compile(v) for k, v in EVENTI.items()}

# Le soglie delle fasce: il valore è l'indice della prima soglia che il numero non raggiunge.
FASCE = {
    "eventi": (1, 100, 1000, 5000, 20000),
    "mb": (1, 5, 20, 50, 100),
    "ore": (0.01, 1, 3, 6, 9),
    "ocr": (200, 500, 1000, 2000),
    "ax": (20, 50, 100, 200),
}


def fascia(tipo: str, n: float) -> int:
    for i, soglia in enumerate(FASCE[tipo]):
        if n < soglia:
            return i
    return len(FASCE[tipo])


def _stato_file() -> Path:
    return percorsi.cartella_dati() / "telemetria.json"


def _coda() -> Path:
    return percorsi.cartella_dati() / "telemetria-coda.jsonl"


@contextlib.contextmanager
def _chiave():
    """Un solo processo alla volta su coda e stato: l'app lancia più CLI insieme (25/10/2026: due
    registra in parallelo hanno lasciato una riga a metà nella coda)."""
    p = percorsi.cartella_dati() / "telemetria.lock"
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _leggi_stato() -> dict:
    try:
        d = json.loads(_stato_file().read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _scrivi(p: Path, testo: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".nuovo")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(testo)
    os.chmod(tmp, 0o600)
    os.replace(tmp, p)


def _salva_stato(d: dict) -> None:
    _scrivi(_stato_file(), json.dumps(d, ensure_ascii=False, indent=2))


def installazione() -> str:
    d = _leggi_stato()
    i = d.get("id")
    if not (isinstance(i, str) and re.fullmatch(r"[A-Za-z0-9-]{8,64}", i)):
        i = str(uuid.uuid4())
        d["id"] = i
        _salva_stato(d)
    return i


def perche_spenta():
    """Il motivo per cui la telemetria è spenta, o None se è accesa."""
    if os.environ.get("LANCILLOTTO_TELEMETRIA", "").strip().lower() in SPENTI:
        return "LANCILLOTTO_TELEMETRIA=0"
    dnt = os.environ.get("DO_NOT_TRACK", "").strip()
    if dnt and dnt != "0":
        return "DO_NOT_TRACK"
    if impostazioni.leggi().get("telemetria") is False:
        return "spenta da te"
    return None


def _url():
    scelto = os.environ.get("LANCILLOTTO_TELEMETRIA_URL", "").strip()
    if scelto:
        return scelto
    # Un registro di prova (test, scenario sintetico) non manda niente al server vero. L'app passa sempre
    # LANCILLOTTO_DIR alla CLI: conta solo se punta altrove dalla cartella vera.
    if os.environ.get("LANCILLOTTO_HOME_TEST", "").strip():
        return None
    vera = Path.home() / "Library" / "Application Support" / "Lancillotto"
    try:
        if percorsi.cartella_dati().resolve() != vera.resolve():
            return None
    except OSError:
        return None
    return URL


def sistema() -> str:
    v = platform.mac_ver()[0] or "0"
    return "macos-%02d" % int(v.split(".")[0] or 0)


def valido(evento: str, valore: str) -> bool:
    r = _REGOLE.get(evento)
    return bool(r and isinstance(valore, str) and r.fullmatch(valore))


def registra(evento: str, valore: str = "", giorno: str = None) -> bool:
    """Una riga in coda, senza rete. Un evento fuori elenco o la telemetria spenta: niente, in silenzio."""
    try:
        if perche_spenta() or not valido(evento, valore):
            return False
        with _chiave():
            p = _coda()
            righe = p.read_text(encoding="utf-8").splitlines() if p.exists() else []
            if len(righe) >= CODA_MASSIMA:
                return False
            riga = {"giorno": giorno or time.strftime("%Y-%m-%d"), "evento": evento, "valore": valore}
            righe.append(json.dumps(riga, ensure_ascii=False))
            _scrivi(p, "\n".join(righe) + "\n")
        return True
    except OSError:
        return False


def _numeri_del_giorno() -> list:
    """Gli eventi del giorno: permessi, fasce, sensori, browser senza indirizzo, costi, impostazioni."""
    from . import registro as reg_mod
    from . import uscita
    out = []
    imp = impostazioni.leggi()
    out.append(("impostazione", "testo:" + ("si" if imp.get("testo_schermo") else "no")))
    out.append(("impostazione", "valori:" + ("si" if imp.get("valori_campi") else "no")))
    reg = reg_mod.apri()
    if reg is None:
        return out
    try:
        m = reg_mod.meta(reg)
        out.append(("permesso", "ax:" + ("si" if m.get("permesso_ax") == "1" else "no")))
        out.append(("permesso", "schermo:" + ("si" if m.get("permesso_schermo") == "1" else "no")))
        inizio = int(time.mktime(time.strptime(time.strftime("%Y-%m-%d"), "%Y-%m-%d")) * 1000)
        n = reg.execute("SELECT COUNT(*) FROM evento WHERE ts >= ?", (inizio,)).fetchone()[0]
        out.append(("giorno", "eventi:%d" % fascia("eventi", n)))
        peso = 0
        for nome in ("registro.sqlite", "registro.sqlite-wal"):
            try:
                peso += (percorsi.cartella_dati() / nome).stat().st_size
            except OSError:
                pass
        out.append(("giorno", "mb:%d" % fascia("mb", peso / 1048576.0)))
        try:
            from . import analisi
            from .pseudonimi import Pseudonimi
            analisi.analizza()
            an = analisi.apri()
            try:
                g = uscita.giorno(reg, an, Pseudonimi(an), uscita.oggi_str())
                an.commit()
            finally:
                an.close()
            out.append(("giorno", "ore:%d" % fascia("ore", (g.get("attivo_min") or 0) / 60.0)))
        except Exception:
            out.append(("errore", "analisi"))
        for r in reg.execute("SELECT sensore, stato, dettaglio FROM salute WHERE ts >= ?", (inizio,)):
            if r[1] in ("guasto", "degradato") and valido("sensore", "%s:%s" % (r[0], r[1])):
                out.append(("sensore", "%s:%s" % (r[0], r[1])))
            d = r[2] or ""
            if d.startswith("url_assente "):
                out.append(("url_assente", d.split(" ", 1)[1].strip()))
            c = re.search(r"costo medio ax (\d+) ms.*?ocr (\d+) ms", d)
            if c:
                out.append(("costo", "ax:%d" % fascia("ax", int(c.group(1)))))
                out.append(("costo", "ocr:%d" % fascia("ocr", int(c.group(2)))))
        avvii = reg.execute("SELECT COUNT(*) FROM evento WHERE tipo = 'servizio' AND ts >= ? AND dettaglio LIKE '%\"avvio\"%'",
                            (inizio,)).fetchone()[0]
        fermi = reg.execute("SELECT COUNT(*) FROM evento WHERE tipo = 'servizio' AND ts >= ? AND dettaglio LIKE '%\"stop\"%'",
                            (inizio,)).fetchone()[0]
        # Un avvio senza uno stop prima è un'uscita non pulita ripresa da launchd (o un riavvio del Mac).
        out.append(("riavvio", str(max(0, min(999, avvii - fermi - 1)))))
    finally:
        reg.close()
    return list(dict.fromkeys(out))  # senza doppioni, nell'ordine


def giornaliero() -> int:
    """Una volta al giorno: i numeri del giorno in coda. Torna quanti eventi ha aggiunto."""
    d = _leggi_stato()
    oggi = time.strftime("%Y-%m-%d")
    if d.get("ultimo_giorno") == oggi:
        return 0
    n = sum(1 for e, v in _numeri_del_giorno() if registra(e, v))
    d = _leggi_stato()
    d["ultimo_giorno"] = oggi
    _salva_stato(d)
    return n


def invia(forza: bool = False) -> dict:
    """Manda la coda in lotti. 2xx, 400 e 413 la svuotano; un altro errore la lascia per il prossimo giro."""
    motivo = perche_spenta()
    if motivo:
        return {"inviati": 0, "spenta": motivo}
    url = _url()
    if url is None:
        return {"inviati": 0, "motivo": "registro di prova"}
    giornaliero()
    d = _leggi_stato()
    if not forza and time.time() - float(d.get("ultimo_invio") or 0) < 3000:
        return {"inviati": 0, "motivo": "inviato da meno di un'ora"}
    with _chiave():
        return _invia_coda(url)


def _invia_coda(url: str) -> dict:
    p = _coda()
    righe = [r for r in (p.read_text(encoding="utf-8").splitlines() if p.exists() else []) if r.strip()]
    inviati = 0
    while righe:
        lotto = []
        for r in righe[:LOTTO]:
            try:
                lotto.append(json.loads(r))
            except ValueError:
                pass
        corpo = json.dumps({"installazione": installazione(), "versione": VERSIONE, "sistema": sistema(),
                            "eventi": lotto}).encode("utf-8")
        # Lo user-agent di default (Python-urllib) Cloudflare lo blocca con l'errore 1010.
        intestazioni = {"content-type": "application/json", "user-agent": "Lancillotto/" + VERSIONE}
        req = urllib.request.Request(url, data=corpo, method="POST", headers=intestazioni)
        try:
            with urllib.request.urlopen(req, timeout=15) as risposta:
                stato = risposta.status
        except urllib.error.HTTPError as e:
            stato = e.code
        except (urllib.error.URLError, OSError):
            break
        if not (200 <= stato < 300 or stato in (400, 413)):
            break
        inviati += len(lotto) if 200 <= stato < 300 else 0
        righe = righe[LOTTO:]
        _scrivi(p, "".join(r + "\n" for r in righe))
    d = _leggi_stato()
    d["ultimo_invio"] = time.time()
    _salva_stato(d)
    return {"inviati": inviati, "in_coda": len(righe)}


def spegni() -> None:
    impostazioni.aggiorna(telemetria=False)
    with _chiave():
        try:
            _coda().unlink()
        except OSError:
            pass


def accendi() -> None:
    impostazioni.aggiorna(telemetria=True)


def mostra() -> dict:
    p = _coda()
    righe = []
    for r in (p.read_text(encoding="utf-8").splitlines() if p.exists() else []):
        try:
            righe.append(json.loads(r))
        except ValueError:
            pass
    return {"accesa": perche_spenta() is None, "perche_spenta": perche_spenta(), "installazione": _leggi_stato().get("id"),
            "versione": VERSIONE, "sistema": sistema(), "server": URL, "in_coda": righe}
