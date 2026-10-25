"""Prove per Claude: 'verifica --sql' sulle sole viste v_* e 'conta' di un pattern di simboli.

verifica: l'SQL gira su analisi.sqlite (mai sul registro) con PRAGMA query_only e un
set_authorizer che ammette solo SELECT, letture delle sole colonne che le viste v_* espongono
(COLONNE_VISTE, qualunque sia la sorgente) e funzioni innocue. Il nome della sorgente non conta:
una CTE si può chiamare v_x o v_evento e leggere ogni tabella, quindi l'authorizer guarda la
coppia (tabella, colonna) letta davvero. ATTACH, PRAGMA, scritture, CTE ricorsive e
load_extension/readfile/writefile sono rifiutati. Tetto di 200 righe e di passi della macchina virtuale.

conta: "Mail:apri_allegato:pdf > Anteprima:copia > Chrome:incolla:*". Ogni voce è un simbolo
con i jolly di fnmatch; "*" da sola vale un simbolo qualsiasi, "**" una sequenza qualsiasi
(anche vuota). Le ripetizioni "×6" si ignorano: non si controllano. Si contano le occorrenze
senza sovrapposizione sulle sessioni (come le routine), poi episodi e giorni distinti.

conta --routine ID: tutte le forme della routine (routine.forme), ognuna alla lettera, senza
contare due volte lo stesso tratto. Lo schema da solo è la forma più frequente, con la coda
di rumore: contato a mano dà meno volte della routine, e non è una smentita.
"""
from __future__ import annotations

import fnmatch
import json
import re
import sqlite3

from . import percorsi

TETTO_RIGHE = 200
TETTO_PASSI = 2000000
FUNZIONI_VIETATE = {"load_extension", "readfile", "writefile", "edit", "fts3_tokenizer", "zipfile",
                    "sqlar_compress", "sqlar_uncompress", "sqlite_compileoption_get",
                    "sqlite_compileoption_used", "fts5_source_id", "shell_add_schema", "lsmode"}

# Le colonne che le viste v_* espongono (analisi.SCHEMA): le sole letture ammesse.
COLONNE_VISTE = {
    "simbolo": {"evento_id", "episodio_id", "simbolo", "ts"},
    "episodio": {"id", "t0", "t1", "attivo_ms", "giorno", "firma", "n_simboli", "variante", "app", "principale"},
    "legame": {"tipo", "da_evento", "a_evento", "ritardo_ms", "confidenza", "episodio_id"},
    "routine": {"id", "schema", "volte", "episodi", "giorni", "n_varianti", "tempo_totale_ms", "punteggio", "stato",
                "avvio_a_freddo", "dal", "al"},
    "routine_episodio": {"routine_id", "episodio_id", "t0", "t1"},
}
BASI_DELLE_VISTE = set(COLONNE_VISTE)
# SQLite segnala anche la lettura delle colonne della vista stessa: stesse colonne, nome v_*.
# Una CTE che si chiama come una vista non apre niente: le sue letture delle tabelle di base
# passano comunque da COLONNE_VISTE.
for _base, _vista in (("simbolo", "v_evento"), ("episodio", "v_episodio"), ("legame", "v_legame"),
                      ("routine", "v_routine"), ("routine_episodio", "v_routine_episodio")):
    COLONNE_VISTE[_vista] = set(COLONNE_VISTE[_base])
SQLITE_OK, SQLITE_DENY = 0, 1
A_READ, A_SELECT, A_FUNCTION = 20, 21, 31


class SqlRifiutato(Exception):
    pass


def autorizza(azione, arg1, arg2, db, sorgente):
    """L'authorizer: solo SELECT, letture delle colonne esposte dalle viste v_*, funzioni non vietate.

    Per una lettura arg1 è la tabella e arg2 la colonna. Si guarda solo questa coppia: il nome
    della sorgente (vista o CTE) lo sceglie chi scrive la query e non prova niente.
    """
    if azione == A_SELECT:
        return SQLITE_OK
    if azione == A_READ:
        tabella, colonna = arg1 or "", arg2 or ""
        if tabella in COLONNE_VISTE and (colonna in COLONNE_VISTE[tabella] or colonna == ""):
            # colonna "": il pianificatore legge solo il rowid di una tabella di base
            return SQLITE_OK
        return SQLITE_DENY
    if azione == A_FUNCTION:
        if (arg2 or "").lower() in FUNZIONI_VIETATE:
            return SQLITE_DENY
        return SQLITE_OK
    return SQLITE_DENY


def esegui_sql(sql: str) -> dict:
    testo = (sql or "").strip().rstrip(";").strip()
    if not testo:
        raise SqlRifiutato("SQL vuoto")
    if ";" in testo:
        raise SqlRifiutato("una sola istruzione SELECT, senza punto e virgola in mezzo")
    p = percorsi.analisi()
    if not p.exists():
        raise SqlRifiutato("analisi.sqlite non c'è ancora: lancia 'lancillotto analizza'")
    conn = sqlite3.connect(str(p), timeout=5.0)
    try:
        conn.execute("PRAGMA query_only=1")
        passi = [0]

        def progresso():
            passi[0] += 1
            return 1 if passi[0] * 1000 > TETTO_PASSI else 0
        conn.set_progress_handler(progresso, 1000)
        conn.set_authorizer(autorizza)
        try:
            cur = conn.execute(testo)
            righe = cur.fetchmany(TETTO_RIGHE + 1)
        except sqlite3.DatabaseError as e:
            raise SqlRifiutato("rifiutato: %s (ammesse solo SELECT sulle viste v_evento, v_episodio,"
                               " v_legame, v_routine, v_routine_episodio)" % str(e).split("\n")[0])
        except sqlite3.Warning as e:
            raise SqlRifiutato("rifiutato: %s" % e)
        colonne = [d[0] for d in (cur.description or [])]
        troncato = len(righe) > TETTO_RIGHE
        return {"colonne": colonne, "righe": [list(r) for r in righe[:TETTO_RIGHE]],
                "n": min(len(righe), TETTO_RIGHE), "troncato": troncato}
    finally:
        conn.close()


# --- conta ------------------------------------------------------------------------------

def leggi_pattern(pattern: str) -> list:
    voci = []
    for v in (pattern or "").split(">"):
        v = re.sub(r"\s*×\d+$", "", v.strip())
        v = re.sub(r"\s+x\d+$", "", v)
        if v:
            voci.append(v)
    if not voci:
        raise ValueError("pattern vuoto")
    return voci


def _escapa(p: str) -> str:
    """Le parentesi quadre dei segnaposto ([SITO_2]) sono testo, non classi di fnmatch."""
    return re.sub(r"[\[\]]", lambda m: "[" + m.group(0) + "]", p)


def _fine(seq: list, i: int, pat: list, j: int):
    """L'indice di fine della corrispondenza più corta di pat[j:] a partire da seq[i], o None."""
    if j == len(pat):
        return i
    p = pat[j]
    if p == "**":
        for k in range(i, len(seq) + 1):
            f = _fine(seq, k, pat, j + 1)
            if f is not None:
                return f
        return None
    if i >= len(seq):
        return None
    if p == "*" or fnmatch.fnmatchcase(seq[i], _escapa(p)):
        return _fine(seq, i + 1, pat, j + 1)
    return None


def conta_in(seq: list, pat: list) -> int:
    n, i = 0, 0
    while i < len(seq):
        f = _fine(seq, i, pat, 0)
        if f is not None and f > i:
            n += 1
            i = f
        else:
            i += 1
    return n


def conta(an, pattern: str, dal=None) -> dict:
    """Le occorrenze del pattern sulle sessioni; l'episodio di un'occorrenza è quello del suo inizio."""
    from . import analisi
    pat = leggi_pattern(pattern)
    volte, episodi, per_giorno = 0, set(), {}
    # lo schema di una routine può avere blocchi "(A + B)": si conta sulla stessa forma
    blocchi = any(v.startswith("(") for v in pat)
    for seq in analisi.sequenze_sessioni(an, dal, con_blocchi=blocchi).values():
        simboli = [t["s"] for t in seq["token"]]
        i = 0
        while i < len(simboli):
            f = _fine(simboli, i, pat, 0)
            if f is not None and f > i:
                volte += 1
                episodi.add(seq["token"][i]["ep"])
                g = seq["giorno"]
                per_giorno[g] = per_giorno.get(g, 0) + 1
                i = f
            else:
                i += 1
    return {"pattern": " > ".join(pat), "volte": volte, "episodi": len(episodi),
            "giorni": len(per_giorno), "per_giorno": dict(sorted(per_giorno.items())), "dal": dal}


def conta_routine(an, rid: int, dal=None) -> dict:
    """Le occorrenze di tutte le forme della routine rid sulle sessioni: lo stesso conto di
    'volte' della routine, rifatto dai simboli. Ogni tratto conta una volta sola."""
    from . import analisi
    r = an.execute("SELECT id, volte, forme FROM routine WHERE id = ?", (int(rid),)).fetchone()
    if r is None:
        raise ValueError("routine %d non trovata: guarda lancillotto routine --json" % int(rid))
    try:
        forme = [list(f) for f in json.loads(r["forme"] or "[]") if f]
    except ValueError:
        forme = []
    volte, episodi, per_giorno = 0, set(), {}
    for seq in analisi.sequenze_sessioni(an, dal).values():
        simboli = [t["s"] for t in seq["token"]]
        tratti = []
        for f in forme:
            n, i = len(f), 0
            while i + n <= len(simboli):
                if simboli[i:i + n] == f:
                    tratti.append((i, i + n))
                    i += n
                else:
                    i += 1
        fine = -1
        for a, b in sorted(tratti, key=lambda x: (x[0], -(x[1] - x[0]))):
            if a < fine:
                continue
            fine = b
            volte += 1
            episodi.add(seq["token"][a]["ep"])
            g = seq["giorno"]
            per_giorno[g] = per_giorno.get(g, 0) + 1
    return {"routine": int(rid), "volte": volte, "volte_della_routine": int(r["volte"]), "forme": len(forme),
            "episodi": len(episodi), "giorni": len(per_giorno), "per_giorno": dict(sorted(per_giorno.items())),
            "dal": dal}
