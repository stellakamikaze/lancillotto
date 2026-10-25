"""Routine: le tre piantate in testa, il rumore alternato non passa, le rifiutate non tornano."""
from __future__ import annotations

import random
import sqlite3

from base import Base

from lancillotto import routine as rtm


def piantata(schema: str):
    """Quale routine piantata è questa (R1, R2, R3), oppure None."""
    if "Anteprima:apri_allegato:pdf" in schema and "Chrome:incolla" in schema and "Anteprima:copia" in schema:
        return "R1"
    if "Excel:menu:ordina" in schema and "File:scarica:xlsx" in schema:
        return "R2"
    if "Calendario:copia" in schema and "Slack:incolla" in schema:
        return "R3"
    return None


class TestRoutine(Base):
    def test_tre_piantate_in_testa(self):
        self.fabbrica()
        codice, d = self.cli_json("routine", "--top", "3")
        self.assertEqual(codice, 0)
        trovate = [piantata(r["schema"]) for r in d["routine"]]
        self.assertEqual(sorted(t for t in trovate if t), ["R1", "R2", "R3"],
                         "le 3 routine piantate non sono in testa: %s" % [r["schema"][:80] for r in d["routine"]])
        per_nome = {piantata(r["schema"]): r for r in d["routine"]}
        self.assertEqual(per_nome["R1"]["volte"], 15)
        self.assertEqual(per_nome["R1"]["giorni"], 5)
        self.assertEqual(per_nome["R2"]["volte"], 5)
        self.assertGreaterEqual(per_nome["R3"]["volte"], 12)
        self.assertGreaterEqual(per_nome["R1"]["legami_tra_app"], 15)
        self.assertRegex(per_nome["R1"]["schema"], r"Mail\b.*>.*Anteprima\b.*>.*Chrome\b")

    def test_rumore_alternato_non_diventa_routine(self):
        """Due app che si alternano spesso (cmd+tab) non fanno una routine: serve il lift."""
        rng = random.Random(3)
        sequenze = {}
        t = 0
        for ep in range(30):
            token = []
            for k in range(60):
                s = rng.choice(["Slack:finestra", "Chrome:finestra", "Note:finestra", "Mail:finestra"])
                if token and token[-1]["s"] == s:
                    continue
                token.append({"s": s, "n": 1, "e0": t, "e1": t, "t0": t * 1000, "t1": t * 1000 + 30000})
                t += 40
            sequenze[ep] = {"token": token, "giorno": "2026-10-%02d" % (10 + ep % 5)}
        trovate = rtm.scopri(sequenze)
        self.assertEqual(trovate, [], "rumore diventato routine: %s" % [r["schema"] for r in trovate[:3]])

    def test_rifiutata_non_torna(self):
        self.fabbrica()
        codice, d = self.cli_json("routine", "--top", "3")
        r1 = next(r for r in d["routine"] if piantata(r["schema"]) == "R1")
        codice, esito = self.cli_json("rifiuta", str(r1["id"]), "lo fa già la contabilità")
        self.assertEqual(codice, 0, esito)
        for argv in (["analizza", "--da-zero"], ["analizza"]):
            self.cli_json(*argv)
            codice, d2 = self.cli_json("routine", "--top", "20")
            ids = [r["id"] for r in d2["routine"]]
            self.assertNotIn(r1["id"], ids, "la routine rifiutata è tornata dopo %s" % argv)
            self.assertNotIn("R1", [piantata(r["schema"]) for r in d2["routine"]],
                             "la routine rifiutata è tornata con un altro id")
        codice, d3 = self.cli_json("routine", "--stato", "rifiutata")
        self.assertIn(r1["id"], [r["id"] for r in d3["routine"]])

    def test_rifiutata_torna_se_il_tempo_raddoppia(self):
        self.fabbrica()
        codice, d = self.cli_json("routine", "--top", "3")
        r3 = next(r for r in d["routine"] if piantata(r["schema"]) == "R3")
        self.cli_json("rifiuta", str(r3["id"]), "non mi interessa")
        conn = sqlite3.connect(str(self.dati / "analisi.sqlite"))
        conn.execute("UPDATE routine_stato SET tempo_rif_ms = 1000 WHERE id = ?", (r3["id"],))
        conn.commit()
        conn.close()
        self.cli_json("analizza", "--da-zero")
        codice, d2 = self.cli_json("routine", "--top", "10")
        self.assertIn(r3["id"], [r["id"] for r in d2["routine"]], "firma cambiata ma la routine non torna")

    def test_id_stabili_e_incrementale_come_da_zero(self):
        self.fabbrica()
        codice, a = self.cli_json("routine", "--top", "5")
        self.cli_json("analizza", "--da-zero")
        codice, b = self.cli_json("routine", "--top", "5")
        self.assertEqual([(r["id"], r["schema"], r["volte"]) for r in a["routine"]],
                         [(r["id"], r["schema"], r["volte"]) for r in b["routine"]])

    def test_conta_conferma_la_routine(self):
        self.fabbrica()
        codice, d = self.cli_json("conta", "Mail:finestra > Anteprima:apri_allegato:pdf > Anteprima:copia > Chrome:*")
        self.assertEqual(codice, 0)
        self.assertEqual(d["volte"], 15)
        self.assertEqual(d["giorni"], 5)
        codice, d = self.cli_json("conta", "Calendario:clic:copia > ** > Slack:invia")
        self.assertGreaterEqual(d["volte"], 12)
        codice, d = self.cli_json("conta", "Chrome:incolla:[SITO_*]/campo")
        self.assertGreaterEqual(d["volte"], 30)


class TestRoutineIncrementale(Base):
    def test_analisi_a_giorni_uguale_a_da_zero(self):
        import datetime as dt
        import fabbrica
        f = fabbrica.Fabbrica(self.dati)
        oggi = dt.date.today()
        for i in range(5):
            f.giornata(oggi - dt.timedelta(days=4 - i), i)
            f.conn.commit()
            self.cli_json("analizza")
        f.chiudi()
        codice, a = self.cli_json("routine", "--top", "5")
        self.cli_json("analizza", "--da-zero")
        codice, b = self.cli_json("routine", "--top", "5")
        self.assertEqual([(r["schema"], r["volte"]) for r in a["routine"]],
                         [(r["schema"], r["volte"]) for r in b["routine"]])
