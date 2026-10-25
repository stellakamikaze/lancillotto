"""Rumore che non è una routine: navigazione pura, passi dentro un'app esclusa, file dei programmi.

Sono i tre falsi positivi della prima giornata vera (25/10/2026): Instagram aperto da una scheda
nuova, il passaggio fra una chat esclusa e Firefox, i .pyc e i font scritti mentre Claude Code
lavorava. Il motore li deve lasciare fuori, e la routine vera accanto deve restare.
"""
from __future__ import annotations

from base import Base
from test_cicli import _Contesto, _Sequenze

from lancillotto import episodi as epm
from lancillotto import routine as rtm

NAVIGA = ["Firefox:nuova_scheda", "Firefox:visita:instagram.com", "Firefox:clic:web"]
ESCLUSA = ["Mail:copia", "[esclusa]:escluso", "Chrome:incolla:[SITO_1]/campo"]
VERA = ["Mail:clic:allegato", "Anteprima:apri_allegato:pdf", "Anteprima:copia", "Chrome:incolla:[SITO_1]/campo"]


def _sequenze(pezzo: list, seme: int = 5) -> dict:
    seq = _Sequenze(seme)
    for sid in range(1, 16):
        seq.sessione(sid, seq.rumore(10) + pezzo + seq.rumore(6) + pezzo + seq.rumore(8) + VERA + seq.rumore(6))
    return seq.out


class TestRumore(Base):
    def test_navigazione_non_diventa_routine(self):
        trovate = rtm.scopri(_sequenze(NAVIGA))
        sole_navigazione = [r["schema"] for r in trovate if "instagram" in r["schema"] and "Anteprima" not in r["schema"]]
        self.assertEqual(sole_navigazione, [], "navigazione diventata routine: %s" % sole_navigazione)
        self.assertTrue([r for r in trovate if "Anteprima:copia" in r["schema"]],
                        "la routine vera accanto è sparita: %s" % [r["schema"] for r in trovate[:3]])

    def test_app_esclusa_spezza_lo_schema(self):
        trovate = rtm.scopri(_sequenze(ESCLUSA))
        con_esclusa = [r["schema"] for r in trovate if ":escluso" in r["schema"]]
        self.assertEqual(con_esclusa, [], "app esclusa dentro una routine: %s" % con_esclusa)
        self.assertTrue([r for r in trovate if "Anteprima:copia" in r["schema"]], "la routine vera è sparita")

    def test_file_dei_programmi_fuori_dagli_episodi(self):
        ctx = epm.Contesto(_Contesto())
        terminale = {"app_id": 2, "bundle": "com.apple.Terminal", "app_nome": "Terminale"}
        finder = {"app_id": 3, "bundle": "com.apple.finder", "app_nome": "Finder"}
        excel = {"app_id": 4, "bundle": "com.microsoft.Excel", "app_nome": "Microsoft Excel"}
        firefox = {"app_id": 5, "bundle": "org.mozilla.firefox", "app_nome": "Firefox"}

        def file(tipo, ts, ext, **kw):
            return dict({"app_id": None, "tipo": tipo, "ts": ts, "ext": ext, "det": {}}, **kw)

        # Claude Code dal Terminale scrive codice e cache; un clic sul web non è un gesto sui file
        ctx.simbolo(dict(terminale, tipo="comando", ts=0, det={"tasti": "cmd+s"}))
        ctx.simbolo(dict(firefox, tipo="clic", ts=500, det={"web": True}))
        programma = [ctx.simbolo(file("file_crea", 1000, "pyc")), ctx.simbolo(file("file_mod", 1500, "plist")),
                     ctx.simbolo(file("file_crea", 2000, "woff2"))]
        self.assertEqual(programma, [None, None, None], "file di un programma entrato: %s" % programma)
        # la persona: salva in Excel, sposta nel Finder, scarica dal browser
        ctx.simbolo(dict(excel, tipo="comando", ts=60000, det={"tasti": "cmd+s"}))
        self.assertEqual(ctx.simbolo(file("file_mod", 61000, "xlsx")), "File:modifica:xlsx")
        ctx.simbolo(dict(finder, tipo="comando", ts=120000, det={"tasti": "cmd+backspace"}))
        self.assertEqual(ctx.simbolo(file("file_sposta", 122000, "pdf")), "File:sposta:pdf")
        self.assertEqual(ctx.simbolo(file("file_crea", 900000, "pdf", cartella="download")), "File:scarica:pdf")
        # oltre 10 s dal gesto il file non è più della persona
        self.assertIsNone(ctx.simbolo(file("file_mod", 140000, "xlsx")), "file lontano dal gesto entrato")
