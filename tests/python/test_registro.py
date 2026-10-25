"""Lettura del registro: assente, vuoto, schema più nuovo, DEFLATE raw, sola lettura."""
from __future__ import annotations

import sqlite3

from base import Base
import fabbrica

from lancillotto import registro


class TestRegistro(Base):
    def test_registro_assente_dati_null_con_causa(self):
        try:
            self.cli("oggi")
        finally:
            self.assertFalse((self.dati / "registro.sqlite").exists(), "la CLI ha creato il registro: non deve")
        for verbo in (["oggi"], ["routine"], ["episodi"], ["settimana"], ["catene"], ["cerca", "fattura"]):
            codice, d = self.cli_json(*verbo)
            self.assertEqual(codice, 0, verbo)
            self.assertIn("dati", d, verbo)
            self.assertIsNone(d["dati"], verbo)
            self.assertEqual(d["causa"], "registratore mai avviato", verbo)
            self.assertEqual(d["tipo"], "dati_osservati")
        self.assertFalse((self.dati / "registro.sqlite").exists(), "la CLI ha creato il registro: non deve")
        codice, d = self.cli_json("stato", "--json")
        self.assertEqual(d["stato"], "fermo")

    def test_schema_piu_nuovo_errore_chiaro(self):
        f = fabbrica.Fabbrica(self.dati, schema_versione=99)
        f.chiudi()
        codice, d = self.cli_json("oggi")
        self.assertEqual(codice, 2, "schema 99 senza errore chiaro")
        self.assertIn("aggiorna Lancillotto", d.get("errore", ""), "schema 99 senza errore chiaro")

    def test_registro_vuoto(self):
        self.dati.mkdir(parents=True)
        sqlite3.connect(str(self.dati / "registro.sqlite")).close()
        codice, d = self.cli_json("oggi")
        self.assertEqual(codice, 0)
        self.assertIsNone(d["dati"])
        self.assertIn("registro vuoto", d["causa"])

    def test_deflate_raw(self):
        testo = "Totale fattura: 1.250,00 euro, città è là"
        self.assertEqual(registro.decomprimi(fabbrica.comprimi(testo)), testo)
        self.assertIsNone(registro.decomprimi(b"non compresso"))

    def test_lettura_non_scrive(self):
        self.fabbrica()
        conn = registro.apri()
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute("DELETE FROM evento")
        conn.close()
        c = sqlite3.connect(str(self.dati / "registro.sqlite"))
        n = c.execute("SELECT COUNT(*) FROM evento").fetchone()[0]
        c.close()
        self.assertGreater(n, 1000)

    def test_eco_del_menu_dopo_una_scorciatoia(self):
        f = fabbrica.Fabbrica(self.dati)
        f.finestra("mail", "Appunti")
        # nella fabbrica il passo è il tempo fino all'evento seguente
        f.comando("mail", "cmd+v", passo=200)
        eco = f.menu("mail", "Modifica > Incolla")
        f.comando("mail", "cmd+a", passo=3000)
        dopo = f.menu("mail", "Modifica > Seleziona tutto")
        f.comando("mail", "cmd+c", passo=200)
        altra = f.menu("excel", "Modifica > Incolla")
        f.chiudi()
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        conn.row_factory = sqlite3.Row
        self.addCleanup(conn.close)
        ids = [e["id"] for e in registro.eventi(conn)]
        self.assertNotIn(eco, ids, "la voce di menu del cmd+v conta come un secondo incolla")
        self.assertIn(dopo, ids, "una voce di menu scelta 3 s dopo non è un'eco")
        self.assertIn(altra, ids, "una voce di menu in un'altra app non è un'eco")
