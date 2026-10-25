"""Allowlist e segnaposto stabili: ciò che di un titolo, un dominio o un'app può uscire.

Regola (docs/PIANO.md, "Uscita verso Claude"): nei titoli escono solo le parole del vocabolario
generico it/en (lancillotto/vocabolario.txt, più quello della persona nella cartella dati);
ogni altra parola diventa [P#], con un numero stabile per hash. I domini pubblici noti
(lancillotto/domini_pubblici.txt) escono in chiaro, gli altri diventano [SITO_n]. Le app fuori
elenco diventano [APP_n]. La tabella alias resta in analisi.sqlite e non esce mai.
"""
from __future__ import annotations

import functools
import hashlib
import hmac
import re
from pathlib import Path

from . import percorsi

QUI = Path(__file__).resolve().parent
FILE_VOCABOLARIO = QUI / "vocabolario.txt"
FILE_DOMINI = QUI / "domini_pubblici.txt"

# Nome breve e stabile per i bundle più comuni: lo stesso in ogni simbolo.
NOMI_APP = {
    "com.apple.mail": "Mail",
    "com.apple.Preview": "Anteprima",
    "com.apple.Safari": "Safari",
    "com.google.Chrome": "Chrome",
    "com.google.Chrome.canary": "Chrome",
    "company.thebrowser.Browser": "Arc",
    "org.mozilla.firefox": "Firefox",
    "com.microsoft.edgemac": "Edge",
    "com.brave.Browser": "Brave",
    "com.vivaldi.Vivaldi": "Vivaldi",
    "com.operasoftware.Opera": "Opera",
    "com.apple.finder": "Finder",
    "com.apple.iCal": "Calendario",
    "com.apple.Notes": "Note",
    "com.apple.reminders": "Promemoria",
    "com.apple.TextEdit": "TextEdit",
    "com.apple.iWork.Pages": "Pages",
    "com.apple.iWork.Numbers": "Numbers",
    "com.apple.iWork.Keynote": "Keynote",
    "com.apple.Terminal": "Terminale",
    "com.apple.systempreferences": "Impostazioni",
    "com.apple.Photos": "Foto",
    "com.apple.AddressBook": "Contatti",
    "com.microsoft.Excel": "Excel",
    "com.microsoft.Word": "Word",
    "com.microsoft.Powerpoint": "PowerPoint",
    "com.microsoft.Outlook": "Outlook",
    "com.microsoft.teams2": "Teams",
    "com.microsoft.teams": "Teams",
    "com.tinyspeck.slackmacgap": "Slack",
    "notion.id": "Notion",
    "com.notion.id": "Notion",
    "us.zoom.xos": "Zoom",
    "com.adobe.Reader": "Acrobat",
    "com.adobe.Acrobat.Pro": "Acrobat",
    "com.figma.Desktop": "Figma",
    "com.spotify.client": "Spotify",
    "com.microsoft.VSCode": "VSCode",
    "com.googlecode.iterm2": "iTerm",
    "com.anthropic.claudefordesktop": "Claude",
}

BROWSER = {"com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
           "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac",
           "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"}

SEGNAPOSTO_REDATTORE = re.compile(r"\[(CARTA|IBAN|CF|CHIAVE|JWT|PEM|OTP|PASSWORD)#[0-9a-fA-F]{4}\]")
# Con schema o www, oppure host.tld/percorso senza schema (come la barra indirizzi di Chrome).
URL = re.compile(r"(?i)\b(?:https?://|www\.)\S+|(?<![\w@.\-])(?:[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d{1,5})?/\S*")
PERCORSO = re.compile(r"(?:~|/)(?:[^\s/]+/)+[^\s/]*")
EMAIL = re.compile(r"(?i)\b[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+\b")
PAROLA = re.compile(r"\[(?:CARTA|IBAN|CF|CHIAVE|JWT|PEM|OTP|PASSWORD|URL|PERCORSO|EMAIL)\]|[^\W_]+", re.UNICODE)
SEGNAPOSTO_USCITA = re.compile(r"^\[(?:CARTA|IBAN|CF|CHIAVE|JWT|PEM|OTP|PASSWORD|URL|PERCORSO|EMAIL)\]$")


@functools.lru_cache(maxsize=None)
def _vocabolario_base() -> tuple:
    parole, app = set(), set()
    sezione = "parole"
    for riga in FILE_VOCABOLARIO.read_text(encoding="utf-8").splitlines():
        r = riga.strip()
        if not r or r.startswith("#"):
            continue
        if r == "[app]":
            sezione = "app"
            continue
        if sezione == "app":
            app.add(r.lower())
        else:
            for w in r.lower().split():
                parole.add(w)
    return frozenset(parole), frozenset(app)


def vocabolario() -> tuple:
    """(parole ammesse, nomi di app noti), più le parole che la persona ha aggiunto."""
    parole, app = _vocabolario_base()
    extra = percorsi.vocabolario_persona()
    try:
        righe = extra.read_text(encoding="utf-8").splitlines()
    except OSError:
        return parole, app
    agg = {w.strip().lower() for w in righe if w.strip() and not w.startswith("#")}
    return parole | agg, app


@functools.lru_cache(maxsize=None)
def domini_pubblici() -> frozenset:
    out = set()
    for riga in FILE_DOMINI.read_text(encoding="utf-8").splitlines():
        r = riga.strip().lower()
        if r and not r.startswith("#"):
            out.add(r)
    return frozenset(out)


def parola_ammessa(w: str) -> bool:
    lw = w.lower()
    if SEGNAPOSTO_USCITA.match(w):
        return True
    if lw.isdigit():
        if len(lw) <= 2:
            return True
        return len(lw) == 4 and 1990 <= int(lw) <= 2039
    parole, app = vocabolario()
    return lw in parole or lw in app


def dominio_pubblico(d):
    """Il suffisso pubblico noto più lungo che copre d, oppure None."""
    d = (d or "").lower().strip().strip(".")
    if d.startswith("www."):
        d = d[4:]
    if not d:
        return None
    pubblici = domini_pubblici()
    parti = d.split(".")
    for i in range(len(parti) - 1):
        cand = ".".join(parti[i:])
        if cand in pubblici:
            return cand
    return None


def registrabile(d: str) -> str:
    """Il dominio registrabile (approssimato): ultime due etichette, tre per i suffissi composti."""
    parti = [p for p in (d or "").lower().strip(".").split(".") if p]
    if len(parti) <= 2:
        return ".".join(parti)
    composti = {"co.uk", "com.au", "co.jp", "com.br", "co.it", "gov.it", "edu.it", "org.uk", "ac.uk"}
    if ".".join(parti[-2:]) in composti:
        return ".".join(parti[-3:])
    return ".".join(parti[-2:])


def pulisci(testo: str) -> str:
    """Toglie URL, percorsi ed email, e riduce i segnaposto del redattore al solo tipo."""
    t = SEGNAPOSTO_REDATTORE.sub(lambda m: "[%s]" % m.group(1), testo or "")
    t = URL.sub("[URL]", t)
    t = EMAIL.sub("[EMAIL]", t)
    t = PERCORSO.sub("[PERCORSO]", t)
    return t


def nome_app_canonico(bundle, nome) -> str:
    if bundle and bundle in NOMI_APP:
        return NOMI_APP[bundle]
    return (nome or bundle or "?").strip()


def _hash(tipo: str, valore: str) -> str:
    try:
        k = percorsi.chiave().read_bytes()
    except OSError:
        k = b""
    msg = (tipo + "\u0000" + valore).encode("utf-8")
    if len(k) == 32:
        return hmac.new(k, msg, hashlib.sha256).hexdigest()[:32]
    # Sale col nome di prima della rinomina (25/10/2026): cambiarlo cambierebbe gli pseudonimi.
    return hashlib.sha256(b"ancillotto\x00" + msg).hexdigest()[:32]


class Pseudonimi:
    """Segnaposto stabili, tenuti nella tabella alias di analisi.sqlite."""

    PREFISSI = {"parola": "P", "sito": "SITO_", "app": "APP_"}

    def __init__(self, conn):
        self.conn = conn
        self.cache = {}
        self.prossimo = {}
        for tipo, h, s in conn.execute("SELECT tipo, h, segnaposto FROM alias"):
            self.cache[(tipo, h)] = s
        for tipo in self.PREFISSI:
            n = conn.execute("SELECT COUNT(*) FROM alias WHERE tipo = ?", (tipo,)).fetchone()[0]
            self.prossimo[tipo] = int(n) + 1

    def segnaposto(self, tipo: str, valore: str) -> str:
        h = _hash(tipo, valore)
        s = self.cache.get((tipo, h))
        if s is None:
            s = "[%s%d]" % (self.PREFISSI[tipo], self.prossimo[tipo])
            self.prossimo[tipo] += 1
            self.conn.execute("INSERT OR IGNORE INTO alias(tipo, h, segnaposto) VALUES (?, ?, ?)",
                              (tipo, h, s))
            self.cache[(tipo, h)] = s
        return s

    def parola(self, w: str) -> str:
        if parola_ammessa(w):
            return w
        return self.segnaposto("parola", w.lower())

    def testo(self, s, massimo: int = 160) -> str:
        """Un titolo o un nome file: le parole ammesse restano, le altre diventano [P#]."""
        if not s:
            return ""
        t = pulisci(s)
        out, ultimo = [], 0
        for m in PAROLA.finditer(t):
            sep = t[ultimo:m.start()]
            out.append(re.sub(r"\s+", " ", sep))
            out.append(self.parola(m.group(0)))
            ultimo = m.end()
        out.append(re.sub(r"\s+", " ", t[ultimo:]))
        return "".join(out).strip()[:massimo]

    def parole(self, s) -> list:
        """Le parole di un testo dopo l'allowlist (ammesse o [P#]), in ordine."""
        if not s:
            return []
        return [self.parola(m.group(0)) for m in PAROLA.finditer(pulisci(s))]

    def breve(self, s, massimo: int = 4) -> str:
        """Etichetta per un simbolo: solo parole ammesse, minuscole, unite da trattini."""
        if not s:
            return ""
        ammesse = [m.group(0).lower() for m in PAROLA.finditer(pulisci(s))
                   if parola_ammessa(m.group(0)) and not m.group(0).startswith("[")]
        return "-".join(ammesse[:massimo])

    def sito(self, d) -> str:
        if not d:
            return ""
        pub = dominio_pubblico(d)
        if pub:
            return pub
        return self.segnaposto("sito", registrabile(d))

    def app(self, bundle, nome) -> str:
        if bundle and bundle in NOMI_APP:
            return NOMI_APP[bundle]
        n = nome_app_canonico(bundle, nome)
        parole_ok, app_note = vocabolario()
        if n.lower() in app_note:
            return n
        pezzi = [p for p in re.split(r"[^\w]+", n) if p]
        if pezzi and all(p.lower() in parole_ok or p.lower() in app_note for p in pezzi):
            return n.replace(":", " ")
        return self.segnaposto("app", (bundle or n))
