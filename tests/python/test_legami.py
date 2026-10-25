"""Legami: precisione degli appunti contro la verità nota della fabbrica, e i casi difficili."""
from __future__ import annotations

import json
import sqlite3

from base import Base


class TestLegami(Base):
    def setUp(self):
        super().setUp()
        self.f = self.fabbrica()
        codice, esito = self.cli_json("analizza")
        self.assertEqual(codice, 0, esito)
        self.an = sqlite3.connect(str(self.dati / "analisi.sqlite"))
        self.an.row_factory = sqlite3.Row
        self.addCleanup(self.an.close)

    def appunti(self, minima=0.0):
        return [r for r in self.an.execute("SELECT * FROM legame WHERE tipo = 'appunti' AND confidenza >= ?",
                                           (minima,))]

    def test_precisione_appunti(self):
        verita = self.f.verita["appunti"]
        alti = [(r["da_evento"], r["a_evento"]) for r in self.appunti(0.5)]
        self.assertTrue(alti)
        giusti = sum(1 for x in alti if x in verita)
        precisione = giusti / len(alti)
        richiamo = giusti / len(verita)
        self.assertGreaterEqual(precisione, 0.9, "precisione appunti %.2f sotto 0,9" % precisione)
        self.assertGreaterEqual(richiamo, 0.9, "richiamo appunti %.2f sotto 0,9" % richiamo)

    def test_incolla_senza_copia_nessun_legame_alto(self):
        senza = set(self.f.verita["senza_copia"])
        self.assertGreaterEqual(len(senza), 5)
        legati = [r for r in self.appunti(0.5) if r["a_evento"] in senza]
        self.assertEqual(legati, [], "incolla senza copia con legame ad alta confidenza")

    def test_cambio_da_app_in_secondo_piano_sotto_mezzo(self):
        for sorgente, incolla in self.f.verita["sfondo"]:
            righe = [r for r in self.appunti() if r["a_evento"] == incolla]
            self.assertEqual(len(righe), 1)
            self.assertLess(righe[0]["confidenza"], 0.5, "cambio dallo sfondo con confidenza alta")
            self.assertEqual(json.loads(righe[0]["prova"]).get("sfondo"), 1)

    def test_ventaglio(self):
        for sorgente, incolla in self.f.verita["ventaglio"]:
            righe = [r for r in self.appunti() if r["da_evento"] == sorgente]
            self.assertEqual(sorted(r["a_evento"] for r in righe), sorted(incolla))
            for r in righe:
                self.assertEqual(json.loads(r["prova"]).get("ventaglio"), 3)

    def test_altro_compito(self):
        (sorgente, incolla), = self.f.verita["altro_compito"]
        r = self.an.execute("SELECT * FROM legame WHERE a_evento = ?", (incolla,)).fetchone()
        self.assertIsNotNone(r)
        self.assertEqual(r["da_evento"], sorgente)
        self.assertEqual(json.loads(r["prova"]).get("altro_compito"), 1)
        self.assertGreater(r["ritardo_ms"], 30 * 60000)

    def test_copia_senza_comando_vale_07(self):
        righe = [r for r in self.appunti() if r["da_simbolo"] == "Calendario:copia"]
        self.assertTrue(righe)
        self.assertTrue(all(r["confidenza"] == 0.7 for r in righe))

    def test_download_file_riuso_stesso_oggetto(self):
        tipi = {r[0]: r[1] for r in self.an.execute("SELECT tipo, COUNT(*) FROM legame GROUP BY tipo")}
        self.assertEqual(tipi.get("download"), 5)
        self.assertGreaterEqual(tipi.get("file", 0), 15)
        self.assertEqual(tipi.get("riuso"), 15)
        self.assertGreaterEqual(tipi.get("stesso_oggetto", 0), 15)
        d = self.an.execute("SELECT * FROM legame WHERE tipo = 'download' LIMIT 1").fetchone()
        self.assertEqual(d["da_simbolo"], "Chrome:visita:drive.google.com")
        self.assertEqual(json.loads(d["prova"]), {"provenienza": "drive.google.com"})

    def test_catene_in_uscita(self):
        codice, d = self.cli_json("catene", "--tipo", "appunti")
        self.assertEqual(d["livello"], "L1")
        self.assertTrue(d["catene"])
        for c in d["catene"]:
            self.assertNotEqual(c["da"], "?")
            self.assertIn("confidenza", c)
