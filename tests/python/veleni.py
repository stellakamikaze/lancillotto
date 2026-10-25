"""Veleni dei test: versioni rotte del codice, applicate solo dai test con unittest.mock.

LANCILLOTTO_TEST_VELENO=nome mette il veleno in ogni test (Base.setUp). Il codice di produzione
non legge mai questa variabile. L'elenco, con il test che deve diventare rosso, sta in veleni.md.
"""
from __future__ import annotations

import os
from unittest import mock

from lancillotto import analisi, episodi, legami, melchior, pseudonimi, registro, routine, segreti, uscita, verifica

_valuta_vera = registro.valuta_consenso
_sorgente_vera = legami.sorgente_appunti


def _consenso_senza_scadenza(righe, t0, t1, ora_ms):
    return _valuta_vera(righe, t0, t1, 0)


def _consenso_senza_intervallo(righe, t0, t1, ora_ms):
    for r in righe:
        if r["deciso"] == 1:
            return _valuta_vera([r], r["t0"], r["t1"], ora_ms)
    return _valuta_vera(righe, t0, t1, ora_ms)


def _sorgente_senza_cc(conn, ev):
    r = conn.execute("SELECT id, ts, app_id, cc, dettaglio FROM evento WHERE tipo = 'appunti' AND ts <= ?"
                     " ORDER BY ts DESC, id DESC LIMIT 1", (ev["ts"],)).fetchone()
    return dict(r) if r is not None else None


def _apri_che_crea(scrittura=False):
    import sqlite3
    from lancillotto import percorsi
    percorsi.assicura_cartella()
    conn = sqlite3.connect(str(percorsi.registro()))
    conn.row_factory = sqlite3.Row
    return conn


def _corse_sempre(occ, sequenze, forti, coperti):
    return [(ep, i, n) for ep, i, n, _k in routine._corse(occ)]


def _involucro_nudo(livello, corpo, limiti=None):
    d = dict(corpo)
    d["limiti"] = list(limiti or [])
    return d


VELENI = {
    "allowlist": lambda: [mock.patch.object(pseudonimi, "parola_ammessa", lambda w: True)],
    "domini": lambda: [mock.patch.object(pseudonimi, "dominio_pubblico", lambda d: (d or "").lower() or None)],
    "app_nomi": lambda: [mock.patch.object(pseudonimi.Pseudonimi, "app",
                                           lambda self, b, n: pseudonimi.nome_app_canonico(b, n))],
    "appunti_cc": lambda: [mock.patch.object(legami, "sorgente_appunti", _sorgente_senza_cc)],
    "sfondo": lambda: [mock.patch.object(legami, "primo_piano", lambda conn, ts: None)],
    "lift": lambda: [mock.patch.object(routine, "LIFT", 0.0)],
    "consenso_scadenza": lambda: [mock.patch.object(registro, "valuta_consenso", _consenso_senza_scadenza)],
    "consenso_intervallo": lambda: [mock.patch.object(registro, "valuta_consenso", _consenso_senza_intervallo)],
    "segreti_l2": lambda: [mock.patch.object(segreti, "redigi", lambda t: (t, []))],
    "schema_versione": lambda: [mock.patch.object(registro, "SCHEMA_SUPPORTATA", 999)],
    "registro_crea": lambda: [mock.patch.object(registro, "apri", _apri_che_crea)],
    "authorizer": lambda: [mock.patch.object(verifica, "autorizza", lambda *a: 0)],
    "dimentica": lambda: [mock.patch.object(registro, "dimentica", lambda conn, da, a: {"eventi": 0, "righe": 0})],
    "nota_controlli": lambda: [mock.patch.object(melchior, "problemi_testo", lambda *a, **k: []),
                               mock.patch.object(melchior, "_controlla_nota", lambda t: None)],
    "yaml_virgolette": lambda: [mock.patch.object(melchior, "_q", lambda t: t)],
    "rifiutate": lambda: [mock.patch.object(analisi, "stato_effettivo", lambda rec, r: "proposta")],
    "inattivita": lambda: [mock.patch.object(episodi, "INATTIVITA_MS", 10 ** 12)],
    "involucro": lambda: [mock.patch.object(uscita, "involucro", _involucro_nudo)],
    "tetto_token": lambda: [mock.patch.object(uscita, "limita", lambda obj, tetto=2000: obj)],
    "corse": lambda: [mock.patch.object(routine, "_corse_estese", lambda *a: None)],
    "corse_sempre": lambda: [mock.patch.object(routine, "_corse_estese", _corse_sempre)],
    "ritorno": lambda: [mock.patch.object(episodi.Contesto, "ritorno", lambda self, ev, chiave: False)],
}


def applica(test) -> None:
    nome = os.environ.get("LANCILLOTTO_TEST_VELENO", "").strip()
    if not nome:
        return
    if nome not in VELENI:
        raise RuntimeError("veleno sconosciuto: %s (elenco in tests/python/veleni.md)" % nome)
    for p in VELENI[nome]():
        p.start()
        test.addCleanup(p.stop)
