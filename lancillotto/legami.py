"""Legami fra eventi (docs/PROGETTAZIONE.md, sezione 5, punto 3).

Le regole normalizzano soltanto: ogni legame ha tipo, da, a, ritardo, confidenza e una prova
in JSON corto. Il giudizio lo dà Claude.

  appunti        incolla con cc = N  ──>  ultimo evento appunti prima dell'incolla, se ha cc = N
                 0,95 con copia esplicita nell'app sorgente, 0,7 senza, 0,4 da app in secondo
                 piano; oltre 30 minuti "altro_compito"; più incolla dallo stesso N = ventaglio
                 copia esplicita in un'ALTRA app nei 3 s prima (cmd+c, poi cmd+tab prima del
                 controllo degli appunti ogni 0,5 s): la sorgente è quella copia, in quell'app
                 nessuna copia, nessun comando, menu o clic nei 3 s prima nell'app attiva: il cambio
                 viene da fuori (Universal Clipboard, gestore di appunti) -> sfondo, 0,4
                 cc diverso (copia non vista: pausa, app esclusa, prima dell'avvio) -> nessun legame
  download       file nuovo in Download con provenienza X -> ultimo url con dominio X (2 ore),
                 altrimenti la finestra di Mail in primo piano
  file           stesso inode: crea, apri, modifica, sposta; upload stimato a 0,4 dichiarato
  stesso_oggetto stessa impronta in due app nello stesso episodio
  riuso          impronta vista in A ricompare entro 30 minuti in un campo compilato in B
"""
from __future__ import annotations

from . import episodi as epm
from . import pseudonimi
from .registro import dettaglio

ALTRO_COMPITO_MS = 30 * 60000
DOWNLOAD_MS = 2 * 3600000
RIUSO_MS = 30 * 60000
UPLOAD_MS = 10 * 60000
AUTOSALVATAGGIO_MS = 5 * 60000
TIPI_FILE = ("documento", "file_crea", "file_mod", "file_sposta", "file_elimina")
ETICHETTE_UPLOAD = {"carica", "upload", "choose", "scegli", "scegli file", "choose file",
                    "allega", "attach", "sfoglia", "browse", "apri", "open", "invia file"}


def _legame(tipo, da, conf, prova, a_ev, da_app=None, ritardo=None):
    return {"tipo": tipo, "da": int(da["id"]), "a": int(a_ev["id"]),
            "ritardo_ms": int(ritardo if ritardo is not None else a_ev["ts"] - da["ts"]),
            "confidenza": round(float(conf), 2), "prova": prova, "a_ts": int(a_ev["ts"]),
            "da_app": da_app if da_app is not None else da.get("app_id"),
            "a_app": a_ev.get("app_id")}


def primo_piano(conn, ts: int):
    r = conn.execute("SELECT app_id, id, ts FROM evento WHERE tipo = 'finestra' AND ts <= ?"
                     " ORDER BY ts DESC, id DESC LIMIT 1", (int(ts),)).fetchone()
    return r


def sorgente_appunti(conn, ev: dict):
    """L'evento appunti che ha portato il contatore al cc dell'incolla, oppure None.

    È l'ultimo evento appunti prima dell'incolla: se il suo cc è diverso, il cambio
    che l'incolla porta non è stato visto, e non c'è legame.
    """
    r = conn.execute(
        "SELECT id, ts, app_id, cc, dettaglio FROM evento WHERE tipo = 'appunti'"
        " AND (ts < ? OR (ts = ? AND id < ?)) ORDER BY ts DESC, id DESC LIMIT 1",
        (ev["ts"], ev["ts"], ev["id"])).fetchone()
    if r is None or r["cc"] is None or ev.get("cc") is None or int(r["cc"]) != int(ev["cc"]):
        return None
    return dict(r)


def copia_esplicita(conn, src: dict):
    """Il modo della copia nell'app sorgente nei 3 secondi prima: "comando", "menu" o None."""
    for r in conn.execute(
            "SELECT tipo, dettaglio FROM evento WHERE app_id IS ? AND tipo IN ('comando', 'menu')"
            " AND ts >= ? AND ts <= ? ORDER BY ts DESC", (src["app_id"], src["ts"] - 3000,
                                                          src["ts"] + 500)):
        finto = {"tipo": r["tipo"], "det": dettaglio(r["dettaglio"])}
        if epm.e_copia(finto):
            return r["tipo"]
    return None


def copia_altrove(conn, src: dict):
    """La copia esplicita (comando o menu) in un'altra app nei 3 secondi prima del cambio degli
    appunti, oppure None. Il registratore attribuisce il cambio all'app attiva al controllo, che
    dopo un cmd+tab rapido è già quella nuova."""
    for r in conn.execute(
            "SELECT id, ts, app_id, tipo, dettaglio FROM evento WHERE tipo IN ('comando', 'menu')"
            " AND app_id IS NOT NULL AND app_id IS NOT ? AND ts >= ? AND ts <= ? ORDER BY ts DESC, id DESC",
            (src["app_id"], src["ts"] - 3000, src["ts"])):
        if epm.e_copia({"tipo": r["tipo"], "det": dettaglio(r["dettaglio"])}):
            return dict(r)
    return None


def input_recente(conn, src: dict) -> bool:
    """Un comando, una voce di menu o un clic nell'app del cambio, nei 3 secondi prima."""
    r = conn.execute("SELECT 1 FROM evento WHERE app_id IS ? AND tipo IN ('comando', 'menu', 'clic')"
                     " AND ts >= ? AND ts <= ? LIMIT 1", (src["app_id"], src["ts"] - 3000, src["ts"])).fetchone()
    return r is not None


def appunti(conn, eventi: list) -> list:
    out = []
    for ev in eventi:
        if not epm.e_incolla(ev) or ev.get("cc") is None:
            continue
        src = sorgente_appunti(conn, ev)
        if src is None:
            continue
        det = dettaglio(src.get("dettaglio"))
        if det.get("riservato"):
            continue
        modo = copia_esplicita(conn, src)
        altrove = copia_altrove(conn, src) if modo is None else None
        if altrove is not None:
            # cmd+c in A e cambio d'app prima del controllo: la sorgente è la copia in A
            prova = {"cc": int(ev["cc"]), "copia": altrove["tipo"], "app_cambiata": 1}
            if ev["ts"] - altrove["ts"] > ALTRO_COMPITO_MS:
                prova["altro_compito"] = 1
            out.append(_legame("appunti", altrove, 0.95, prova, ev))
            continue
        fp = primo_piano(conn, src["ts"])
        sfondo = src["app_id"] is None or (fp is not None and fp["app_id"] != src["app_id"])
        if not sfondo and modo is None and not input_recente(conn, src):
            # nessuno ha copiato qui: il contenuto arriva da fuori
            sfondo = True
        if sfondo:
            conf = 0.4
        elif modo:
            conf = 0.95
        else:
            conf = 0.7
        prova = {"cc": int(ev["cc"]), "copia": modo or "senza_comando"}
        if sfondo:
            prova["sfondo"] = 1
        if ev["ts"] - src["ts"] > ALTRO_COMPITO_MS:
            prova["altro_compito"] = 1
        out.append(_legame("appunti", src, conf, prova, ev))
    return out


def download(conn, eventi: list, ps) -> list:
    out = []
    for ev in eventi:
        if ev["tipo"] != "file_crea" or ev.get("cartella") != "download":
            continue
        prov = (ev.get("provenienza") or "").lower()
        trovato = None
        if prov:
            candidati = conn.execute(
                "SELECT e.id, e.ts, e.app_id, o.dominio FROM evento e JOIN oggetto o ON o.id = e.ogg_id"
                " WHERE e.tipo = 'url' AND e.ts <= ? AND e.ts >= ? ORDER BY e.ts DESC, e.id DESC",
                (ev["ts"], ev["ts"] - DOWNLOAD_MS)).fetchall()
            for c in candidati:
                d = (c["dominio"] or "").lower()
                if d and (d == prov or d.endswith("." + prov) or prov.endswith("." + d)):
                    trovato = c
                    break
            if trovato is None:
                for c in candidati:
                    if pseudonimi.registrabile(c["dominio"] or "") == pseudonimi.registrabile(prov):
                        trovato = c
                        break
        if trovato is not None:
            out.append(_legame("download", dict(trovato), 0.9,
                               {"provenienza": ps.sito(prov)}, ev))
            continue
        fp = primo_piano(conn, ev["ts"])
        if fp is not None:
            a = conn.execute("SELECT bundle FROM app WHERE id = ?", (fp["app_id"],)).fetchone()
            if a is not None and a["bundle"] == "com.apple.mail":
                out.append(_legame("download", {"id": fp["id"], "ts": fp["ts"],
                                                "app_id": fp["app_id"]}, 0.6,
                                   {"mail": 1}, ev))
    return out


def file(conn, eventi: list) -> list:
    out = []
    for ev in eventi:
        if ev["tipo"] not in TIPI_FILE or not ev.get("inode"):
            continue
        prec = conn.execute(
            "SELECT e.id, e.ts, e.tipo, e.app_id FROM evento e JOIN oggetto o ON o.id = e.ogg_id"
            " WHERE o.inode = ? AND e.tipo IN ('documento', 'file_crea', 'file_mod', 'file_sposta',"
            " 'file_elimina') AND (e.ts < ? OR (e.ts = ? AND e.id < ?))"
            " ORDER BY e.ts DESC, e.id DESC LIMIT 1",
            (ev["inode"], ev["ts"], ev["ts"], ev["id"])).fetchone()
        if prec is None:
            continue
        if prec["tipo"] == ev["tipo"] and ev["ts"] - prec["ts"] < AUTOSALVATAGGIO_MS:
            continue
        out.append(_legame("file", dict(prec), 0.9,
                           {"inode": "uguale", "da": prec["tipo"], "a": ev["tipo"]}, ev))
    for ev in eventi:
        if ev["tipo"] != "clic":
            continue
        etichetta = str(ev["det"].get("etichetta") or "").strip().lower().rstrip("…. ")
        if etichetta not in ETICHETTE_UPLOAD:
            continue
        prec = conn.execute(
            "SELECT id, ts, app_id FROM evento WHERE tipo IN ('documento', 'file_crea', 'file_mod',"
            " 'file_sposta') AND ts <= ? AND ts >= ? ORDER BY ts DESC, id DESC LIMIT 1",
            (ev["ts"], ev["ts"] - UPLOAD_MS)).fetchone()
        if prec is not None:
            out.append(_legame("file", dict(prec), 0.4, {"upload": "stima"}, ev))
    return out


def stesso_oggetto(conn, episodi_eventi: dict) -> list:
    """episodi_eventi: episodio -> lista di eventi. Stessa impronta in due app dello stesso episodio.

    Le impronte si prendono da tutti gli eventi nell'intervallo dell'episodio, non solo da quelli
    con un simbolo: il testo a schermo (schermo), la selezione alla copia (appunti dopo un cmd+c)
    e il documento di ritorno non hanno simbolo ma portano le impronte."""
    out = []
    for _ep, evs in episodi_eventi.items():
        if not evs:
            continue
        per_id = {e["id"]: e for e in evs}
        t0 = min(e["ts"] for e in evs)
        t1 = max(e["ts"] for e in evs)
        gruppi = {}
        for r in conn.execute(
                "SELECT i.h, i.tipo, e.id, e.ts, e.app_id FROM impronta i JOIN evento e ON e.id = i.evento_id"
                " WHERE e.ts >= ? AND e.ts <= ?", (t0, t1)):
            e = per_id.get(r["id"]) or {"id": r["id"], "ts": r["ts"], "app_id": r["app_id"]}
            gruppi.setdefault((r["h"], r["tipo"]), []).append(e)
        for (_h, tipo), lista in gruppi.items():
            lista.sort(key=lambda e: (e["ts"], e["id"]))
            prima_per_app = {}
            for e in lista:
                prima_per_app.setdefault(e.get("app_id"), e)
            if len(prima_per_app) < 2:
                continue
            ordinate = sorted(prima_per_app.values(), key=lambda e: (e["ts"], e["id"]))
            origine = ordinate[0]
            for e in ordinate[1:]:
                out.append(_legame("stesso_oggetto", origine, 0.8, {"impronta": tipo}, e))
    return out


def riuso(conn, eventi: list) -> list:
    out = []
    for ev in eventi:
        if ev["tipo"] != "campo_valore":
            continue
        visti = set()
        for imp in conn.execute("SELECT h, tipo FROM impronta WHERE evento_id = ? AND fonte = 'campo'",
                                (ev["id"],)).fetchall():
            r = conn.execute(
                "SELECT e.id, e.ts, e.app_id, i.fonte FROM impronta i JOIN evento e ON e.id = i.evento_id"
                " WHERE i.h = ? AND i.fonte IN ('titolo', 'file', 'selezione', 'schermo')"
                " AND e.ts >= ? AND e.ts <= ? AND (e.app_id IS NULL OR e.app_id IS NOT ?)"
                " ORDER BY e.ts DESC, e.id DESC LIMIT 1",
                (imp["h"], ev["ts"] - RIUSO_MS, ev["ts"], ev.get("app_id"))).fetchone()
            if r is None or r["id"] in visti:
                continue
            visti.add(r["id"])
            out.append(_legame("riuso", dict(r), 0.85,
                               {"impronta": imp["tipo"], "fonte": r["fonte"]}, ev))
    return out


def calcola(conn, eventi: list, episodi_eventi: dict, ps) -> list:
    """Tutti i legami che arrivano negli eventi dati (la sorgente può stare prima)."""
    return (appunti(conn, eventi) + download(conn, eventi, ps) + file(conn, eventi)
            + stesso_oggetto(conn, episodi_eventi) + riuso(conn, eventi))
