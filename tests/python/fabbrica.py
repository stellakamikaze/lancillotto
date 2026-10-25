"""Fabbrica di registri sintetici per i test, secondo docs/CONTRATTO.md e registratore/schema.sql.

Cinque giorni di lavoro (gli ultimi cinque, oggi compreso) con tre routine piantate, varianti e
rumore, legami degli appunti con verità nota e titoli con nomi di clienti inventati.

Routine piantate:
- R1 "fatture al portale": Mail > Anteprima (allegato pdf) > copia > Chrome su un portale non
  pubblico > incolla in un campo, tre o due volte; 3 al giorno per 5 giorni.
- R2 "report vendite": Drive > download xlsx > Excel (ordina, pivot, salva) > esporta pdf > Mail
  (allega, invia); 1 al giorno per 5 giorni.
- R3 "agenda in Slack": Calendario (pulsante Copia, senza comando) > Slack incolla e invia;
  2 al giorno dal secondo giorno.
Casi degli appunti con verità nota: copia e incolla veri (anche dentro il rumore), incolla senza
copia vista (copia dentro un'app esclusa), cambio da un gestore di appunti in secondo piano,
ventaglio (una copia, tre incolla), incolla dopo 35 minuti (altro compito).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import random
import sqlite3
import sys
import zlib
from pathlib import Path

RADICE = Path(__file__).resolve().parents[2]
SCHEMA = RADICE / "registratore" / "schema.sql"

APP = {
    "mail": ("com.apple.mail", "Mail"),
    "anteprima": ("com.apple.Preview", "Anteprima"),
    "chrome": ("com.google.Chrome", "Google Chrome"),
    "excel": ("com.microsoft.Excel", "Microsoft Excel"),
    "slack": ("com.tinyspeck.slackmacgap", "Slack"),
    "calendario": ("com.apple.iCal", "Calendario"),
    "note": ("com.apple.Notes", "Note"),
    "spotify": ("com.spotify.client", "Spotify"),
    "1password": ("com.1password.1password", "1Password"),
    "appunti_sfondo": ("com.esempio.gestore-appunti", "Gestore Appunti Zeta"),
    "gestionale": ("it.esempio.gestionale", "Gestionale Rossi Impianti"),
}
CLIENTI = ["Rossi Impianti Srl", "Bianchi Logistica", "Ferraresi Costruzioni"]
NOMI_VIETATI = ["Rossi", "Bianchi", "Ferraresi", "Zeta", "acme", "portale-fornitori"]
PORTALE = "portale-fornitori-acme.it"
SEGRETO_L2 = "sk-ant-api03-VELENOabcdefghijklmnopqrstuvwxyz0123456789"
IBAN_L2 = "IT60X0542811101000000123456"


def comprimi(testo: str) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(testo.encode("utf-8")) + c.flush()


class Fabbrica:
    def __init__(self, cartella, seme: int = 7, schema_versione: int = 1, battito_ms=None):
        self.cartella = Path(cartella)
        self.cartella.mkdir(parents=True, exist_ok=True)
        os.chmod(str(self.cartella), 0o700)
        self.chiave = bytes(range(32))
        p = self.cartella / "chiave"
        p.write_bytes(self.chiave)
        os.chmod(str(p), 0o600)
        self.percorso = self.cartella / "registro.sqlite"
        self.conn = sqlite3.connect(str(self.percorso))
        self.conn.executescript(SCHEMA.read_text(encoding="utf-8"))
        ora = int(dt.datetime.now().timestamp() * 1000)
        for k, v in (("schema_versione", str(schema_versione)), ("versione_binario", "0.0-fabbrica"),
                     ("ultimo_battito", str(battito_ms if battito_ms is not None else ora)),
                     ("persi", "0"), ("avvio", str(ora)), ("permesso_ax", "1"), ("permesso_schermo", "1")):
            self.conn.execute("INSERT OR REPLACE INTO meta(chiave, valore) VALUES (?, ?)", (k, v))
        self.rng = random.Random(seme)
        self.t = 0
        self.cc = 1000
        self.inode = 5000
        self.app_id = {}
        self.ogg_id = {}
        self.finestra_aperta = None
        self.primo_piano = None
        self.n_fattura = 100
        self.verita = {"appunti": set(), "senza_copia": [], "sfondo": [], "ventaglio": [],
                       "altro_compito": [], "routine": {"R1": 0, "R2": 0, "R3": 0}}
        self.intervallo_testo = None

    # --- basi ---------------------------------------------------------------------------
    def h(self, tipo: str, valore: str) -> str:
        return hmac.new(self.chiave, (tipo + "\u0000" + valore).encode("utf-8"), hashlib.sha256).hexdigest()[:32]

    def app(self, chiave: str) -> int:
        if chiave not in self.app_id:
            bundle, nome = APP[chiave]
            esclusa = 1 if chiave == "1password" else 0
            cur = self.conn.execute("INSERT INTO app(bundle, nome, esclusa) VALUES (?, ?, ?)", (bundle, nome, esclusa))
            self.app_id[chiave] = cur.lastrowid
        return self.app_id[chiave]

    def oggetto(self, tipo, valore, etichetta=None, dominio=None, ext=None, inode=None, cartella=None,
                provenienza=None) -> int:
        ch = self.h(tipo, valore)
        if ch not in self.ogg_id:
            cur = self.conn.execute(
                "INSERT INTO oggetto(tipo, chiave_h, etichetta, dominio, ext, inode, cartella, provenienza)"
                " VALUES (?,?,?,?,?,?,?,?)", (tipo, ch, etichetta, dominio, ext, inode, cartella, provenienza))
            self.ogg_id[ch] = cur.lastrowid
        return self.ogg_id[ch]

    def evento(self, tipo, app=None, ogg=None, dur=0, det=None, cc=None, passo=1000, tasti=None, click=None) -> int:
        cur = self.conn.execute(
            "INSERT INTO evento(ts, dur_ms, tipo, app_id, ogg_id, dettaglio, cc, tasti, click)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (self.t, dur, tipo, self.app(app) if app else None, ogg,
             json.dumps(det, ensure_ascii=False, separators=(",", ":")) if det is not None else None,
             cc, tasti, click))
        self.t += passo
        return cur.lastrowid

    def chiudi_finestra(self):
        if self.finestra_aperta is not None:
            ident, t0 = self.finestra_aperta
            self.conn.execute("UPDATE evento SET dur_ms = ? WHERE id = ?", (max(0, self.t - t0), ident))
            self.finestra_aperta = None

    def finestra(self, app, titolo, passo=1000) -> int:
        self.chiudi_finestra()
        bundle = APP[app][0]
        ogg = self.oggetto("finestra", bundle + "\u0000" + titolo, etichetta=titolo)
        t0 = self.t
        ident = self.evento("finestra", app, ogg, det={"pid": 400 + len(app)}, passo=passo, tasti=3, click=1)
        self.finestra_aperta = (ident, t0)
        self.primo_piano = app
        return ident

    def url(self, app, dominio, etichetta, passo=1500) -> int:
        ogg = self.oggetto("url", "https://%s/%s" % (dominio, etichetta), etichetta=etichetta, dominio=dominio)
        return self.evento("url", app, ogg, det={"fonte": "ax"}, passo=passo)

    def file(self, percorso, ext, cartella="documenti", provenienza=None, inode=None):
        nome = percorso.rsplit("/", 1)[-1]
        if inode is None:
            self.inode += 1
            inode = self.inode
        return self.oggetto("file", percorso, etichetta=nome, ext=ext, inode=inode, cartella=cartella,
                            provenienza=provenienza), inode

    def documento(self, app, ogg, passo=2000) -> int:
        return self.evento("documento", app, ogg, det={"fonte": "axdocument"}, passo=passo)

    def comando(self, app, tasti, passo=800) -> int:
        return self.evento("comando", app, None, det={"tasti": tasti}, cc=self.cc, passo=passo)

    def menu(self, app, percorso, passo=1500) -> int:
        return self.evento("menu", app, None, det={"percorso": percorso}, passo=passo)

    def clic(self, app, etichetta, ruolo="AXButton", passo=1200) -> int:
        return self.evento("clic", app, None, det={"ruolo": ruolo, "etichetta": etichetta}, passo=passo)

    def copia(self, app, esplicita=True, passo=1500) -> int:
        if esplicita:
            self.comando(app, "cmd+c", passo=80)
        self.cc += 1
        return self.evento("appunti", app, None, det={"tipi": ["public.utf8-plain-text"], "riservato": 0, "len": 12},
                           cc=self.cc, passo=passo)

    def incolla(self, app, passo=1500) -> int:
        return self.comando(app, "cmd+v", passo=passo)

    def campo_valore(self, app, etichetta, valore, passo=2500) -> int:
        bundle = APP[app][0]
        ogg = self.oggetto("finestra", bundle + "\u0000campo")
        ident = self.evento("campo_valore", app, ogg, dur=3000, det={"ruolo": "AXTextField", "etichetta": etichetta},
                            passo=passo)
        self.conn.execute("INSERT INTO campo(evento_id, ruolo, etichetta, valore_z, lunghezza, redazioni)"
                          " VALUES (?,?,?,?,?,0)", (ident, "AXTextField", etichetta, comprimi(valore), len(valore)))
        return ident

    def impronta(self, evento_id, valore, tipo, fonte):
        self.conn.execute("INSERT INTO impronta(h, tipo, evento_id, fonte) VALUES (?,?,?,?)",
                          (self.h("impronta", valore), tipo, evento_id, fonte))

    def schermo(self, app, righe: list, fonte="ocr"):
        ev = self.evento("schermo", app, None, det={"fonte": fonte, "ms": 120}, passo=500)
        ids = []
        for testo in righe:
            hh = hashlib.sha256(testo.encode("utf-8")).hexdigest()[:32]
            r = self.conn.execute("SELECT id FROM riga WHERE h = ?", (hh,)).fetchone()
            if r is None:
                cur = self.conn.execute(
                    "INSERT INTO riga(h, testo_z, lunghezza, prima_ts, ultima_ts, volte) VALUES (?,?,?,?,?,1)",
                    (hh, comprimi(testo), len(testo), self.t, self.t))
                ids.append(cur.lastrowid)
            else:
                ids.append(r[0])
        self.conn.execute("INSERT INTO schermo(evento_id, ts, fonte, finestra_id, aggiunte, tolte, n_righe)"
                          " VALUES (?,?,?,?,?,?,?)", (ev, self.t - 500, fonte, None, json.dumps(ids), "[]", len(ids)))
        return ev

    def pausa_sec(self, secondi):
        self.t += int(secondi * 1000)

    # --- rumore ---------------------------------------------------------------------------
    def rumore(self, minuti, appunti=True):
        fine = self.t + minuti * 60000
        while self.t < fine:
            x = self.rng.random()
            if x < 0.16:
                self.finestra("slack", "Slack - generale", passo=self.rng.randint(30, 120) * 1000)
            elif x < 0.30:
                self.finestra("chrome", "Video - YouTube")
                self.url("chrome", "youtube.com", "watch", passo=self.rng.randint(40, 150) * 1000)
            elif x < 0.42:
                self.finestra("chrome", "Notizie del giorno")
                self.url("chrome", self.rng.choice(["giornale-locale-esempio.it", "it.wikipedia.org",
                                                    "meteo-esempio.it"]), "pagina",
                         passo=self.rng.randint(30, 120) * 1000)
            elif x < 0.52:
                self.finestra("note", "Note - idee", passo=self.rng.randint(20, 90) * 1000)
            elif x < 0.58:
                self.finestra("spotify", "Spotify", passo=self.rng.randint(10, 40) * 1000)
            elif x < 0.66:
                cliente = self.rng.choice(CLIENTI)
                self.finestra("mail", "Re: preventivo %s" % cliente, passo=self.rng.randint(30, 100) * 1000)
            elif x < 0.72:
                self.finestra("gestionale", "Gestionale - anagrafica %s" % self.rng.choice(CLIENTI),
                              passo=self.rng.randint(30, 90) * 1000)
            elif x < 0.78:
                self.finestra("slack", "Slack - generale", passo=2000)
                self.comando("slack", "cmd+tab", passo=1000)
                self.finestra("note", "Note - idee", passo=self.rng.randint(10, 30) * 1000)
            elif x < 0.84:
                self.finestra("excel", "Budget %s.xlsx" % self.rng.choice(CLIENTI), passo=1000)
                f, _i = self.file("/Users/prova/Documents/Budget.xlsx", "xlsx", inode=4242)
                self.documento("excel", f, passo=self.rng.randint(30, 90) * 1000)
            elif x < 0.90 and appunti:
                self.finestra("note", "Note - idee", passo=4000)
                a = self.copia("note", passo=5000)
                p = self.incolla("note", passo=self.rng.randint(10, 40) * 1000)
                self.verita["appunti"].add((a, p))
            elif x < 0.94:
                self.finestra("chrome", "Accesso")
                self.evento("protetto", "chrome", None, dur=8000, det={}, passo=9000)
            else:
                self.chiudi_finestra()
                self.evento("escluso", "1password", None, dur=15000, det={"perche": "app"}, passo=16000)

    # --- routine piantate -------------------------------------------------------------------
    def r1(self, variante: int):
        self.verita["routine"]["R1"] += 1
        cliente = self.rng.choice(CLIENTI)
        self.n_fattura += 1
        numero = "2026/%d" % self.n_fattura
        self.finestra("mail", "Fattura ottobre - %s" % cliente, passo=40000)
        nome = "Fattura %d %s.pdf" % (self.n_fattura, cliente)
        self.finestra("anteprima", nome, passo=1000)
        f, _i = self.file("/Users/prova/Library/Mail Downloads/%s" % nome, "pdf", cartella="mail_allegati")
        doc = self.documento("anteprima", f, passo=25000)
        self.impronta(doc, numero, "numero", "file")
        campi = [("Numero", numero), ("Data", "24/10/2026"), ("Importo", "1.250,00")]
        if variante == 2:
            campi = [campi[0], campi[2]]
        for k, (campo, valore) in enumerate(campi):
            if k:
                self.finestra("anteprima", nome, passo=12000)
            a = self.copia("anteprima", passo=1500)
            self.finestra("chrome", "Portale fornitori - Nuova fattura", passo=1000)
            if k == 0:
                self.url("chrome", PORTALE, "fatture", passo=2000)
            self.evento("campo_focus", "chrome", None, det={"ruolo": "AXTextField", "etichetta": campo}, passo=1000)
            p = self.incolla("chrome", passo=2000)
            self.verita["appunti"].add((a, p))
            cv = self.campo_valore("chrome", campo, valore)
            if campo == "Numero":
                self.impronta(cv, numero, "numero", "campo")
        if variante == 3:
            self.clic("chrome", "Salva bozza", passo=3000)
        self.clic("chrome", "Invia", passo=20000)

    def r2(self, variante: int, giorno: str):
        self.verita["routine"]["R2"] += 1
        cliente = self.rng.choice(CLIENTI)
        self.finestra("chrome", "Report vendite - Google Drive", passo=1000)
        self.url("chrome", "drive.google.com", "drive", passo=30000)
        nome = "Report vendite %s %s.xlsx" % (cliente, giorno)
        f, inode = self.file("/Users/prova/Downloads/%s" % nome, "xlsx", cartella="download",
                             provenienza="drive.google.com")
        self.evento("file_crea", None, f, passo=4000)
        self.finestra("excel", nome, passo=1000)
        self.documento("excel", f, passo=60000)
        self.menu("excel", "Dati > Ordina", passo=45000)
        if variante != 2:
            self.menu("excel", "Inserisci > Tabella pivot", passo=90000)
        self.comando("excel", "cmd+s", passo=1000)
        self.evento("file_mod", None, f, passo=20000)
        self.menu("excel", "Archivio > Esporta come PDF…", passo=8000)
        pdf, _ = self.file("/Users/prova/Documents/Report vendite %s %s.pdf" % (cliente, giorno), "pdf")
        self.evento("file_crea", None, pdf, passo=5000)
        self.finestra("mail", "Nuovo messaggio", passo=20000)
        self.clic("mail", "Allega", passo=15000)
        self.comando("mail", "shift+cmd+d", passo=10000)

    def r3(self, ripetizioni: int):
        self.verita["routine"]["R3"] += 1
        for _k in range(ripetizioni):
            self.finestra("calendario", "Calendario - settimana", passo=20000)
            self.clic("calendario", "Copia", passo=200)
            a = self.copia("calendario", esplicita=False, passo=3000)
            self.finestra("slack", "Slack - progetto", passo=4000)
            p = self.incolla("slack", passo=6000)
            self.verita["appunti"].add((a, p))
            self.comando("slack", "cmd+return", passo=15000)

    # --- casi speciali degli appunti ---------------------------------------------------------
    def caso_senza_copia(self):
        self.chiudi_finestra()
        self.evento("escluso", "1password", None, dur=12000, det={"perche": "app"}, passo=12000)
        self.cc += 1  # la copia dentro l'app esclusa non lascia eventi
        self.finestra("chrome", "Accesso al servizio", passo=2000)
        p = self.incolla("chrome", passo=5000)
        self.verita["senza_copia"].append(p)

    def caso_sfondo(self):
        self.finestra("note", "Note - idee", passo=3000)
        a = self.copia("note", passo=4000)
        self.cc += 1
        s = self.evento("appunti", "appunti_sfondo", None, det={"tipi": ["public.utf8-plain-text"], "riservato": 0,
                                                                "len": 30}, cc=self.cc, passo=3000)
        self.finestra("chrome", "Notizie del giorno", passo=2000)
        p = self.incolla("chrome", passo=5000)
        self.verita["sfondo"].append((s, p))
        del a

    def caso_ventaglio(self):
        self.finestra("note", "Note - elenco", passo=3000)
        a = self.copia("note", passo=3000)
        incolla = []
        for _k in range(3):
            self.finestra("excel", "Budget generale.xlsx", passo=4000)
            p = self.incolla("excel", passo=6000)
            incolla.append(p)
            self.verita["appunti"].add((a, p))
            self.finestra("note", "Note - elenco", passo=5000)
        self.verita["ventaglio"].append((a, incolla))

    def caso_altro_compito(self):
        self.finestra("note", "Note - indirizzi", passo=3000)
        a = self.copia("note", passo=3000)
        self.rumore(35, appunti=False)
        self.finestra("mail", "Nuovo messaggio", passo=3000)
        p = self.incolla("mail", passo=4000)
        self.verita["appunti"].add((a, p))
        self.verita["altro_compito"].append((a, p))

    # --- giornate ---------------------------------------------------------------------------
    def inizio_giorno(self, data: dt.date, ora=9):
        self.t = int(dt.datetime.combine(data, dt.time(ora, 0)).timestamp() * 1000)
        self.evento("servizio", None, None, det={"cosa": "avvio", "dettaglio": "fabbrica"}, passo=1000)
        self.evento("sblocco", None, None, det={}, passo=1000)

    def fine_giorno(self):
        self.chiudi_finestra()
        self.evento("blocco", None, None, det={}, passo=1000)

    def pranzo(self):
        self.chiudi_finestra()
        self.evento("inattivo", None, None, dur=45 * 60000, det={}, passo=45 * 60000)

    def giornata(self, data: dt.date, indice: int):
        self.inizio_giorno(data)
        if indice == 0:
            # incolla prima di qualunque copia vista
            self.finestra("chrome", "Notizie del giorno", passo=2000)
            p = self.incolla("chrome", passo=3000)
            self.verita["senza_copia"].append(p)
        self.rumore(self.rng.randint(12, 20))
        self.r1(1 + (indice % 3))
        self.rumore(self.rng.randint(14, 22))
        self.r2(1 if indice % 2 == 0 else 2, data.isoformat())
        self.rumore(self.rng.randint(12, 20))
        if indice >= 1:
            self.r3(2 if indice % 2 else 1)
            self.rumore(self.rng.randint(12, 18))
        self.caso_senza_copia()
        self.rumore(self.rng.randint(10, 16))
        self.pranzo()
        self.rumore(self.rng.randint(10, 16))
        self.r1(3 if indice % 2 else 1)
        self.rumore(self.rng.randint(12, 20))
        if indice == 4:
            self.t0_testo = self.t
            self.finestra("anteprima", "Fattura scansionata.pdf", passo=2000)
            self.schermo("anteprima", ["Totale fattura 1.250,00 euro", "Cliente Rossi Impianti Srl",
                                       "Pagamento su %s entro il 30/11" % IBAN_L2,
                                       "Dettagli su https://%s/fatture?id=99 e www.esempio-privato.it/x" % PORTALE,
                                       "chiave di prova %s" % SEGRETO_L2, "numero ordine 774411"])
            self.pausa_sec(30)
            self.intervallo_testo = (self.t0_testo - 1000, self.t + 1000)
        self.caso_sfondo()
        self.rumore(self.rng.randint(8, 12))
        if indice >= 1:
            self.r3(1)
            self.rumore(self.rng.randint(12, 18))
        self.caso_ventaglio()
        self.rumore(self.rng.randint(12, 18))
        self.r1(2 if indice % 2 == 0 else 1)
        self.rumore(self.rng.randint(10, 15))
        if indice == 2:
            self.caso_altro_compito()
            self.rumore(10)
        if indice >= 1:
            self.r3(2)
            self.rumore(self.rng.randint(8, 12))
        self.fine_giorno()

    def salute(self, data: dt.date):
        t = int(dt.datetime.combine(data, dt.time(9, 1)).timestamp() * 1000)
        self.conn.execute("INSERT INTO salute(ts, sensore, stato, dettaglio) VALUES (?,?,?,?)", (t, "ax", "ok", None))
        self.conn.execute("INSERT INTO salute(ts, sensore, stato, dettaglio) VALUES (?,?,?,?)",
                          (t + 1000, "url firefox", "degradato", "URL mancante su Firefox"))

    def cinque_giorni(self, oggi: dt.date = None):
        oggi = oggi or dt.date.today()
        for i in range(5):
            d = oggi - dt.timedelta(days=4 - i)
            self.giornata(d, i)
        self.salute(oggi)
        self.conn.commit()
        return self

    def recenti(self, minuti_fa: int = 3):
        """Eventi vicini all'ora vera: servono a provare 'dimentica'."""
        self.t = int(dt.datetime.now().timestamp() * 1000) - minuti_fa * 60000
        self.finestra("note", "Note - segreto recente Ferraresi", passo=5000)
        cv = self.campo_valore("note", "Titolo", "valore recente da dimenticare", passo=3000)
        self.impronta(cv, "recente", "parola_rara", "campo")
        self.schermo("note", ["riga recente da dimenticare 991"])
        self.chiudi_finestra()
        self.conn.commit()
        return cv

    def riapri(self):
        self.conn = sqlite3.connect(str(self.percorso))
        return self

    def chiudi(self):
        self.conn.commit()
        self.conn.close()
        os.chmod(str(self.percorso), 0o600)


def nuova(cartella, **kw) -> Fabbrica:
    return Fabbrica(cartella, **kw).cinque_giorni()


if __name__ == "__main__":
    f = nuova(sys.argv[1] if len(sys.argv) > 1 else "fabbrica-dati")
    print(json.dumps({k: (len(v) if isinstance(v, (set, list)) else v) for k, v in f.verita.items()}))
    f.chiudi()
