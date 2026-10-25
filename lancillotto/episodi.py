"""Simboli ed episodi (docs/PROGETTAZIONE.md, sezione 5, punti 1 e 2).

Simbolo: ogni evento diventa "app:azione:tipo". Il tipo è l'estensione, il dominio
pseudonimizzato o il ruolo del campo, mai il nome. Le ripetizioni consecutive si comprimono
("Chrome:incolla:[SITO_2]/campo×6").

Episodio: si taglia su inattività oltre 5 minuti, sonno, blocco o pausa; quando l'oggetto
principale (quello con più tempo nell'episodio) non torna per 10 minuti; dopo 45 minuti senza
ritorno sull'oggetto iniziale. Un lavoro ripreso sullo stesso oggetto entro 2 ore si ricuce.

  eventi ordinati ──> simbolo + ancora (contesto per app: dominio, documento, campo)
        │                 nessun simbolo (schermo, servizio, campo_focus) -> fuori dagli episodi
        │                 file senza un gesto della persona (lo scrive un programma) -> fuori
        v
  segmenta ──> taglio: inattivo>5 min | sonno | blocco | pausa | buco>5 min
        │      taglio: principale assente da 10 min -> il nuovo episodio parte dal primo
        │              oggetto nuovo dopo l'ultima visita del principale
        │      taglio: oggetto iniziale assente da 45 min
        v
  ricuci ──> due episodi consecutivi con lo stesso principale e meno di 2 ore fra loro
"""
from __future__ import annotations

from . import pseudonimi

INATTIVITA_MS = 5 * 60000
RITORNO_MS = 10 * 60000
SENZA_RITORNO_MS = 45 * 60000
RICUCITURA_MS = 2 * 3600000
TETTO_DUR_MS = 5 * 60000
APP_FILE = "File"
APP_ESCLUSA = "[esclusa]"

COMANDI = {
    "cmd+c": "copia", "cmd+x": "taglia", "cmd+v": "incolla", "shift+cmd+v": "incolla",
    "opt+shift+cmd+v": "incolla", "cmd+s": "salva", "shift+cmd+s": "salva_come",
    "cmd+z": "annulla", "shift+cmd+z": "ripeti", "cmd+a": "seleziona_tutto", "cmd+f": "cerca",
    "cmd+n": "nuovo", "cmd+t": "nuova_scheda", "cmd+w": "chiudi", "cmd+p": "stampa",
    "cmd+o": "apri", "cmd+r": "ricarica", "cmd+l": "indirizzo", "cmd+return": "invia",
    "cmd+enter": "invia", "shift+cmd+d": "invia", "cmd+q": "esci", "cmd+e": "esporta",
}
COMANDI_SALTATI = {"cmd+tab", "shift+cmd+tab", "cmd+`", "shift+cmd+`", "cmd+space", "ctrl+space"}
COPIA = {"copia", "taglia"}
VOCI_MENU = {
    "copia": "copia", "copy": "copia", "taglia": "taglia", "cut": "taglia",
    "incolla": "incolla", "paste": "incolla", "incolla e adatta stile": "incolla",
    "paste and match style": "incolla", "incolla stile": "incolla",
}
TAGLI = {"sonno", "blocco", "pausa"}
# Un evento sui file è un gesto della persona se arriva entro 10 s da un suo gesto sui file: un
# comando, menu o clic nel Finder, oppure salva, salva con nome, esporta o una voce di menu in
# un'altra app che non è un terminale. Gli altri li scrivono i programmi (cache, .pyc, font,
# preferenze, database, Claude Code dal Terminale) e non entrano negli episodi. Il download resta sempre.
GESTO_FILE_MS = 10000
FINDER = "com.apple.finder"
SALVA = {"salva", "salva_come", "esporta"}
TERMINALI = {"com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
             "io.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm"}


def voce_menu(percorso: str) -> str:
    ultima = (percorso or "").split(">")[-1].strip().lower()
    return ultima.replace("…", "").replace("...", "").strip()


def azione_comando(ev: dict):
    """L'azione di un comando o di una voce di menu di copia e incolla, oppure None."""
    if ev["tipo"] == "comando":
        return COMANDI.get(str(ev["det"].get("tasti", "")).lower())
    if ev["tipo"] == "menu":
        voce = voce_menu(str(ev["det"].get("percorso", "")))
        if voce in VOCI_MENU:
            return VOCI_MENU[voce]
        # "Incolla speciale", "Paste Special", "Incolla e mantieni formattazione": come il
        # registratore (SensoreMenu.èIncolla), ogni voce che comincia così è un incolla
        if voce.startswith("incolla") or voce.startswith("paste"):
            return "incolla"
    return None


def e_incolla(ev: dict) -> bool:
    return azione_comando(ev) == "incolla"


def e_copia(ev: dict) -> bool:
    return azione_comando(ev) in COPIA


def ruolo_breve(ruolo) -> str:
    r = str(ruolo or "").strip()
    if r.startswith("AX"):
        r = r[2:]
    return r.lower() or "campo"


class Contesto:
    """Ciò che serve per dare un tipo ai simboli: per ogni app dominio, documento e campo."""

    def __init__(self, ps):
        self.ps = ps
        self.dominio = {}      # app_id -> dominio grezzo
        self.documento = {}    # app_id -> (inode o chiave_h, ext)
        self.campo = {}        # app_id -> True se c'è un campo a fuoco
        self.primo_piano = None
        self.ultima_copia = {}  # app_id -> ts dell'ultimo comando di copia
        self.ultima_copia_ts = None  # ts dell'ultimo comando di copia, in qualunque app
        self.ultimo_input = {}  # app_id -> ts dell'ultimo comando, menu o clic
        self.ultimo_gesto_file = None  # ts dell'ultimo gesto della persona sui file (gesto_della_persona)
        self.ultimo_ogg = {}   # (app_id, tipo) -> (oggetto, ts) dell'ultimo documento o URL

    def ritorno(self, ev, chiave) -> bool:
        """Vero se l'app torna sullo stesso documento o URL entro 10 minuti. Il registratore
        ripete documento e url a ogni ritorno sull'app (docs/CONTRATTO.md): non è un'apertura nuova."""
        k = (ev.get("app_id"), ev["tipo"])
        prima = self.ultimo_ogg.get(k)
        self.ultimo_ogg[k] = (chiave, ev["ts"])
        return prima is not None and chiave is not None and prima[0] == chiave and ev["ts"] - prima[1] <= RITORNO_MS

    def nome_app(self, ev) -> str:
        if ev.get("app_id") is None:
            return APP_FILE
        return self.ps.app(ev.get("bundle"), ev.get("app_nome"))

    def tipo_contesto(self, app_id) -> str:
        d = self.dominio.get(app_id)
        if d:
            return self.ps.sito(d)
        doc = self.documento.get(app_id)
        if doc and doc[1]:
            return str(doc[1]).lower()
        return ""

    def ancora(self, ev):
        """L'oggetto su cui si sta lavorando: documento, dominio o app."""
        tipo = ev["tipo"]
        if tipo in ("documento", "file_crea", "file_mod", "file_sposta", "file_elimina"):
            chiave = ev.get("inode") or ev.get("chiave_h") or ev.get("ogg_id")
            return "f:%s" % chiave
        if tipo == "url":
            return "d:%s" % pseudonimi.registrabile(ev.get("dominio") or "")
        app_id = ev.get("app_id")
        if app_id is None:
            return None
        if tipo == "escluso":
            return "x:%s" % app_id
        d = self.dominio.get(app_id)
        if d:
            return "d:%s" % pseudonimi.registrabile(d)
        doc = self.documento.get(app_id)
        if doc:
            return "f:%s" % doc[0]
        return "a:%s" % (ev.get("bundle") or app_id)

    def gesto_della_persona(self, ev) -> bool:
        """Vero se un evento sui file viene dalla persona: un download, o un suo gesto sui file
        (Finder, salva, esporta, menu fuori dai terminali) nei GESTO_FILE_MS prima."""
        if ev["tipo"] == "file_crea" and ev.get("cartella") == "download":
            return True
        t = self.ultimo_gesto_file
        return t is not None and 0 <= ev["ts"] - t <= GESTO_FILE_MS

    def simbolo(self, ev):
        """Il simbolo dell'evento (o None) e aggiorna il contesto."""
        tipo, app_id, det = ev["tipo"], ev.get("app_id"), ev["det"]
        if tipo == "escluso":
            return APP_ESCLUSA + ":escluso"
        if tipo in ("comando", "menu", "clic"):
            self.ultimo_input[app_id] = ev["ts"]
            b = ev.get("bundle")
            if b == FINDER or (b not in TERMINALI and (tipo == "menu" or azione_comando(ev) in SALVA)):
                self.ultimo_gesto_file = ev["ts"]
        app = self.nome_app(ev)
        if tipo == "finestra":
            if app_id != self.primo_piano:
                self.campo.pop(app_id, None)
            self.primo_piano = app_id
            if ev.get("bundle") not in pseudonimi.BROWSER:
                self.dominio.pop(app_id, None)
            return "%s:finestra" % app
        if tipo == "url":
            self.dominio[app_id] = ev.get("dominio") or ""
            self.documento.pop(app_id, None)
            if self.ritorno(ev, ev.get("chiave_h") or ev.get("ogg_id")):
                return None
            return "%s:visita:%s" % (app, self.ps.sito(ev.get("dominio")))
        if tipo == "documento":
            chiave = ev.get("inode") or ev.get("chiave_h") or ev.get("ogg_id")
            ext = (ev.get("ext") or "").lower()
            self.documento[app_id] = (chiave, ext)
            if ev.get("bundle") not in pseudonimi.BROWSER:
                self.dominio.pop(app_id, None)
            if self.ritorno(ev, chiave):
                return None
            azione = "apri_allegato" if ev.get("cartella") == "mail_allegati" else "apri"
            return "%s:%s:%s" % (app, azione, ext or "file")
        if tipo == "campo_focus":
            self.campo[app_id] = True
            return None
        if tipo == "campo_valore":
            etichetta = self.ps.breve(det.get("etichetta"), 2)
            dove = self.tipo_contesto(app_id) or ruolo_breve(det.get("ruolo"))
            return "%s:compila:%s%s" % (app, dove, ("/" + etichetta) if etichetta else "")
        if tipo in ("comando", "menu"):
            azione = azione_comando(ev)
            if tipo == "comando":
                tasti = str(det.get("tasti", "")).lower()
                if tasti in COMANDI_SALTATI:
                    return None
            if azione in COPIA:
                self.ultima_copia[app_id] = ev["ts"]
                self.ultima_copia_ts = ev["ts"]
                return "%s:%s" % (app, azione)
            if azione == "incolla":
                dove = self.tipo_contesto(app_id)
                if dove and self.campo.get(app_id):
                    dove += "/campo"
                elif not dove and self.campo.get(app_id):
                    dove = "campo"
                return "%s:incolla%s" % (app, (":" + dove) if dove else "")
            if tipo == "comando":
                if azione:
                    return "%s:%s" % (app, azione)
                return "%s:tasti:%s" % (app, str(det.get("tasti", "")).lower())
            voce = self.ps.breve(voce_menu(str(det.get("percorso", ""))), 4)
            return "%s:menu:%s" % (app, voce or "voce")
        if tipo == "clic":
            if det.get("web"):
                return "%s:clic:web" % app
            etichetta = self.ps.breve(det.get("etichetta"), 3)
            return "%s:clic:%s" % (app, etichetta or ruolo_breve(det.get("ruolo")))
        if tipo == "appunti":
            if det.get("riservato"):
                return None
            t = self.ultima_copia.get(app_id)
            if t is not None and 0 <= ev["ts"] - t <= 3000:
                return None
            # la copia c'è già, in un'altra app (cmd+c e poi cmd+tab prima del controllo)
            if self.ultima_copia_ts is not None and 0 <= ev["ts"] - self.ultima_copia_ts <= 3000:
                return None
            if app_id != self.primo_piano:
                return None
            # nessun comando, menu o clic qui nei 3 s prima: il contenuto arriva da fuori
            ui = self.ultimo_input.get(app_id)
            if ui is None or not 0 <= ev["ts"] - ui <= 3000:
                return None
            return "%s:copia" % app
        if tipo.startswith("file_"):
            if not self.gesto_della_persona(ev):
                return None
            ext = (ev.get("ext") or "").lower() or "file"
            azione = {"file_crea": "crea", "file_mod": "modifica", "file_sposta": "sposta",
                      "file_elimina": "elimina"}[tipo] if tipo in (
                "file_crea", "file_mod", "file_sposta", "file_elimina") else tipo
            if tipo == "file_crea" and ev.get("cartella") == "download":
                azione = "scarica"
            return "%s:%s:%s" % (APP_FILE, azione, ext)
        if tipo == "protetto":
            return "%s:protetto" % app
        return None


def prepara(eventi: list, ps, contesto_prima: list = ()) -> list:
    """Aggiunge a ogni evento "_simbolo" e "_ancora". contesto_prima scalda il contesto."""
    ctx = Contesto(ps)
    for ev in contesto_prima:
        ctx.simbolo(ev)
    for ev in eventi:
        ev["_simbolo"] = ctx.simbolo(ev)
        ev["_ancora"] = ctx.ancora(ev) if ev["_simbolo"] else None
    return eventi


class _Episodio:
    def __init__(self):
        self.eventi = []
        self.visto = {}
        self.tempo = {}
        self.ancore = []       # ancore in ordine di prima comparsa
        self.fine = 0

    def aggiungi(self, ev, credito: int):
        a = ev["_ancora"]
        self.eventi.append(ev)
        if a is not None:
            if a not in self.visto:
                self.ancore.append(a)
            self.visto[a] = ev["ts"]
            self.tempo[a] = self.tempo.get(a, 0) + credito
        self.fine = max(self.fine, ev["ts"] + min(int(ev.get("dur_ms") or 0), TETTO_DUR_MS))

    def principale(self):
        if not self.tempo:
            return None
        return max(self.ancore, key=lambda a: (self.tempo.get(a, 0), -self.ancore.index(a)))


def _crediti(eventi: list) -> dict:
    """Tempo dato a ogni evento: fino al prossimo evento con simbolo, al massimo 5 minuti."""
    out = {}
    for i, ev in enumerate(eventi):
        dopo = eventi[i + 1]["ts"] if i + 1 < len(eventi) else ev["ts"] + int(ev.get("dur_ms") or 0)
        out[id(ev)] = max(0, min(dopo - ev["ts"], TETTO_DUR_MS))
    return out


def _taglia(cur, rif, ev, crediti: dict):
    """Taglio retroattivo: il nuovo episodio parte dal primo oggetto nuovo dopo l'ultima visita
    di rif. Ritorna (episodio chiuso o None, episodio corrente o None)."""
    ultima = cur.visto[rif]
    note = set()
    k = None
    for i, e in enumerate(cur.eventi):
        if e["ts"] <= ultima:
            if e["_ancora"] is not None:
                note.add(e["_ancora"])
            continue
        if e["_ancora"] is not None and e["_ancora"] not in note:
            k = i
            break
    if k is not None:
        vecchio, nuovo = _Episodio(), _Episodio()
        for e in cur.eventi[:k]:
            vecchio.aggiungi(e, crediti[id(e)])
        for e in cur.eventi[k:]:
            nuovo.aggiungi(e, crediti[id(e)])
        return vecchio, nuovo
    if ev["_ancora"] is not None and ev["_ancora"] not in cur.visto:
        return cur, None
    # si lavora ancora sugli oggetti dell'episodio: vale come ritorno
    cur.visto[rif] = ev["ts"]
    return None, cur


def segmenta(eventi: list) -> list:
    """Divide gli eventi (già preparati) in episodi: liste di eventi con simbolo."""
    con_simbolo = [e for e in eventi if e.get("_simbolo")]
    crediti = _crediti(con_simbolo)
    episodi = []
    cur = None
    for ev in eventi:
        t = ev["ts"]
        tipo = ev["tipo"]
        if tipo in TAGLI or (tipo == "inattivo" and int(ev.get("dur_ms") or 0) > INATTIVITA_MS):
            if cur is not None and cur.eventi:
                episodi.append(cur)
            cur = None
            continue
        if not ev.get("_simbolo"):
            continue
        if cur is not None and t - cur.fine > INATTIVITA_MS:
            episodi.append(cur)
            cur = None
        if cur is not None:
            rif = None
            p = cur.principale()
            iniziale = cur.ancore[0] if cur.ancore else None
            if p is not None and t - cur.visto[p] > RITORNO_MS:
                rif = p
            elif (iniziale is not None and t - cur.eventi[0]["ts"] > SENZA_RITORNO_MS
                  and t - cur.visto[iniziale] > SENZA_RITORNO_MS):
                rif = iniziale
            if rif is not None:
                chiuso, cur = _taglia(cur, rif, ev, crediti)
                if chiuso is not None and chiuso.eventi:
                    episodi.append(chiuso)
        if cur is None:
            cur = _Episodio()
        cur.aggiungi(ev, crediti[id(ev)])
    if cur is not None and cur.eventi:
        episodi.append(cur)
    return _ricuci(episodi)


def _ricuci(episodi: list) -> list:
    out = []
    for ep in episodi:
        if out:
            prec = out[-1]
            if (prec.principale() is not None and prec.principale() == ep.principale()
                    and ep.eventi[0]["ts"] - prec.fine <= RICUCITURA_MS):
                for a, v in ep.tempo.items():
                    prec.tempo[a] = prec.tempo.get(a, 0) + v
                for e in ep.eventi:
                    a = e["_ancora"]
                    prec.eventi.append(e)
                    if a is not None:
                        if a not in prec.visto:
                            prec.ancore.append(a)
                        prec.visto[a] = e["ts"]
                    prec.fine = max(prec.fine, e["ts"] + min(int(e.get("dur_ms") or 0), TETTO_DUR_MS))
                continue
        out.append(ep)
    return out


def attivo_ms(ep) -> int:
    return int(sum(ep.tempo.values()))


# --- Sequenza compressa: la usano firma, routine e conta ---------------------------------

def comprimi(righe: list) -> list:
    """righe: dict con evento_id, simbolo, ts, fine (in ordine). Ritorna i token:
    {"s": simbolo, "n": ripetizioni, "e0", "e1", "t0", "t1"}.

    Dentro una corsa della stessa app, "App:finestra" sparisce se l'app ha fatto altro.
    Poi le ripetizioni consecutive dello stesso simbolo diventano un token solo.
    """
    corse = []
    for r in righe:
        app = r["simbolo"].split(":", 1)[0]
        if corse and corse[-1][0] == app:
            corse[-1][1].append(r)
        else:
            corse.append((app, [r]))
    filtrate = []
    for app, rs in corse:
        altro = [r for r in rs if not r["simbolo"].endswith(":finestra")]
        if altro:
            # il tempo della finestra si somma al primo evento che resta
            primo_ts = rs[0]["ts"]
            for i, r in enumerate(altro):
                filtrate.append(dict(r, ts=primo_ts) if i == 0 else r)
        else:
            filtrate.extend(rs)
    token = []
    for r in filtrate:
        if token and token[-1]["s"] == r["simbolo"]:
            t = token[-1]
            t["n"] += 1
            t["e1"] = r["evento_id"]
            t["t1"] = max(t["t1"], r["fine"])
        else:
            token.append({"s": r["simbolo"], "n": 1, "e0": r["evento_id"], "e1": r["evento_id"],
                          "t0": r["ts"], "t1": max(r["fine"], r["ts"])})
    return token


BLOCCO_MAX = 6
SEP_BLOCCO = " + "


def _senza_volte(s: str) -> str:
    i = s.rfind(")×")
    return s[:i + 1] if i > 0 and s[i + 2:].isdigit() else s


def e_blocco(s: str) -> bool:
    """Vero per un blocco "(A + B + C)", anche con le ripetizioni "×6" in coda."""
    s = _senza_volte(s)
    return s.startswith("(") and s.endswith(")") and SEP_BLOCCO in s


def simboli_di(s: str) -> list:
    """I simboli di un token: quelli del blocco "(A + B + C)", oppure il simbolo stesso."""
    return _senza_volte(s)[1:-1].split(SEP_BLOCCO) if e_blocco(s) else [s]


def blocchi(token: list, massimo: int = BLOCCO_MAX) -> list:
    """Un blocco di 2..massimo token che si ripete di seguito diventa un token solo,
    "(A + B + C)" con n = ripetizioni: sei copia e incolla uguali di fila sono un passo
    della routine, non sei routine. Fra blocchi che coprono lo stesso tratto vince il più corto.
    """
    out = []
    i = 0
    s = [t["s"] for t in token]
    while i < len(token):
        meglio = None
        for k in range(2, massimo + 1):
            if i + 2 * k > len(token):
                break
            r = 1
            while i + (r + 1) * k <= len(token) and s[i + r * k:i + (r + 1) * k] == s[i:i + k]:
                r += 1
            if r >= 2 and (meglio is None or r * k > meglio[0] * meglio[1]):
                meglio = (k, r)
        if meglio is None:
            out.append(token[i])
            i += 1
            continue
        k, r = meglio
        pezzi = token[i:i + k * r]
        t = {"s": "(" + SEP_BLOCCO.join(s[i:i + k]) + ")", "n": r, "e0": pezzi[0]["e0"],
             "e1": pezzi[-1]["e1"], "t0": pezzi[0]["t0"], "t1": max(p["t1"] for p in pezzi)}
        if "ep" in pezzi[0]:
            t["ep"] = pezzi[0]["ep"]
        out.append(t)
        i += k * r
    return out


def schema_breve(simboli) -> str:
    """Lo schema di una routine da leggere: i blocchi ripetuti di seguito come "(A + B)×6"."""
    tok = blocchi([{"s": x, "n": 1, "e0": 0, "e1": 0, "t0": 0, "t1": 0} for x in simboli])
    return " > ".join(mostra_token(t) for t in tok)


def mostra_token(t: dict) -> str:
    return t["s"] + ("×%d" % t["n"] if t["n"] > 1 else "")


def firma(token: list, massimo: int = 0) -> str:
    voci = [mostra_token(t) for t in token]
    if massimo and len(voci) > massimo:
        voci = voci[:massimo] + ["… +%d" % (len(voci) - massimo)]
    return " > ".join(voci)
