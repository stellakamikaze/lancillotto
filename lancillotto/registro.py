"""Lettura di registro.sqlite, e le sole scritture ammesse (docs/CONTRATTO.md).

Lettura: PRAGMA query_only=1, mai mode=ro (con WAL fallisce se mancano -shm e -wal).
Scrittura, solo per: dimentica un intervallo, cancella tutto, escludi un'app o un sito
all'indietro, e inserire una richiesta di consenso. Tutto il resto lo scrive il registratore.
"""
from __future__ import annotations

import json
import re
import secrets
import sqlite3
import zlib

from . import percorsi

SCHEMA_SUPPORTATA = 1
CAUSA_MAI_AVVIATO = "registratore mai avviato"
CAUSA_VUOTO = "registro vuoto: il registratore non ha ancora scritto lo schema"
CONSENSO_VALIDITA_MS = 600000


class SchemaTroppoNuovo(Exception):
    """Il registro ha uno schema più nuovo di quello che questo lettore conosce."""


class RegistroVuoto(Exception):
    """Il file c'è ma non ha ancora la tabella meta."""


def apri(scrittura: bool = False):
    """La connessione al registro, oppure None se il file non esiste (mai avviato).

    Solleva SchemaTroppoNuovo o RegistroVuoto. Non crea mai il file.
    """
    p = percorsi.registro()
    if not p.exists():
        return None
    conn = sqlite3.connect(str(p), timeout=5.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=5000")
    if scrittura:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA secure_delete=ON")
    else:
        conn.execute("PRAGMA query_only=1")
    try:
        controlla_versione(conn)
    except Exception:
        conn.close()
        raise
    return conn


def controlla_versione(conn) -> int:
    try:
        riga = conn.execute("SELECT valore FROM meta WHERE chiave='schema_versione'").fetchone()
    except sqlite3.DatabaseError:
        raise RegistroVuoto(CAUSA_VUOTO)
    if riga is None:
        raise RegistroVuoto(CAUSA_VUOTO)
    try:
        v = int(str(riga[0]).strip())
    except ValueError:
        raise RegistroVuoto("schema_versione illeggibile nel registro")
    if v > SCHEMA_SUPPORTATA:
        raise SchemaTroppoNuovo(
            "il registro ha lo schema %d, questa CLI legge fino allo schema %d: "
            "aggiorna Lancillotto" % (v, SCHEMA_SUPPORTATA))
    return v


def meta(conn) -> dict:
    return {r[0]: r[1] for r in conn.execute("SELECT chiave, valore FROM meta")}


def decomprimi(b):
    """Testo da DEFLATE raw (Apple COMPRESSION_ZLIB). None se vuoto o illeggibile."""
    if b is None:
        return None
    try:
        return zlib.decompress(bytes(b), -15).decode("utf-8", "replace")
    except (zlib.error, TypeError):
        return None


def comprimi(testo: str) -> bytes:
    """Il contrario di decomprimi: serve ai test e alla fabbrica."""
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(testo.encode("utf-8")) + c.flush()


def dettaglio(testo):
    if not testo:
        return {}
    try:
        d = json.loads(testo)
    except ValueError:
        return {}
    return d if isinstance(d, dict) else {}


SELEZIONE_EVENTI = (
    "SELECT e.id, e.ts, e.dur_ms, e.tipo, e.app_id, e.ogg_id, e.dettaglio, e.cc, e.tasti, e.click,"
    " a.bundle, a.nome AS app_nome, a.esclusa,"
    " o.tipo AS o_tipo, o.chiave_h, o.etichetta, o.dominio, o.ext, o.inode, o.cartella, o.provenienza"
    " FROM evento e LEFT JOIN app a ON a.id = e.app_id LEFT JOIN oggetto o ON o.id = e.ogg_id")


def eventi(conn, dal_ts=None, al_ts=None) -> list:
    """Gli eventi come dizionari, in ordine di tempo, con app e oggetto già uniti."""
    sql = SELEZIONE_EVENTI
    cond, arg = [], []
    if dal_ts is not None:
        cond.append("e.ts >= ?")
        arg.append(int(dal_ts))
    if al_ts is not None:
        cond.append("e.ts < ?")
        arg.append(int(al_ts))
    if cond:
        sql += " WHERE " + " AND ".join(cond)
    sql += " ORDER BY e.ts, e.id"
    out = []
    for r in conn.execute(sql, arg):
        d = dict(r)
        d["det"] = dettaglio(d.get("dettaglio"))
        out.append(d)
    return senza_eco_menu(out)


# Una scorciatoia (cmd+v, cmd+a, cmd+w) fa lampeggiare la sua voce di menu, e il registratore annota
# anche quella: "Modifica > Incolla" arriva 7-250 ms dopo il cmd+v, nella stessa app. Contati tutti e due,
# un incolla diventava due incolla e gonfiava legami e routine (#3939).
ECO_MENU_MS = 1000


def senza_eco_menu(eventi: list) -> list:
    """Toglie la voce di menu che segue subito una scorciatoia nella stessa app."""
    out = []
    for ev in eventi:
        prima = out[-1] if out else None
        if (ev["tipo"] == "menu" and prima is not None and prima["tipo"] == "comando"
                and prima["app_id"] == ev["app_id"] and 0 <= ev["ts"] - prima["ts"] <= ECO_MENU_MS):
            continue
        out.append(ev)
    return out


def cancellazioni(conn) -> int:
    """meta.cancellazioni: sale a ogni cancellazione, dal registratore o dalla CLI (docs/CONTRATTO.md)."""
    r = conn.execute("SELECT valore FROM meta WHERE chiave = 'cancellazioni'").fetchone()
    try:
        return int(r[0]) if r is not None else 0
    except (TypeError, ValueError):
        return 0


def _conta_cancellazione(conn) -> None:
    conn.execute("INSERT INTO meta(chiave, valore) VALUES ('cancellazioni', '1') ON CONFLICT(chiave)"
                 " DO UPDATE SET valore = CAST(CAST(valore AS INTEGER) + 1 AS TEXT)")


def firma_coda(conn) -> dict:
    """Ciò che serve all'analisi incrementale per sapere se il registro è cambiato.

    cancellazioni: se cambia, qualcosa è stato cancellato e gli id di riga e schermo possono
    essere stati riusati: l'analisi riparte da zero anche se i conteggi tornano uguali."""
    r = conn.execute("SELECT COALESCE(MAX(id), 0), COUNT(*) FROM evento").fetchone()
    max_id, n = int(r[0]), int(r[1])
    s = conn.execute("SELECT COALESCE(SUM(dur_ms), 0) FROM evento WHERE id > ?",
                     (max_id - 500,)).fetchone()[0]
    rs = conn.execute("SELECT COALESCE(MAX(id), 0), COUNT(*) FROM schermo").fetchone()
    rr = conn.execute("SELECT COALESCE(MAX(id), 0), COUNT(*) FROM riga").fetchone()
    return {"max_evento": max_id, "n_eventi": n, "dur_coda": int(s),
            "max_schermo": int(rs[0]), "n_schermo": int(rs[1]),
            "max_riga": int(rr[0]), "n_riga": int(rr[1]), "cancellazioni": cancellazioni(conn)}


def conteggi_fino_a(conn, max_evento: int, max_schermo: int, max_riga: int) -> tuple:
    """Quante righe ci sono ancora fino agli id già analizzati: se calano, qualcosa è stato cancellato."""
    a = conn.execute("SELECT COUNT(*) FROM evento WHERE id <= ?", (max_evento,)).fetchone()[0]
    b = conn.execute("SELECT COUNT(*) FROM schermo WHERE id <= ?", (max_schermo,)).fetchone()[0]
    c = conn.execute("SELECT COUNT(*) FROM riga WHERE id <= ?", (max_riga,)).fetchone()[0]
    return int(a), int(b), int(c)


# --- Scritture ammesse: cancellazioni ------------------------------------------------------

def _cancella_eventi(conn, condizione: str, arg: tuple) -> int:
    """Cancella gli eventi che rispettano la condizione, con figli espliciti (anche a FK spente)."""
    sotto = "SELECT id FROM evento WHERE " + condizione
    conn.execute("DELETE FROM campo WHERE evento_id IN (%s)" % sotto, arg)
    conn.execute("DELETE FROM impronta WHERE evento_id IN (%s)" % sotto, arg)
    conn.execute("DELETE FROM schermo WHERE evento_id IN (%s)" % sotto, arg)
    cur = conn.execute("DELETE FROM evento WHERE " + condizione, arg)
    return cur.rowcount if cur.rowcount is not None else 0


def _pulisci_orfani(conn) -> dict:
    """Righe di schermo che nessuno schermo nomina più: via. Oggetti senza eventi: etichetta tolta.

    Gli oggetti non si cancellano: il registratore può tenerne l'id in memoria.
    """
    usate = set()
    for (agg,) in conn.execute("SELECT aggiunte FROM schermo"):
        try:
            for x in json.loads(agg or "[]"):
                usate.add(int(x))
        except (ValueError, TypeError):
            continue
    tutte = [r[0] for r in conn.execute("SELECT id FROM riga")]
    via = [i for i in tutte if i not in usate]
    for i in range(0, len(via), 500):
        blocco = via[i:i + 500]
        conn.execute("DELETE FROM riga WHERE id IN (%s)" % ",".join("?" * len(blocco)), blocco)
    cur = conn.execute(
        "UPDATE oggetto SET etichetta = NULL, provenienza = NULL WHERE etichetta IS NOT NULL"
        " AND id NOT IN (SELECT ogg_id FROM evento WHERE ogg_id IS NOT NULL)"
        " AND id NOT IN (SELECT finestra_id FROM schermo WHERE finestra_id IS NOT NULL)")
    return {"righe": len(via), "oggetti_svuotati": cur.rowcount or 0}


def _chiudi_scrittura(conn) -> None:
    conn.commit()
    try:
        conn.execute("PRAGMA incremental_vacuum")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except sqlite3.DatabaseError:
        pass


def dimentica(conn, da_ms: int, a_ms: int) -> dict:
    """Cancella eventi, campi, impronte, schermi e righe orfane nell'intervallo [da, a].

    Un evento iniziato prima e che entra nell'intervallo (una finestra allungata dal battito)
    si accorcia all'inizio dell'intervallo, come fa il registratore."""
    da, a = int(da_ms), int(a_ms)
    n = _cancella_eventi(conn, "ts >= ? AND ts <= ?", (da, a))
    conn.execute("UPDATE evento SET dur_ms = ? - ts WHERE ts < ? AND ts + dur_ms > ?", (da, da, da))
    conn.execute("DELETE FROM schermo WHERE ts >= ? AND ts <= ?", (da, a))
    orfani = _pulisci_orfani(conn)
    _conta_cancellazione(conn)
    _chiudi_scrittura(conn)
    return {"eventi": n, "righe": orfani["righe"]}


LAPIDE = "~cancellato"


def cancella_tutto(conn) -> dict:
    """Cancella tutto. In app, oggetto e riga resta una lapide vuota con l'id più alto + 1.

    Il registratore tiene in memoria gli id di app, oggetti e righe. Senza lapide SQLite
    riparte da 1, e un id vecchio in memoria punterebbe a una riga nuova di un'altra app.
    Con la lapide gli id nuovi stanno sopra i vecchi: un id vecchio non esiste più, il vincolo
    di chiave esterna fallisce e il registratore svuota la sua memoria (docs/CONTRATTO.md).
    """
    n = conn.execute("SELECT COUNT(*) FROM evento").fetchone()[0]
    massimi = {t: conn.execute("SELECT MAX(id) FROM %s" % t).fetchone()[0] for t in ("app", "oggetto", "riga")}
    for tabella in ("campo", "impronta", "schermo", "riga", "evento", "oggetto", "app",
                    "salute", "giorno", "consenso"):
        conn.execute("DELETE FROM %s" % tabella)
    if massimi["app"] is not None:
        conn.execute("INSERT INTO app(id, bundle, nome, esclusa) VALUES (?, ?, NULL, 0)", (massimi["app"] + 1, LAPIDE))
    if massimi["oggetto"] is not None:
        conn.execute("INSERT INTO oggetto(id, tipo, chiave_h) VALUES (?, 'lapide', ?)", (massimi["oggetto"] + 1, LAPIDE))
    if massimi["riga"] is not None:
        conn.execute("INSERT INTO riga(id, h, testo_z, lunghezza, prima_ts, ultima_ts, volte) VALUES (?, ?, ?, 0, 0, 0, 0)",
                     (massimi["riga"] + 1, LAPIDE, comprimi("")))
    _conta_cancellazione(conn)
    _chiudi_scrittura(conn)
    return {"eventi": int(n)}


def _parole(s: str) -> list:
    return [w for w in re.split(r"[^\w]+", (s or "").lower()) if w]


def nome_corrisponde(nome_app: str, cercato: str) -> bool:
    """"Chrome" va con "Google Chrome", "Outlook" con "Microsoft Outlook": nome uguale, oppure
    tutte le parole cercate dentro il nome, nello stesso ordine e di seguito."""
    a, c = _parole(nome_app), _parole(cercato)
    if not a or not c:
        return False
    if a == c:
        return True
    for i in range(len(a) - len(c) + 1):
        if a[i:i + len(c)] == c:
            return True
    return False


def app_corrispondenti(conn, nome: str) -> list:
    """Le app del registro che corrispondono a NOME: bundle uguale o con quel prefisso, nome
    uguale o che contiene le parole di NOME, oppure il nome breve che l'uscita mostra a Claude
    ("Chrome", "Excel": pseudonimi.NOMI_APP)."""
    from . import pseudonimi
    n = (nome or "").strip()
    if not n:
        return []
    out = []
    for r in conn.execute("SELECT id, bundle, nome FROM app WHERE bundle != ?", (LAPIDE,)).fetchall():
        b = r["bundle"] or ""
        if (b.lower() == n.lower() or b.lower().startswith(n.lower() + ".")
                or nome_corrisponde(r["nome"] or "", n)
                or nome_corrisponde(pseudonimi.NOMI_APP.get(b, ""), n)):
            out.append(dict(r))
    return out


def escludi_app(conn, nome: str) -> dict:
    """Escludi all'indietro: cancella gli eventi dell'app, segna l'app come esclusa."""
    trovate = app_corrispondenti(conn, nome)
    n = 0
    for a in trovate:
        n += _cancella_eventi(conn, "app_id = ?", (a["id"],))
        conn.execute("UPDATE app SET esclusa = 1 WHERE id = ?", (a["id"],))
    orfani = _pulisci_orfani(conn)
    _conta_cancellazione(conn)
    _chiudi_scrittura(conn)
    return {"app": [a["bundle"] for a in trovate], "eventi": n, "righe": orfani["righe"]}


def _dominio_corrisponde(d, suffisso: str) -> bool:
    d = (d or "").lower().strip(".")
    s = suffisso.lower().strip(".")
    return bool(d) and (d == s or d.endswith("." + s))


def escludi_dominio(conn, dominio: str) -> dict:
    """Escludi un sito all'indietro: gli eventi url di quel dominio e tutto ciò che la stessa
    app ha registrato mentre era su quel dominio (titoli, campi, clic, testo). Poi i download
    che vengono da quel sito (eventi file_* senza app, oggetto.provenienza): via gli eventi,
    e gli oggetti perdono nome e provenienza."""
    corrente = {}
    ultima_finestra = {}
    da_cancellare = []
    for r in conn.execute(
            "SELECT e.id, e.ts, e.tipo, e.app_id, o.dominio FROM evento e"
            " LEFT JOIN oggetto o ON o.id = e.ogg_id WHERE e.app_id IS NOT NULL ORDER BY e.ts, e.id"):
        if r["tipo"] == "url":
            corrente[r["app_id"]] = r["dominio"]
            f = ultima_finestra.get(r["app_id"])
            # la finestra arriva un attimo prima dell'url: il suo titolo è già della pagina esclusa
            if f is not None and r["ts"] - f[1] <= 10000 and _dominio_corrisponde(r["dominio"], dominio):
                da_cancellare.append(f[0])
        if r["tipo"] == "finestra":
            ultima_finestra[r["app_id"]] = (r["id"], r["ts"])
        if _dominio_corrisponde(corrente.get(r["app_id"]), dominio):
            da_cancellare.append(r["id"])
    oggetti_scaricati = [r["id"] for r in conn.execute(
        "SELECT id, provenienza FROM oggetto WHERE tipo = 'file' AND provenienza IS NOT NULL").fetchall()
        if _dominio_corrisponde(r["provenienza"], dominio)]
    for i in range(0, len(oggetti_scaricati), 500):
        blocco = oggetti_scaricati[i:i + 500]
        q = ",".join("?" * len(blocco))
        da_cancellare += [r[0] for r in conn.execute(
            "SELECT id FROM evento WHERE tipo LIKE 'file\\_%%' ESCAPE '\\' AND ogg_id IN (%s)" % q, blocco)]
        conn.execute("UPDATE oggetto SET etichetta = NULL, provenienza = NULL WHERE id IN (%s)" % q, blocco)
        conn.execute("DELETE FROM impronta WHERE fonte = 'file' AND evento_id IN"
                     " (SELECT id FROM evento WHERE ogg_id IN (%s))" % q, blocco)
    da_cancellare = sorted(set(da_cancellare))
    n = 0
    for i in range(0, len(da_cancellare), 500):
        blocco = da_cancellare[i:i + 500]
        n += _cancella_eventi(conn, "id IN (%s)" % ",".join("?" * len(blocco)), tuple(blocco))
    orfani = _pulisci_orfani(conn)
    _conta_cancellazione(conn)
    _chiudi_scrittura(conn)
    return {"eventi": n, "righe": orfani["righe"]}


# --- Scritture ammesse: consenso L2 ----------------------------------------------------------

def inserisci_consenso(conn, t0: int, t1: int, descrizione: str, ora_ms: int) -> str:
    ident = secrets.token_hex(8)
    conn.execute(
        "INSERT INTO consenso(id, t0, t1, descrizione, richiesto_ts) VALUES (?, ?, ?, ?, ?)",
        (ident, int(t0), int(t1), descrizione, int(ora_ms)))
    conn.commit()
    return ident


def consensi(conn) -> list:
    return [dict(r) for r in conn.execute(
        "SELECT id, t0, t1, descrizione, richiesto_ts, deciso, deciso_ts, scade_ts FROM consenso"
        " ORDER BY richiesto_ts DESC")]


def valuta_consenso(righe: list, t0: int, t1: int, ora_ms: int) -> dict:
    """Decide se il testo di [t0, t1] si può dare. Ritorna {"esito": ..., ...}.

    esito: "valido" (con l'id), "in_attesa" (richiesta uguale non ancora decisa),
    "negato" (con motivo: rifiutato, scaduto, fuori_intervallo), "nessuno".
    """
    copre = [r for r in righe if r["t0"] <= t0 and t1 <= r["t1"]]
    for r in copre:
        if r["deciso"] == 1 and r["scade_ts"] is not None and ora_ms < int(r["scade_ts"]):
            return {"esito": "valido", "id": r["id"], "scade_ts": int(r["scade_ts"])}
    for r in righe:
        if r["deciso"] is None and r["t0"] == t0 and r["t1"] == t1:
            return {"esito": "in_attesa", "id": r["id"], "descrizione": r["descrizione"]}
    if copre:
        ultimo = copre[0]
        if ultimo["deciso"] == 0:
            return {"esito": "negato", "motivo": "rifiutato", "id": ultimo["id"]}
        if ultimo["deciso"] == 1:
            return {"esito": "negato", "motivo": "scaduto", "id": ultimo["id"]}
    validi_altrove = [r for r in righe if r["deciso"] == 1 and r["scade_ts"] is not None
                      and ora_ms < int(r["scade_ts"])]
    if validi_altrove:
        return {"esito": "negato", "motivo": "fuori_intervallo", "id": validi_altrove[0]["id"]}
    return {"esito": "nessuno"}


# --- Peso dei dati di un giorno --------------------------------------------------------------

def peso_giorno(conn, inizio_ms: int, fine_ms: int) -> int:
    """Stima in byte dei dati di [inizio, fine): dettagli e righe degli eventi, valori dei campi,
    testo delle righe di schermo comparse quel giorno, delta delle istantanee, impronte.

    giorno.byte è il peso di tutto il file (docs/CONTRATTO.md): con la conservazione a regime la
    crescita da ieri a oggi è vicina a zero o negativa, quindi non dice quanto pesa oggi.
    """
    a = (int(inizio_ms), int(fine_ms))
    eventi = conn.execute("SELECT COALESCE(SUM(LENGTH(COALESCE(dettaglio, ''))), 0) + COUNT(*) * 48 FROM evento"
                          " WHERE ts >= ? AND ts < ?", a).fetchone()[0]
    campi = conn.execute("SELECT COALESCE(SUM(LENGTH(COALESCE(c.valore_z, '')) + LENGTH(COALESCE(c.etichetta, ''))), 0)"
                         " + COUNT(*) * 32 FROM campo c JOIN evento e ON e.id = c.evento_id"
                         " WHERE e.ts >= ? AND e.ts < ?", a).fetchone()[0]
    righe = conn.execute("SELECT COALESCE(SUM(LENGTH(testo_z)), 0) + COUNT(*) * 64 FROM riga"
                         " WHERE prima_ts >= ? AND prima_ts < ?", a).fetchone()[0]
    schermi = conn.execute("SELECT COALESCE(SUM(LENGTH(aggiunte) + LENGTH(tolte)), 0) + COUNT(*) * 48 FROM schermo"
                           " WHERE ts >= ? AND ts < ?", a).fetchone()[0]
    impronte = conn.execute("SELECT COUNT(*) * 72 FROM impronta i JOIN evento e ON e.id = i.evento_id"
                            " WHERE e.ts >= ? AND e.ts < ?", a).fetchone()[0]
    return int(eventi + campi + righe + schermi + impronte)
