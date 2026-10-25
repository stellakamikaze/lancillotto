"""verifica --sql: solo SELECT sulle viste v_*, tetto 200 righe."""
from __future__ import annotations

from base import Base


class TestVerifica(Base):
    def setUp(self):
        super().setUp()
        self.fabbrica()

    def rifiutato(self, sql: str):
        codice, d = self.cli_json("verifica", "--sql", sql)
        self.assertEqual(codice, 2, "SQL accettato e non doveva: %s -> %s" % (sql, str(d)[:200]))
        self.assertIn("errore", d)

    def test_rifiuta_attach_pragma_scritture_tabelle(self):
        for sql in ("ATTACH DATABASE '%s' AS r" % (self.dati / "registro.sqlite"),
                    "PRAGMA table_info(episodio)",
                    "INSERT INTO legame(tipo) VALUES ('x')",
                    "DELETE FROM v_evento",
                    "SELECT * FROM episodio",
                    "SELECT testo FROM righe_fts",
                    "SELECT * FROM alias",
                    "SELECT * FROM sqlite_master",
                    "SELECT load_extension('x')",
                    "SELECT readfile('/etc/passwd')",
                    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c",
                    "SELECT 1; SELECT 2",
                    # una CTE chiamata v_* non apre le tabelle di analisi.sqlite (revisione, punto 1)
                    "WITH v_x AS (SELECT * FROM righe_fts_content) SELECT * FROM v_x",
                    "WITH v_x AS (SELECT * FROM intento) SELECT * FROM v_x",
                    "WITH v_evento AS (SELECT * FROM alias) SELECT * FROM v_evento",
                    "WITH v_x AS (SELECT titoli FROM episodio) SELECT * FROM v_x",
                    "WITH v_episodio(id, giorno) AS (SELECT id, titoli FROM episodio) SELECT giorno FROM v_episodio",
                    "SELECT (SELECT titoli FROM episodio LIMIT 1)"):
            self.rifiutato(sql)

    def test_select_sulle_viste_e_tetto(self):
        codice, d = self.cli_json("verifica", "--sql", "SELECT simbolo, COUNT(*) AS n FROM v_evento GROUP BY simbolo"
                                                         " ORDER BY n DESC")
        self.assertEqual(codice, 0, d)
        self.assertEqual(d["colonne"], ["simbolo", "n"])
        self.assertTrue(d["righe"])
        codice, d = self.cli_json("verifica", "--sql", "SELECT evento_id FROM v_evento")
        self.assertEqual(d["n"], 200)
        self.assertTrue(d["troncato"])
        codice, d = self.cli_json("verifica", "--sql", "SELECT e.giorno, COUNT(*) FROM v_episodio e JOIN v_legame l"
                                                         " ON l.episodio_id = e.id GROUP BY e.giorno")
        self.assertEqual(codice, 0, d)
        self.assertEqual(len(d["righe"]), 5)
        self.assertEqual(d["tipo"], "dati_osservati")

    def test_cte_sulle_viste_resta_ammessa(self):
        codice, d = self.cli_json("verifica", "--sql", "WITH v_x AS (SELECT simbolo FROM v_evento) SELECT COUNT(*) FROM v_x")
        self.assertEqual(codice, 0, d)
