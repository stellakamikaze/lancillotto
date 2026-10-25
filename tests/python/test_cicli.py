"""Cicli dentro le routine: sei copia e incolla uguali di fila sono un passo, non sei routine.

Il registro scritto dal binario Swift (--scenario-sintetico) ha questa forma: Mail apre
l'allegato, Anteprima lo mostra, poi sei volte copia in Anteprima e incolla in Chrome. Qui la
stessa forma è costruita a mano sulle sequenze, con rumore casuale intorno, più il caso opposto:
una routine fatta a volte due volte di fila conta ogni volta.
"""
from __future__ import annotations

import random

from base import Base

from lancillotto import episodi as epm
from lancillotto import routine as rtm

RUMORE = ["Finder:finestra", "Note:finestra", "Spotify:finestra", "Safari:visita:ilpost.it",
          "Slack:finestra", "Terminale:finestra", "Musica:finestra", "Foto:finestra",
          "Meteo:finestra", "Calcolatrice:finestra"]
CICLO = ["Anteprima:copia", "Chrome:incolla:[SITO_1]/campo", "Chrome:clic:salva"]
PREFISSO = ["Mail:clic:allegato", "Anteprima:apri_allegato:pdf"]
R3 = ["Calendario:clic:copia", "Calendario:copia", "Slack:incolla", "Slack:invia"]


class _Sequenze:
    def __init__(self, seme: int):
        self.rng = random.Random(seme)
        self.out = {}
        self.ident = 0

    def sessione(self, sid: int, pezzi: list) -> None:
        token, t = [], 1000000 * sid
        for s in pezzi:
            self.ident += 1
            token.append({"s": s, "n": 1, "e0": self.ident, "e1": self.ident, "t0": t, "t1": t + 4000, "ep": sid})
            t += 5000
        self.out[sid] = {"token": token, "giorno": "2026-10-%02d" % (10 + sid), "episodi": {sid}}

    def rumore(self, n: int) -> list:
        return [self.rng.choice(RUMORE) for _ in range(n)]


class _Contesto:
    """Pseudonimi finti: bastano i nomi delle app."""

    def app(self, bundle, nome):
        return nome or bundle

    def sito(self, dominio):
        return dominio or ""


class TestCicli(Base):
    def test_ciclo_dentro_routine_resta_intero(self):
        seq = _Sequenze(3)
        for sid in range(1, 6):
            pezzi = []
            for _k in range(3):
                pezzi += seq.rumore(12) + PREFISSO + CICLO * 5
            seq.sessione(sid, pezzi + seq.rumore(12))
        trovate = rtm.scopri(seq.out)
        con_mail = [r for r in trovate if r["schema"].startswith("Mail:clic:allegato > Anteprima:apri_allegato:pdf")]
        self.assertTrue(con_mail, "ciclo spezzato: %s" % [r["schema"] for r in trovate[:3]])
        r = con_mail[0]
        self.assertIn("(Anteprima:copia + Chrome:incolla:[SITO_1]/campo + Chrome:clic:salva)×5", r["schema"],
                      "ciclo spezzato: %s" % r["schema"])
        self.assertEqual(r["volte"], 15, "ciclo spezzato: %s volte" % r["volte"])
        self.assertEqual(r["app"], ["Mail", "Anteprima", "Chrome"])
        self.assertEqual(epm.simboli_di("(A:x + B:y)×5"), ["A:x", "B:y"])

    def test_due_volte_di_fila_restano_due(self):
        seq = _Sequenze(5)
        for sid in range(1, 6):
            pezzi = seq.rumore(14) + R3 + seq.rumore(14) + R3 * 2
            seq.sessione(sid, pezzi + seq.rumore(14))
        trovate = rtm.scopri(seq.out)
        r3 = [r for r in trovate if "Calendario:copia" in r["schema"] and "Slack:incolla" in r["schema"]]
        self.assertTrue(r3, "routine R3 non trovata: %s" % [r["schema"] for r in trovate[:3]])
        self.assertEqual(r3[0]["volte"], 15, "ripetizioni di fila contate una: %s volte, %s"
                         % (r3[0]["volte"], r3[0]["schema"]))

    def test_ritorno_sullo_stesso_documento_non_riapre(self):
        ctx = epm.Contesto(_Contesto())
        base = {"app_id": 7, "bundle": "com.apple.Preview", "app_nome": "Anteprima", "det": {},
                "inode": 42, "ext": "pdf", "cartella": "mail_allegati"}
        simboli = []
        for ts in (0, 20000, 40000, 40000 + 11 * 60000):
            simboli.append(ctx.simbolo(dict(base, tipo="documento", ts=ts)))
        self.assertEqual(simboli, ["Anteprima:apri_allegato:pdf", None, None, "Anteprima:apri_allegato:pdf"],
                         "ritorno contato come apertura: %s" % simboli)
        altro = ctx.simbolo(dict(base, tipo="documento", ts=40000 + 11 * 60000 + 1000, inode=43))
        self.assertEqual(altro, "Anteprima:apri_allegato:pdf", "documento nuovo non visto")
