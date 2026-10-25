"""analisi.sqlite: episodi, simboli, legami e routine ricavati dal registro.

La scrive solo Python. È incrementale (tabella cursore) e rigenerabile da zero (--da-zero).
Sopravvivono a --da-zero: alias (i segnaposto restano gli stessi), routine_stato (proposta,
confermata, rifiutata, automatizzata, scartata, con motivo e nota, e il giudizio di Claude con
titolo e come, per firma) e intento (le parole della
persona dalla revisione, per inizio dell'episodio).

  registro.sqlite (letto in una sola transazione: una fotografia, anche se il registratore scrive)
        │
        v
  firma della coda uguale al cursore? ── sì ──> niente da fare
        │ no
        v
  meta.cancellazioni cambiato, o righe cancellate fino al cursore? ── sì ──> da zero
  (gli id di riga e schermo si riusano dopo una cancellazione: i conteggi da soli non bastano)
        │ no
        v
  ripresa = min(primo evento nuovo, ultimo già visto) - 4 ore; si rifanno gli episodi da lì
        v
  simboli -> episodi -> legami -> righe di testo nell'indice -> routine (sempre tutte) -> cursore
"""
from __future__ import annotations

import datetime as dt
import json
import sqlite3
import time
from collections import Counter

from . import episodi as epm
from . import legami as lgm
from . import percorsi, raggiungo, registro
from . import routine as rtm
from .pseudonimi import Pseudonimi, parola_ammessa

RIPRESA_MS = 4 * 3600000
CONTESTO_MS = 2 * 3600000
RAGGIUNGO_VALIDITA_S = 86400
VERSIONE_ANALISI = 3
STATI = ("proposta", "confermata", "rifiutata", "automatizzata", "scartata")
# Il giudizio di Claude su una routine (melchior.valuta), persistente come lo stato.
COLONNE_GIUDIZIO = (("titolo", "TEXT"), ("come", "TEXT"), ("giudizio", "TEXT"), ("perche", "TEXT"),
                    ("giudicata", "TEXT"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS cursore(chiave TEXT PRIMARY KEY, valore TEXT);
CREATE TABLE IF NOT EXISTS episodio(id INTEGER PRIMARY KEY, t0 INTEGER NOT NULL, t1 INTEGER NOT NULL,
  attivo_ms INTEGER, giorno TEXT, ogg_principale INTEGER, principale TEXT, firma TEXT,
  n_simboli INTEGER, variante INTEGER, app TEXT, parole TEXT, titoli TEXT);
CREATE INDEX IF NOT EXISTS episodio_t0 ON episodio(t0);
CREATE INDEX IF NOT EXISTS episodio_giorno ON episodio(giorno);
CREATE TABLE IF NOT EXISTS simbolo(evento_id INTEGER PRIMARY KEY, episodio_id INTEGER, simbolo TEXT,
  ts INTEGER, fine INTEGER);
CREATE INDEX IF NOT EXISTS simbolo_s ON simbolo(simbolo);
CREATE INDEX IF NOT EXISTS simbolo_ep ON simbolo(episodio_id, ts);
CREATE TABLE IF NOT EXISTS legame(id INTEGER PRIMARY KEY, tipo TEXT, da_evento INTEGER, a_evento INTEGER,
  ritardo_ms INTEGER, confidenza REAL, prova TEXT, a_ts INTEGER, da_app INTEGER, a_app INTEGER,
  episodio_id INTEGER, da_simbolo TEXT, a_simbolo TEXT);
CREATE INDEX IF NOT EXISTS legame_da ON legame(da_evento);
CREATE INDEX IF NOT EXISTS legame_a ON legame(a_evento);
CREATE TABLE IF NOT EXISTS routine(id INTEGER PRIMARY KEY, firma_h TEXT, schema TEXT, varianti TEXT,
  volte INTEGER, episodi INTEGER, giorni INTEGER, lunghezza INTEGER, coesione REAL,
  tempo_totale_ms INTEGER, n_varianti INTEGER, legami_tra_app INTEGER, app TEXT, raggiungibile TEXT,
  punteggio REAL, avvio_a_freddo INTEGER, stato TEXT, dal TEXT, al TEXT, forme TEXT,
  cambiata_dal_rifiuto INTEGER, motivo_rifiuto TEXT);
CREATE TABLE IF NOT EXISTS routine_episodio(routine_id INTEGER, episodio_id INTEGER, e0 INTEGER,
  e1 INTEGER, t0 INTEGER, t1 INTEGER);
CREATE TABLE IF NOT EXISTS alias(tipo TEXT, h TEXT, segnaposto TEXT, PRIMARY KEY(tipo, h));
CREATE TABLE IF NOT EXISTS routine_stato(id INTEGER PRIMARY KEY AUTOINCREMENT, firma_h TEXT UNIQUE,
  schema TEXT, stato TEXT NOT NULL DEFAULT 'proposta', motivo TEXT, con_cosa TEXT, nota TEXT,
  tempo_rif_ms INTEGER, creata TEXT, aggiornata TEXT, titolo TEXT, come TEXT, giudizio TEXT,
  perche TEXT, giudicata TEXT);
CREATE TABLE IF NOT EXISTS intento(t0 INTEGER PRIMARY KEY, testo TEXT, ts INTEGER);
CREATE TABLE IF NOT EXISTS riga_vista(riga_id INTEGER, ts INTEGER, app_id INTEGER, fonte TEXT,
  schermo_id INTEGER);
CREATE INDEX IF NOT EXISTS riga_vista_r ON riga_vista(riga_id);
CREATE UNIQUE INDEX IF NOT EXISTS riga_vista_u ON riga_vista(riga_id, schermo_id);
CREATE INDEX IF NOT EXISTS riga_vista_ts ON riga_vista(ts);
CREATE VIRTUAL TABLE IF NOT EXISTS episodio_fts USING fts5(parole, intento,
  tokenize='unicode61 remove_diacritics 2');
CREATE VIRTUAL TABLE IF NOT EXISTS righe_fts USING fts5(testo, tokenize='unicode61 remove_diacritics 2');
CREATE VIEW IF NOT EXISTS v_evento AS SELECT evento_id, episodio_id, simbolo, ts FROM simbolo;
CREATE VIEW IF NOT EXISTS v_episodio AS SELECT id, t0, t1, attivo_ms, giorno, firma, n_simboli,
  variante, app, principale FROM episodio;
CREATE VIEW IF NOT EXISTS v_legame AS SELECT tipo, da_evento, a_evento, ritardo_ms, confidenza,
  episodio_id FROM legame;
CREATE VIEW IF NOT EXISTS v_routine AS SELECT id, schema, volte, episodi, giorni, n_varianti,
  tempo_totale_ms, punteggio, stato, avvio_a_freddo, dal, al FROM routine;
CREATE VIEW IF NOT EXISTS v_routine_episodio AS SELECT routine_id, episodio_id, t0, t1
  FROM routine_episodio;
"""

DERIVATE = ("episodio", "simbolo", "legame", "routine", "routine_episodio", "riga_vista",
            "episodio_fts", "righe_fts", "cursore")


def giorno_di(ts_ms: int) -> str:
    return dt.datetime.fromtimestamp(ts_ms / 1000).strftime("%Y-%m-%d")


def apri():
    """Apre (e crea, con permessi 600) analisi.sqlite. Se lo schema dell'analisi è di un'altra
    versione, le tabelle derivate si rifanno: sono rigenerabili, le persistenti restano."""
    percorsi.assicura_cartella()
    p = percorsi.analisi()
    percorsi.crea_600(p)
    conn = sqlite3.connect(str(p), timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=10000")
    versione = conn.execute("PRAGMA user_version").fetchone()[0]
    if versione != VERSIONE_ANALISI:
        for v in ("v_evento", "v_episodio", "v_legame", "v_routine", "v_routine_episodio"):
            conn.execute("DROP VIEW IF EXISTS %s" % v)
        for t in DERIVATE:
            conn.execute("DROP TABLE IF EXISTS %s" % t)
        conn.execute("PRAGMA user_version = %d" % VERSIONE_ANALISI)
        conn.commit()
    conn.executescript(SCHEMA)
    # routine_stato è persistente: un'analisi di prima del giudizio prende le colonne nuove
    presenti = {r[1] for r in conn.execute("PRAGMA table_info(routine_stato)")}
    for nome, tipo in COLONNE_GIUDIZIO:
        if nome not in presenti:
            conn.execute("ALTER TABLE routine_stato ADD COLUMN %s %s" % (nome, tipo))
    conn.commit()
    return conn


def _cursore(an) -> dict:
    out = {}
    for k, v in an.execute("SELECT chiave, valore FROM cursore"):
        try:
            out[k] = json.loads(v)
        except ValueError:
            continue
    return out


def _scrivi_cursore(an, chiave: str, valore) -> None:
    an.execute("INSERT OR REPLACE INTO cursore(chiave, valore) VALUES (?, ?)",
               (chiave, json.dumps(valore)))


def svuota(an) -> None:
    for t in DERIVATE:
        an.execute("DELETE FROM %s" % t)


def mappa_raggiungo(an) -> dict:
    """raggiungo() tenuto in cache per un giorno: serve al punteggio delle routine."""
    cur = _cursore(an).get("raggiungo")
    if isinstance(cur, dict) and time.time() - float(cur.get("ts", 0)) < RAGGIUNGO_VALIDITA_S:
        return cur.get("mappa") or {}
    mappa = raggiungo.raggiungo()
    _scrivi_cursore(an, "raggiungo", {"ts": time.time(), "mappa": mappa})
    return mappa


def _parole_episodio(evs: list, ps) -> tuple:
    """(10 parole più frequenti, titoli pseudonimizzati, tutte le parole ammesse per l'indice)."""
    conta = Counter()
    titoli = []
    for e in evs:
        if e.get("o_tipo") in ("finestra", "file") and e.get("etichetta"):
            t = ps.testo(e["etichetta"])
            if t and t not in titoli and len(titoli) < 12:
                titoli.append(t)
            for w in ps.parole(e["etichetta"]):
                if len(w) > 2 or w.startswith("["):
                    conta[w.lower() if not w.startswith("[") else w] += 1
    parole = [w for w, _n in conta.most_common(10)]
    ammesse = sorted(w for w in conta if not w.startswith("[") and parola_ammessa(w))
    return parole, titoli, ammesse


def _principale(ep, ps, per_ancora: dict) -> tuple:
    a = ep.principale()
    if a is None:
        return None, ""
    ev = per_ancora.get(a)
    if a.startswith("d:"):
        return (ev.get("ogg_id") if ev else None), ps.sito(a[2:])
    if a.startswith("f:"):
        ext = (ev.get("ext") if ev else "") or "file"
        return (ev.get("ogg_id") if ev else None), "file " + str(ext).lower()
    if ev is not None:
        return None, ps.app(ev.get("bundle"), ev.get("app_nome"))
    return None, ""


def _inserisci_episodi(an, eps: list, ps) -> dict:
    """Scrive episodi, simboli e indice. Ritorna episodio -> lista di eventi."""
    out = {}
    intenti = {r["t0"]: r["testo"] for r in an.execute("SELECT t0, testo FROM intento")}
    for ep in eps:
        evs = ep.eventi
        righe = [{"evento_id": e["id"], "simbolo": e["_simbolo"], "ts": e["ts"],
                  "fine": e["ts"] + min(int(e.get("dur_ms") or 0), epm.TETTO_DUR_MS)} for e in evs]
        token = epm.comprimi(righe)
        app = []
        for t in token:
            a = t["s"].split(":", 1)[0]
            if a not in app:
                app.append(a)
        parole, titoli, tutte = _parole_episodio(evs, ps)
        per_ancora = {}
        for e in evs:
            if e["_ancora"] is not None:
                per_ancora.setdefault(e["_ancora"], e)
        ogg, principale = _principale(ep, ps, per_ancora)
        t0 = evs[0]["ts"]
        cur = an.execute(
            "INSERT INTO episodio(t0, t1, attivo_ms, giorno, ogg_principale, principale, firma, n_simboli,"
            " app, parole, titoli) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (t0, max(ep.fine, evs[-1]["ts"]), epm.attivo_ms(ep), giorno_di(t0), ogg, principale,
             epm.firma(token), len(token), json.dumps(app, ensure_ascii=False),
             json.dumps(parole, ensure_ascii=False), json.dumps(titoli, ensure_ascii=False)))
        ep_id = cur.lastrowid
        an.executemany("INSERT OR REPLACE INTO simbolo(evento_id, episodio_id, simbolo, ts, fine)"
                       " VALUES (?,?,?,?,?)",
                       [(r["evento_id"], ep_id, r["simbolo"], r["ts"], r["fine"]) for r in righe])
        ammesse = " ".join(tutte)
        an.execute("INSERT INTO episodio_fts(rowid, parole, intento) VALUES (?, ?, ?)",
                   (ep_id, ammesse, intenti.get(t0, "")))
        out[ep_id] = evs
    return out


def simbolo_di(reg, ps, evento_id: int, cache: dict) -> str:
    """Il simbolo di un evento che non ne ha uno suo (la sorgente di un legame fuori finestra,
    o un evento appunti che segue un comando di copia)."""
    if evento_id in cache:
        return cache[evento_id]
    righe = reg.execute(registro.SELEZIONE_EVENTI + " WHERE e.id = ?", (evento_id,)).fetchall()
    out = "?"
    if righe:
        ev = dict(righe[0])
        ev["det"] = registro.dettaglio(ev.get("dettaglio"))
        if ev["tipo"] == "appunti":
            out = ps.app(ev.get("bundle"), ev.get("app_nome")) + ":copia"
        else:
            out = epm.Contesto(ps).simbolo(ev) or "%s:%s" % (
                ps.app(ev.get("bundle"), ev.get("app_nome")) if ev.get("app_id") else epm.APP_FILE, ev["tipo"])
    cache[evento_id] = out
    return out


def _inserisci_legami(an, reg, ps, lista: list, ep_di: dict, eventi: list) -> int:
    cache = {e["id"]: e["_simbolo"] for e in eventi if e.get("_simbolo")}
    n = 0
    for lg in lista:
        an.execute(
            "INSERT INTO legame(tipo, da_evento, a_evento, ritardo_ms, confidenza, prova, a_ts, da_app,"
            " a_app, episodio_id, da_simbolo, a_simbolo) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (lg["tipo"], lg["da"], lg["a"], lg["ritardo_ms"], lg["confidenza"],
             json.dumps(lg["prova"], ensure_ascii=False, separators=(",", ":")), lg["a_ts"],
             lg["da_app"], lg["a_app"], ep_di.get(lg["a"]), simbolo_di(reg, ps, lg["da"], cache),
             simbolo_di(reg, ps, lg["a"], cache)))
        n += 1
    return n


def _ventagli(an) -> None:
    """Più incolla dalla stessa copia: ogni legame del gruppo dice quanti sono."""
    gruppi = an.execute("SELECT da_evento, COUNT(*) AS n FROM legame WHERE tipo = 'appunti'"
                        " GROUP BY da_evento").fetchall()
    for g in gruppi:
        for r in an.execute("SELECT id, prova FROM legame WHERE tipo = 'appunti' AND da_evento = ?",
                            (g["da_evento"],)).fetchall():
            try:
                prova = json.loads(r["prova"] or "{}")
            except ValueError:
                prova = {}
            if g["n"] > 1:
                prova["ventaglio"] = int(g["n"])
            else:
                prova.pop("ventaglio", None)
            an.execute("UPDATE legame SET prova = ? WHERE id = ?",
                       (json.dumps(prova, ensure_ascii=False, separators=(",", ":")), r["id"]))


def _indicizza_testo(reg, an, da_riga: int, da_schermo: int, firma: dict) -> None:
    """Righe e schermi nuovi, fino ai massimi della firma che diventa il cursore: uno schermo
    scritto dopo la firma lo prende il giro dopo, una volta sola."""
    for r in reg.execute("SELECT id, testo_z FROM riga WHERE id > ? AND id <= ? ORDER BY id",
                         (da_riga, firma["max_riga"])):
        t = registro.decomprimi(r["testo_z"])
        if t:
            an.execute("INSERT OR REPLACE INTO righe_fts(rowid, testo) VALUES (?, ?)", (r["id"], t))
    for s in reg.execute(
            "SELECT s.id, s.ts, s.fonte, s.aggiunte, e.app_id FROM schermo s"
            " LEFT JOIN evento e ON e.id = s.evento_id WHERE s.id > ? AND s.id <= ? ORDER BY s.id",
            (da_schermo, firma["max_schermo"])):
        try:
            ids = [int(x) for x in json.loads(s["aggiunte"] or "[]")]
        except (ValueError, TypeError):
            continue
        an.executemany("INSERT OR IGNORE INTO riga_vista(riga_id, ts, app_id, fonte, schermo_id) VALUES (?,?,?,?,?)",
                       [(i, s["ts"], s["app_id"], s["fonte"], s["id"]) for i in ids])


# --- Routine e loro stato ------------------------------------------------------------------

def ms_per_volta(r: dict) -> int:
    """Il ritmo di una routine: tempo medio di una volta. Non cresce con i giorni di registro."""
    return int(int(r.get("tempo_totale_ms") or 0) / max(1, int(r.get("volte") or 0)))


def stato_effettivo(rec, r: dict) -> str:
    """Lo stato di una routine già vista. Una rifiutata o scartata torna proposta solo se è cambiata: il
    tempo di una volta è più che raddoppiato rispetto a quando è stata rifiutata.

    Si confronta il tempo per volta, non il totale: il totale cresce da solo con i giorni
    registrati (fino ai 14 della conservazione) e farebbe tornare ogni rifiuto dei primi giorni.
    tempo_rif_ms è il tempo per volta al momento del rifiuto (melchior.rifiuta)."""
    stato = rec["stato"]
    # una scartata (Claude: non è un compito) torna con la stessa regola, e va giudicata di nuovo
    if stato in ("rifiutata", "scartata"):
        rif = rec["tempo_rif_ms"] or 0
        if rif and ms_per_volta(r) > 2 * rif:
            return "proposta"
    return stato


def _trova_stato(stati: list, r: dict, gia: set):
    firme = {rtm.firma_h(f) for f in r["forme"]}
    for rec in stati:
        if rec["id"] not in gia and rec["firma_h"] in firme:
            return rec
    for rec in stati:
        if rec["id"] in gia:
            continue
        try:
            schema = tuple(json.loads(rec["schema"] or "[]"))
        except ValueError:
            continue
        soglia = max(2, len(schema) // 4)
        for f in r["forme"]:
            if abs(len(schema) - len(f)) <= soglia and rtm.distanza(schema, tuple(f)) <= soglia:
                return rec
    return None


def sequenze_sessioni(an, dal=None, con_blocchi: bool = False) -> dict:
    """Le sequenze compresse per sessione: episodi consecutivi senza buchi oltre 5 minuti.

    Le routine si cercano sulle sessioni, non sui singoli episodi: un taglio di episodio
    nel mezzo di una routine (oggetto principale che cambia) non la spezza. Ogni token sa
    il suo episodio; il supporto conta gli episodi in cui le occorrenze iniziano.
    con_blocchi: i blocchi ripetuti di seguito diventano un token "(A + B)" (episodi.blocchi).
    """
    sql = "SELECT id, t0, t1, giorno FROM episodio"
    arg = []
    if dal:
        sql += " WHERE giorno >= ?"
        arg.append(dal)
    sql += " ORDER BY t0, id"
    eps = an.execute(sql, arg).fetchall()
    sessione_di, giorni, membri = {}, {}, {}
    sid, fine = 0, None
    for e in eps:
        if fine is None or e["t0"] - fine > epm.INATTIVITA_MS:
            sid += 1
            giorni[sid] = e["giorno"]
            membri[sid] = set()
        sessione_di[e["id"]] = sid
        membri[sid].add(e["id"])
        fine = max(fine or 0, e["t1"])
    righe = {}
    for r in an.execute("SELECT evento_id, episodio_id, simbolo, ts, fine FROM simbolo ORDER BY ts, evento_id"):
        s_id = sessione_di.get(r["episodio_id"])
        if s_id is not None:
            righe.setdefault(s_id, []).append(dict(r))
    out = {}
    for s_id, rr in righe.items():
        ep_di = {x["evento_id"]: x["episodio_id"] for x in rr}
        token = epm.comprimi(rr)
        for t in token:
            t["ep"] = ep_di[t["e0"]]
        if con_blocchi:
            token = epm.blocchi(token)
        out[s_id] = {"token": token, "giorno": giorni[s_id], "episodi": membri[s_id]}
    return out


def _routine(an) -> int:
    sequenze = sequenze_sessioni(an)
    legami = []
    for r in an.execute("SELECT tipo, a_ts, ritardo_ms, da_app, a_app, episodio_id FROM legame"):
        d = dict(r)
        d["episodio"] = d.pop("episodio_id")
        legami.append(d)
    canali = raggiungo.canali(mappa_raggiungo(an))
    trovate = rtm.scopri(sequenze, legami, canali)
    an.execute("DELETE FROM routine")
    an.execute("DELETE FROM routine_episodio")
    an.execute("UPDATE episodio SET variante = NULL")
    stati = [dict(r) for r in an.execute("SELECT * FROM routine_stato ORDER BY id")]
    oggi = dt.date.today().isoformat()
    gia = set()
    for r in trovate:
        rec = _trova_stato(stati, r, gia)
        if rec is None:
            an.execute(
                "INSERT OR IGNORE INTO routine_stato(firma_h, schema, stato, creata, aggiornata)"
                " VALUES (?, ?, 'proposta', ?, ?)",
                (r["firma_h"], json.dumps(list(r["g"]), ensure_ascii=False), oggi, oggi))
            riga = an.execute("SELECT * FROM routine_stato WHERE firma_h = ?", (r["firma_h"],)).fetchone()
            rec = dict(riga)
            if rec["id"] in gia:
                continue
            stati.append(rec)
        gia.add(rec["id"])
        stato = stato_effettivo(rec, r)
        # Una rifiutata che è cambiata torna fra le proposte, ma il rifiuto resta registrato
        # (routine_stato non cambia): la skill dice alla persona che l'aveva già rifiutata e perché.
        cambiata = 1 if rec["stato"] == "rifiutata" and stato == "proposta" else 0
        an.execute(
            "INSERT INTO routine(id, firma_h, schema, varianti, volte, episodi, giorni, lunghezza, coesione,"
            " tempo_totale_ms, n_varianti, legami_tra_app, app, raggiungibile, punteggio, avvio_a_freddo,"
            " stato, dal, al, forme, cambiata_dal_rifiuto, motivo_rifiuto)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (rec["id"], r["firma_h"], r["schema"], json.dumps(r["varianti"], ensure_ascii=False),
             r["volte"], r["episodi"], r["giorni"], r["lunghezza"], r["coesione"], r["tempo_totale_ms"],
             r["n_varianti"], r["legami_tra_app"], json.dumps(r["app"], ensure_ascii=False),
             json.dumps(r["raggiungibile"], ensure_ascii=False), r["punteggio"],
             1 if r["avvio_a_freddo"] else 0, stato, r["dal"], r["al"],
             json.dumps(r["forme"], ensure_ascii=False), cambiata, rec["motivo"] if cambiata else None))
        for o in r["occorrenze"]:
            tok = sequenze[o["sessione"]]["token"][o["i"]:o["i"] + o["n"]]
            an.execute("INSERT INTO routine_episodio(routine_id, episodio_id, e0, e1, t0, t1)"
                       " VALUES (?,?,?,?,?,?)", (rec["id"], o["ep"], tok[0]["e0"], tok[-1]["e1"],
                                                 o["t0"], o["t1"]))
            an.execute("UPDATE episodio SET variante = ? WHERE id = ? AND variante IS NULL",
                       (rec["id"], o["ep"]))
    return len(trovate)


# --- Ingresso ---------------------------------------------------------------------------

def analizza(da_zero: bool = False) -> dict:
    """Aggiorna analisi.sqlite. {"dati": None, "causa": ...} se il registro non c'è."""
    reg = registro.apri()
    if reg is None:
        return {"dati": None, "causa": registro.CAUSA_MAI_AVVIATO}
    an = apri()
    try:
        # Una sola transazione di lettura: tutte le SELECT vedono lo stesso registro, anche se il
        # registratore scrive un lotto nel frattempo (WAL). Si chiude con reg.close().
        reg.execute("BEGIN")
        firma = registro.firma_coda(reg)
        cur = _cursore(an)
        prec = cur.get("registro")
        if prec and not da_zero:
            if prec == firma:
                return {"analisi": "niente di nuovo", "da_zero": False}
            ora = registro.conteggi_fino_a(reg, prec["max_evento"], prec["max_schermo"], prec["max_riga"])
            if ora != (prec["n_eventi"], prec["n_schermo"], prec["n_riga"]):
                da_zero = True
            if prec.get("cancellazioni", 0) != firma["cancellazioni"]:
                da_zero = True
        elif not prec:
            da_zero = True
        if da_zero:
            svuota(an)
            t_inizio = None
            da_riga, da_schermo = 0, 0
        else:
            r = reg.execute("SELECT MIN(ts) FROM evento WHERE id > ?", (prec["max_evento"],)).fetchone()
            candidati = [x for x in (r[0], cur.get("max_ts")) if x is not None]
            rif = (min(candidati) if candidati else 0) - RIPRESA_MS
            r2 = an.execute("SELECT MIN(t0) FROM episodio WHERE t1 >= ?", (rif,)).fetchone()
            t_inizio = min(x for x in (rif, r2[0]) if x is not None)
            vecchi = [x[0] for x in an.execute("SELECT id FROM episodio WHERE t0 >= ?", (t_inizio,))]
            for i in range(0, len(vecchi), 500):
                b = vecchi[i:i + 500]
                q = ",".join("?" * len(b))
                an.execute("DELETE FROM episodio_fts WHERE rowid IN (%s)" % q, b)
                an.execute("DELETE FROM simbolo WHERE episodio_id IN (%s)" % q, b)
                an.execute("DELETE FROM episodio WHERE id IN (%s)" % q, b)
            an.execute("DELETE FROM simbolo WHERE ts >= ?", (t_inizio,))
            an.execute("DELETE FROM legame WHERE a_ts >= ?", (t_inizio,))
            da_riga, da_schermo = prec["max_riga"], prec["max_schermo"]
        ps = Pseudonimi(an)
        eventi = registro.eventi(reg, dal_ts=t_inizio)
        prima = registro.eventi(reg, dal_ts=t_inizio - CONTESTO_MS, al_ts=t_inizio) if t_inizio else []
        epm.prepara(eventi, ps, prima)
        eps = epm.segmenta(eventi)
        per_ep = _inserisci_episodi(an, eps, ps)
        ep_di = {e["id"]: ep for ep, evs in per_ep.items() for e in evs}
        n_leg = _inserisci_legami(an, reg, ps, lgm.calcola(reg, eventi, per_ep, ps), ep_di, eventi)
        _ventagli(an)
        _indicizza_testo(reg, an, da_riga, da_schermo, firma)
        n_rout = _routine(an)
        max_ts = reg.execute("SELECT MAX(ts) FROM evento").fetchone()[0]
        _scrivi_cursore(an, "registro", firma)
        _scrivi_cursore(an, "max_ts", max_ts)
        an.commit()
        return {"analisi": "aggiornata", "da_zero": da_zero, "episodi_rifatti": len(eps),
                "legami_nuovi": n_leg, "routine": n_rout}
    finally:
        an.close()
        reg.close()
