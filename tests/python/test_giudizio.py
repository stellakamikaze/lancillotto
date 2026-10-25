"""Il giudizio di Claude su una routine (lancillotto valuta) e ciò che ne legge la finestra (oggi --json)."""
from __future__ import annotations

import datetime as dt
import sqlite3

from base import Base
from test_routine import piantata

TITOLO = "Copiare i dati delle fatture nel portale dei fornitori"
COME = "Claude legge i PDF allegati e ti prepara i valori da incollare"


class TestGiudizio(Base):
    def _id(self, nome: str) -> int:
        codice, d = self.cli_json("routine", "--top", "5")
        return next(r["id"] for r in d["routine"] if piantata(r["schema"]) == nome)

    def test_prima_della_lettura_nessun_giudizio(self):
        self.fabbrica()
        codice, d = self.cli_json("oggi")
        self.assertEqual(d["compiti"], [])
        self.assertIsNone(d["lettura"]["data"])
        self.assertEqual(d["lettura"]["da_leggere"], d["lettura"]["schemi"])

    def test_compito_compare_in_oggi(self):
        self.fabbrica()
        r1 = self._id("R1")
        codice, esito = self.cli_json("valuta", str(r1), "--compito", TITOLO, "--come", COME)
        self.assertEqual(codice, 0, esito)
        self.assertEqual(esito["giudizio"], "compito")
        codice, d = self.cli_json("oggi")
        voce = next((c for c in d["compiti"] if c["id"] == r1), None)
        self.assertIsNotNone(voce, "compito giudicato ma assente da oggi: %s" % d["compiti"])
        self.assertEqual((voce["titolo"], voce["come"], voce["stato"]), (TITOLO, COME, "proposta"))
        self.assertEqual((voce["volte"], voce["giorni"]), (15, 5))
        self.assertEqual(d["lettura"]["data"], dt.date.today().isoformat())
        self.assertEqual(d["lettura"]["da_leggere"], d["lettura"]["schemi"] - 1)
        # il giudizio sopravvive all'analisi rifatta da zero
        self.cli_json("analizza", "--da-zero")
        codice, d = self.cli_json("oggi")
        self.assertIn(r1, [c["id"] for c in d["compiti"]], "giudizio perso dopo analizza --da-zero")

    def test_non_compito_sparisce_e_torna_col_tempo_raddoppiato(self):
        self.fabbrica()
        r3 = self._id("R3")
        codice, esito = self.cli_json("valuta", str(r3), "--non-compito", "agenda copiata a mano per scelta")
        self.assertEqual(codice, 0, esito)
        self.cli_json("analizza", "--da-zero")
        codice, d = self.cli_json("routine", "--top", "20")
        self.assertNotIn(r3, [r["id"] for r in d["routine"]], "la routine scartata è tornata")
        codice, o = self.cli_json("oggi")
        self.assertNotIn(r3, [c["id"] for c in o["compiti"]], "una scartata fra i compiti")
        self.assertGreaterEqual(o["lettura"]["scartate"], 1)
        codice, p = self.cli_json("precedenti")
        self.assertIn("agenda copiata a mano per scelta",
                      [v.get("non_compito") for v in p["routine_decise"]], "il perché non arriva a Claude")
        conn = sqlite3.connect(str(self.dati / "analisi.sqlite"))
        conn.execute("UPDATE routine_stato SET tempo_rif_ms = 1000 WHERE id = ?", (r3,))
        conn.commit()
        conn.close()
        self.cli_json("analizza", "--da-zero")
        codice, d = self.cli_json("routine", "--top", "20")
        self.assertIn(r3, [r["id"] for r in d["routine"]], "scartata cambiata ma non torna")
        codice, o = self.cli_json("oggi")
        self.assertEqual(o["lettura"]["da_leggere"], o["lettura"]["schemi"], "la scartata tornata non va riletta")

    def test_testi_cattivi_rifiutati(self):
        self.fabbrica()
        r1 = self._id("R1")
        for argv in (["--compito", "Copiare per [P3] le fatture", "--come", COME],
                     ["--compito", TITOLO, "--come", "apre https://portale.example.com"],
                     ["--compito", TITOLO],
                     ["--compito", TITOLO, "--come", COME, "--non-compito", "no"]):
            codice, out = self.cli("valuta", str(r1), *argv)
            self.assertEqual(codice, 2, "valuta accettato: %s" % argv)
        codice, d = self.cli_json("oggi")
        self.assertEqual(d["compiti"], [], "un giudizio rifiutato è stato scritto")

    def test_analisi_vecchia_prende_le_colonne(self):
        self.dati.mkdir(parents=True, exist_ok=True)
        p = self.dati / "analisi.sqlite"
        conn = sqlite3.connect(str(p))
        conn.execute("CREATE TABLE routine_stato(id INTEGER PRIMARY KEY AUTOINCREMENT, firma_h TEXT UNIQUE,"
                     " schema TEXT, stato TEXT NOT NULL DEFAULT 'proposta', motivo TEXT, con_cosa TEXT, nota TEXT,"
                     " tempo_rif_ms INTEGER, creata TEXT, aggiornata TEXT)")
        conn.execute("INSERT INTO routine_stato(firma_h, schema, stato) VALUES ('abc', '[]', 'rifiutata')")
        conn.execute("PRAGMA user_version = 2")
        conn.commit()
        conn.close()
        from lancillotto import analisi
        an = analisi.apri()
        self.addCleanup(an.close)
        colonne = {r[1] for r in an.execute("PRAGMA table_info(routine_stato)")}
        self.assertTrue({"titolo", "come", "giudizio", "perche", "giudicata"} <= colonne, colonne)
        self.assertEqual(an.execute("SELECT stato FROM routine_stato").fetchone()[0], "rifiutata",
                         "la migrazione ha perso una decisione")
