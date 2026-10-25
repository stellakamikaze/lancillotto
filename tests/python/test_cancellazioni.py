"""Cancellazioni: dimentica, escludi all'indietro, cancella tutto. Pausa e impostazioni."""
from __future__ import annotations

import json
import os
import sqlite3

from base import Base


class TestCancellazioni(Base):
    def setUp(self):
        super().setUp()
        self.f = self.fabbrica()
        self.cli_json("analizza")

    def conta(self, sql, *arg):
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        try:
            return conn.execute(sql, arg).fetchone()[0]
        finally:
            conn.close()

    def test_dimentica_cancella_l_intervallo(self):
        cv = self.f.riapri().recenti(3)
        self.f.chiudi()
        self.assertEqual(self.conta("SELECT COUNT(*) FROM campo WHERE evento_id = ?", cv), 1)
        prima = self.conta("SELECT COUNT(*) FROM evento")
        codice, d = self.cli_json("dimentica", "10", "--json")
        self.assertEqual(codice, 0, d)
        self.assertGreaterEqual(d["eventi_cancellati"], 3, "dimentica non ha cancellato l'intervallo")
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento WHERE id = ?", cv), 0,
                         "dimentica non ha cancellato l'intervallo")
        self.assertEqual(self.conta("SELECT COUNT(*) FROM campo WHERE evento_id = ?", cv), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM impronta WHERE evento_id = ?", cv), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM riga WHERE lunghezza = ?", len("riga recente da dimenticare 991")), 0)
        self.assertGreater(self.conta("SELECT COUNT(*) FROM evento"), prima - 100)
        imp = json.loads((self.dati / "impostazioni.json").read_text())
        self.assertEqual(len(imp["dimentica_richieste"]), 1, "il registratore vivo deve ricevere la richiesta")
        codice, d = self.cli_json("cerca", "991")
        self.assertEqual(d["schermo"], [], "l'indice del testo ricorda ancora l'intervallo dimenticato")

    def test_escludi_app_all_indietro(self):
        prima = self.conta("SELECT COUNT(*) FROM evento e JOIN app a ON a.id = e.app_id WHERE a.bundle = 'com.spotify.client'")
        self.assertGreater(prima, 0)
        codice, d = self.cli_json("escludi", "app", "Spotify", "--json")
        self.assertEqual(codice, 0, d)
        self.assertEqual(d["eventi_cancellati"], prima)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento e JOIN app a ON a.id = e.app_id"
                                    " WHERE a.bundle = 'com.spotify.client'"), 0)
        self.assertEqual(self.conta("SELECT esclusa FROM app WHERE bundle = 'com.spotify.client'"), 1)
        imp = json.loads((self.dati / "impostazioni.json").read_text())
        self.assertIn("com.spotify.client", imp["escludi_app"])
        codice, out = self.cli("oggi")
        self.assertNotIn("Spotify", out)

    def test_escludi_sito_all_indietro(self):
        codice, d = self.cli_json("escludi", "sito", "https://www.youtube.com/watch?v=1", "--json")
        self.assertEqual(d["nome"], "youtube.com")
        self.assertGreater(d["eventi_cancellati"], 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento e JOIN oggetto o ON o.id = e.ogg_id"
                                    " WHERE o.dominio = 'youtube.com'"), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM oggetto WHERE etichetta = 'Video - YouTube'"), 0)

    def test_cancella_tutto_chiede_si(self):
        codice, out = self.cli("cancella-tutto", stdin="no\n")
        self.assertEqual(codice, 1)
        self.assertGreater(self.conta("SELECT COUNT(*) FROM evento"), 0)
        prima = self.conta("SELECT MAX(id) FROM app")
        codice, out = self.cli("cancella-tutto", stdin="SI\n")
        self.assertEqual(codice, 0)
        # un'app nuova scritta dal registratore non riusa un id che lui può tenere in memoria
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        nuovo = conn.execute("INSERT INTO app(bundle, nome) VALUES ('com.esempio.nuova', 'Nuova')").lastrowid
        conn.commit()
        conn.close()
        self.assertGreater(nuovo, prima, "id di app riusato dopo cancella-tutto")
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        conn.execute("DELETE FROM app WHERE bundle = 'com.esempio.nuova'")
        conn.commit()
        conn.close()
        # registratore acceso: la richiesta gli dice di buttare anche quello che ha in RAM
        imp = json.loads((self.dati / "impostazioni.json").read_text())
        self.assertEqual([r["da"] for r in imp.get("dimentica_richieste", [])], [0])
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento"), 0)
        # resta solo la lapide vuota che tiene alti gli id (registro.cancella_tutto)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM oggetto WHERE chiave_h != '~cancellato'"), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM oggetto WHERE etichetta IS NOT NULL"), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM app WHERE bundle != '~cancellato'"), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM riga WHERE lunghezza > 0"), 0)
        self.assertFalse((self.dati / "analisi.sqlite").exists())

    def test_pausa_e_riprendi(self):
        codice, d = self.cli_json("pausa", "30", "--json")
        imp = json.loads((self.dati / "impostazioni.json").read_text())
        self.assertGreater(imp["pausa_fino"], 0)
        self.assertEqual(os.stat(str(self.dati / "impostazioni.json")).st_mode & 0o777, 0o600)
        self.assertFalse((self.dati / "impostazioni.json.tmp").exists())
        codice, s = self.cli_json("stato", "--json")
        self.assertEqual(s["stato"], "in pausa")
        self.cli_json("riprendi", "--json")
        codice, s = self.cli_json("stato", "--json")
        self.assertEqual(s["stato"], "acceso")
        codice, out = self.cli("stato")
        self.assertIn("acceso", out)
        self.assertIn("url firefox degradato", out)
        codice, d = self.cli_json("pausa", "domani", "--json")
        imp = json.loads((self.dati / "impostazioni.json").read_text())
        self.assertEqual(imp["conservazione_giorni"], 14)

    def test_peso_di_oggi_dai_dati_di_oggi(self):
        """giorno.byte è il peso di tutto il registro: con la conservazione a regime il file cala di
        notte e la crescita da ieri è zero o negativa. Il peso di oggi viene dai dati di oggi."""
        import datetime as dt
        from lancillotto import registro
        oggi = dt.date.today()
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        # ieri 12 MB, oggi 9 MB: la conservazione ha tolto un giorno pesante
        conn.execute("INSERT OR REPLACE INTO giorno(data, eventi, byte) VALUES (?, 10, ?)",
                     ((oggi - dt.timedelta(days=1)).isoformat(), 12 * 1048576))
        conn.execute("INSERT OR REPLACE INTO giorno(data, eventi, byte) VALUES (?, 10, ?)",
                     (oggi.isoformat(), 9 * 1048576))
        conn.commit()
        inizio = dt.datetime.combine(oggi, dt.time(0, 0))
        atteso = registro.peso_giorno(conn, int(inizio.timestamp() * 1000),
                                      int((inizio + dt.timedelta(days=1)).timestamp() * 1000))
        conn.close()
        self.assertGreater(atteso, 0)
        codice, s = self.cli_json("stato", "--json")
        self.assertGreater(s["oggi"]["mb"], 0, "peso di oggi a zero con la conservazione a regime: %s" % s["oggi"])
        self.assertEqual(s["oggi"]["mb"], round(atteso / 1048576.0, 2))

    def test_stato_fermo_dalle(self):
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        conn.execute("UPDATE meta SET valore = '1000' WHERE chiave = 'ultimo_battito'")
        conn.commit()
        conn.close()
        codice, s = self.cli_json("stato", "--json")
        self.assertEqual(s["stato"], "fermo")
        self.assertIsNotNone(s["dalle"])
