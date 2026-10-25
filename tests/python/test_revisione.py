"""Correzioni della revisione del 24/10/2026: ogni test nasce da un difetto confermato e
fallisce sulla versione di prima. Il numero nel nome è quello del difetto nell'elenco."""
from __future__ import annotations

import contextlib
import datetime as dt
import io
import json
import os
import plistlib
import sqlite3
import subprocess
import threading
import time
from unittest import mock

import fabbrica
from base import RADICE, Base
from lancillotto import cli, impostazioni, registro, uscita


def ora_ms() -> int:
    return int(time.time() * 1000)


class Piccola(Base):
    """Registro piccolo, scritto a mano evento per evento con la Fabbrica."""

    def nuova(self, battito_ms=None):
        f = fabbrica.Fabbrica(self.dati, battito_ms=battito_ms)
        f.inizio_giorno(dt.date.today(), ora=9)
        return f

    def an(self):
        c = sqlite3.connect(str(self.dati / "analisi.sqlite"))
        c.row_factory = sqlite3.Row
        self.addCleanup(c.close)
        return c

    def reg(self):
        c = sqlite3.connect(str(self.dati / "registro.sqlite"))
        c.row_factory = sqlite3.Row
        self.addCleanup(c.close)
        return c


class TestAppunti(Piccola):
    def test_23_copia_poi_cambio_app_entro_mezzo_secondo(self):
        f = self.nuova()
        f.finestra("anteprima", "Fattura.pdf", passo=3000)
        f.comando("anteprima", "cmd+c", passo=300)          # cmd+c in Anteprima
        f.finestra("chrome", "Portale", passo=150)          # cmd+tab prima del controllo degli appunti
        f.cc += 1
        f.evento("appunti", "chrome", None, det={"tipi": ["public.utf8-plain-text"], "riservato": 0, "len": 8},
                 cc=f.cc, passo=1500)                       # il registratore lo attribuisce a Chrome
        p = f.incolla("chrome", passo=2000)
        f.fine_giorno()
        f.chiudi()
        self.cli_json("analizza")
        lg = self.an().execute("SELECT * FROM legame WHERE tipo = 'appunti' AND a_evento = ?", (p,)).fetchone()
        self.assertIsNotNone(lg)
        self.assertEqual(lg["da_simbolo"], "Anteprima:copia", "la sorgente del legame è l'app sbagliata")
        self.assertEqual(lg["da_app"], f.app_id["anteprima"])
        self.assertGreaterEqual(lg["confidenza"], 0.9)
        firme = [r[0] for r in self.an().execute("SELECT firma FROM episodio")]
        self.assertFalse(any("Chrome:copia" in x for x in firme), "copia falsa in Chrome: %s" % firme)

    def test_24_incolla_speciale_e_incolla_e_adatta_stile(self):
        f = self.nuova()
        f.finestra("excel", "Budget.xlsx", passo=2000)
        a = f.copia("excel", passo=1500)
        f.finestra("excel", "Budget.xlsx", passo=1000)
        m = f.evento("menu", "excel", None, det={"percorso": "Modifica > Incolla speciale…"}, cc=f.cc, passo=3000)
        f.fine_giorno()
        f.chiudi()
        self.cli_json("analizza")
        lg = self.an().execute("SELECT * FROM legame WHERE tipo = 'appunti' AND a_evento = ?", (m,)).fetchone()
        self.assertIsNotNone(lg, "Incolla speciale senza legame")
        self.assertEqual(lg["da_evento"], a)

    def test_25_cambio_da_fuori_senza_copia_ne_input(self):
        f = self.nuova()
        f.finestra("chrome", "Notizie", passo=8000)
        f.cc += 1   # Universal Clipboard: il changeCount cambia, l'app attiva resta Chrome
        f.evento("appunti", "chrome", None, det={"tipi": ["public.utf8-plain-text"], "riservato": 0, "len": 20},
                 cc=f.cc, passo=2000)
        p = f.incolla("chrome", passo=2000)
        f.fine_giorno()
        f.chiudi()
        self.cli_json("analizza")
        lg = self.an().execute("SELECT * FROM legame WHERE tipo = 'appunti' AND a_evento = ?", (p,)).fetchone()
        self.assertIsNotNone(lg)
        self.assertLess(lg["confidenza"], 0.5, "cambio da fuori con confidenza alta")
        self.assertEqual(json.loads(lg["prova"]).get("sfondo"), 1)
        firme = [r[0] for r in self.an().execute("SELECT firma FROM episodio")]
        self.assertFalse(any("Chrome:copia" in x for x in firme), "simbolo di copia falso: %s" % firme)

    def test_26_stesso_oggetto_dalle_impronte_di_schermo_e_selezione(self):
        f = self.nuova()
        f.finestra("anteprima", "Fattura scansionata.pdf", passo=2000)
        s1 = f.schermo("anteprima", ["numero ordine 774411"])
        f.impronta(s1, "774411", "numero", "schermo")
        a = f.copia("anteprima", passo=2000)
        f.impronta(a, "774411", "numero", "selezione")
        f.finestra("chrome", "Portale ordini", passo=1000)
        f.url("chrome", "portale-esempio-ordini.it", "ordini", passo=2000)
        s2 = f.schermo("chrome", ["ordine 774411 ricevuto"])
        f.impronta(s2, "774411", "numero", "schermo")
        f.incolla("chrome", passo=2000)
        f.fine_giorno()
        f.chiudi()
        self.cli_json("analizza")
        n = self.an().execute("SELECT COUNT(*) FROM legame WHERE tipo = 'stesso_oggetto'").fetchone()[0]
        self.assertGreaterEqual(n, 1, "le impronte di schermo e selezione non entrano nel confronto")


class TestAnalisi(Piccola):
    def test_14_id_riusati_dopo_una_cancellazione_non_lasciano_testo(self):
        f = self.nuova()
        f.finestra("note", "Note", passo=1000)
        for k in range(5):
            f.schermo("note", ["riga%d segretissimo%d" % (k, k)])
        f.chiudi()
        self.cli_json("analizza")
        c = self.reg()
        # come il "dimentica" del registratore dal menu: via gli ultimi due schermi e le loro righe,
        # e meta.cancellazioni + 1 (Registro.dimenticaInCoda)
        ultimi = [r[0] for r in c.execute("SELECT id FROM evento WHERE tipo = 'schermo' ORDER BY id DESC LIMIT 2")]
        for e in ultimi:
            c.execute("DELETE FROM schermo WHERE evento_id = ?", (e,))
            c.execute("DELETE FROM evento WHERE id = ?", (e,))
        c.execute("DELETE FROM riga WHERE id NOT IN (SELECT CAST(j.value AS INTEGER) FROM schermo, json_each(schermo.aggiunte) j)")
        c.execute("INSERT INTO meta(chiave, valore) VALUES ('cancellazioni', '1') ON CONFLICT(chiave)"
                  " DO UPDATE SET valore = CAST(CAST(valore AS INTEGER) + 1 AS TEXT)")
        c.commit()
        # dopo il riavvio, righe e schermi nuovi riprendono gli stessi id
        f.riapri()
        for k in range(2):
            f.schermo("note", ["innocuo%d" % k])
        f.chiudi()
        codice, d = self.cli_json("cerca", "segretissimo4")
        self.assertEqual(d["schermo"], [], "il testo dimenticato è ancora cercabile")
        codice, d = self.cli_json("cerca", "innocuo1")
        self.assertTrue(d["schermo"], "il testo nuovo non è indicizzato")

    def test_27_schermo_scritto_durante_l_analisi_non_si_duplica(self):
        f = self.nuova()
        f.finestra("note", "Note", passo=1000)
        f.schermo("note", ["prima riga"])
        f.chiudi()
        self.cli_json("analizza")
        f.riapri()
        f.finestra("note", "Note due", passo=1000)
        f.conn.commit()
        vera = registro.firma_coda

        def firma_e_scrive(conn):
            out = vera(conn)
            # il registratore scrive un lotto mentre l'analisi gira
            w = fabbrica.Fabbrica.__new__(fabbrica.Fabbrica)
            w.__dict__.update(f.__dict__)
            w.conn = sqlite3.connect(str(f.percorso))
            w.schermo("note", ["Zanzibar unica"])
            w.conn.commit()
            w.conn.close()
            return out

        with mock.patch.object(registro, "firma_coda", firma_e_scrive):
            self.cli_json("analizza")
        f.t += 600000
        f.finestra("note", "Note tre", passo=1000)
        f.chiudi()
        self.cli_json("analizza")
        doppie = self.an().execute("SELECT riga_id, schermo_id, COUNT(*) FROM riga_vista GROUP BY riga_id, schermo_id"
                                   " HAVING COUNT(*) > 1").fetchall()
        self.assertEqual(doppie, [], "riga_vista con coppie doppie")
        codice, d = self.cli_json("cerca", "Zanzibar")
        self.assertEqual(len(d["schermo"]), 1, "cerca conta due volte lo stesso schermo: %s" % d["schermo"])


class TestRifiuti(Base):
    def test_22_rifiutata_non_torna_mentre_i_giorni_crescono(self):
        f = fabbrica.Fabbrica(self.dati)
        oggi = dt.date.today()
        giorni = [oggi - dt.timedelta(days=4 - i) for i in range(5)]
        for i in range(2):
            f.giornata(giorni[i], i)
        f.conn.commit()
        self.cli_json("analizza")
        codice, d = self.cli_json("routine", "--top", "5")
        r1 = next(r for r in d["routine"] if "Anteprima" in r["schema"] and "Chrome" in r["schema"])
        self.cli_json("rifiuta", str(r1["id"]), "lo fa già la contabilità")
        for i in range(2, 5):
            f.giornata(giorni[i], i)
            f.conn.commit()
            self.cli_json("analizza")
            codice, d = self.cli_json("routine", "--top", "20")
            self.assertNotIn(r1["id"], [r["id"] for r in d["routine"]], "la routine rifiutata è tornata al giorno %d" % (i + 1))
        f.chiudi()
        codice, p = self.cli_json("precedenti")
        self.assertIn(r1["id"], [r["id"] for r in p["routine_decise"] if r["stato"] == "rifiutata"],
                      "il rifiuto non è più fra i precedenti")


class TestCLI(Base):
    def setUp(self):
        super().setUp()
        self.f = self.fabbrica()

    def conta(self, sql, *arg):
        conn = sqlite3.connect(str(self.dati / "registro.sqlite"))
        try:
            return conn.execute(sql, arg).fetchone()[0]
        finally:
            conn.close()

    def imp(self):
        return impostazioni.leggi()

    def app_finta(self, nome, bundle, cfnome=None):
        p = self.app_dir / (nome + ".app") / "Contents"
        p.mkdir(parents=True)
        with open(str(p / "Info.plist"), "wb") as fh:
            plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleName": cfnome or nome}, fh)

    def test_8_escludi_app_col_nome_breve(self):
        prima = self.conta("SELECT COUNT(*) FROM evento e JOIN app a ON a.id = e.app_id WHERE a.bundle = 'com.microsoft.Excel'")
        self.assertGreater(prima, 0)
        codice, d = self.cli_json("escludi", "app", "Excel", "--json")
        self.assertEqual(codice, 0, d)
        self.assertEqual(d["eventi_cancellati"], prima)
        self.assertIn("com.microsoft.Excel", self.imp()["escludi_app"])
        self.assertNotIn("Excel", self.imp()["escludi_app"])
        codice, d = self.cli_json("escludi", "app", "Chrome", "--json")
        self.assertIn("com.google.Chrome", self.imp()["escludi_app"])

    def test_8_escludi_app_installata_ma_mai_vista_e_app_sconosciuta(self):
        self.app_finta("Microsoft Outlook", "com.microsoft.Outlook")
        codice, d = self.cli_json("escludi", "app", "Outlook", "--json")
        self.assertEqual(codice, 0, d)
        self.assertIn("com.microsoft.Outlook", self.imp()["escludi_app"])
        prima = self.imp()["escludi_app"]
        codice, d = self.cli_json("escludi", "app", "Zoom", "--json")
        self.assertEqual(codice, 2, "un'app che non esiste risulta esclusa: %s" % d)
        self.assertIn("non trovo", d["errore"])
        self.assertEqual(self.imp()["escludi_app"], prima, "un nome che non è un'app è finito fra le esclusioni")

    def test_31_escludi_sito_senza_dominio_rifiutato(self):
        codice, out = self.cli("escludi", "sito", "portale")
        self.assertEqual(codice, 2)
        self.assertIn("non è un sito", out)
        self.assertNotIn("portale", self.imp().get("escludi_domini", []))

    def test_28_escludi_sito_toglie_i_download_da_quel_sito(self):
        self.assertGreater(self.conta("SELECT COUNT(*) FROM oggetto WHERE provenienza = 'drive.google.com'"), 0)
        codice, d = self.cli_json("escludi", "sito", "drive.google.com", "--json")
        self.assertEqual(codice, 0, d)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento e JOIN oggetto o ON o.id = e.ogg_id"
                                    " WHERE e.tipo LIKE 'file_%' AND o.provenienza = 'drive.google.com'"), 0)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM oggetto WHERE provenienza = 'drive.google.com'"), 0,
                         "provenienza del sito escluso rimasta")
        self.assertEqual(self.conta("SELECT COUNT(*) FROM oggetto WHERE tipo = 'file' AND etichetta LIKE 'Report vendite%xlsx'"), 0,
                         "nome del file scaricato dal sito escluso rimasto")

    def test_12_escludi_con_il_registratore_acceso_aspetta_la_coda(self):
        spotify = self.conta("SELECT id FROM app WHERE bundle = 'com.spotify.client'")
        fatto = threading.Event()

        def registratore():
            # come App.impostazioniCambiate: vede la regola nuova, scrive il lotto in RAM, poi conferma
            fine = time.time() + 5
            while time.time() < fine:
                try:
                    if "com.spotify.client" in self.imp().get("escludi_app", []):
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(0.05)
            c = sqlite3.connect(str(self.dati / "registro.sqlite"), timeout=5)
            c.execute("INSERT INTO evento(ts, dur_ms, tipo, app_id) VALUES (?, 0, 'finestra', ?)", (ora_ms() - 3000, spotify))
            c.execute("INSERT OR REPLACE INTO meta(chiave, valore) VALUES ('esclusioni_applicate', ?)", (str(ora_ms()),))
            c.commit()
            c.close()
            fatto.set()

        t = threading.Thread(target=registratore)
        t.start()
        with mock.patch.object(cli, "ATTESA_ESCLUSIONI_S", 5.0):
            codice, d = self.cli_json("escludi", "app", "Spotify", "--json")
        t.join()
        self.assertTrue(fatto.is_set())
        self.assertEqual(d.get("registratore"), "confermato", d)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM evento WHERE app_id = ?", spotify), 0,
                         "eventi in RAM del registratore arrivati dopo la cancellazione")

    def test_30_dimentica_accorcia_l_evento_a_cavallo(self):
        c = sqlite3.connect(str(self.dati / "registro.sqlite"))
        c.execute("UPDATE meta SET valore = '1000' WHERE chiave = 'ultimo_battito'")   # registratore fermo
        app = c.execute("SELECT id FROM app WHERE bundle = 'com.apple.Preview'").fetchone()[0]
        t = ora_ms() - 20 * 60000
        e = c.execute("INSERT INTO evento(ts, dur_ms, tipo, app_id) VALUES (?, ?, 'finestra', ?)",
                      (t, 20 * 60000, app)).lastrowid
        c.commit()
        c.close()
        codice, d = self.cli_json("dimentica", "10", "--json")
        self.assertEqual(codice, 0, d)
        dur = self.conta("SELECT dur_ms FROM evento WHERE id = ?", e)
        self.assertLessEqual(dur, 10 * 60000 + 5000, "l'evento a cavallo conta ancora i minuti dimenticati")

    def test_36_stato_sensori_facoltativi_e_permesso_arrivato(self):
        c = sqlite3.connect(str(self.dati / "registro.sqlite"))
        t = ora_ms() - 3600000
        c.executemany("INSERT INTO salute(ts, sensore, stato, dettaglio) VALUES (?,?,?,?)", [
            (t, "input", "degradato", "Accessibilità non concessa"),
            (t + 60000, "input", "ok", "Accessibilità concessa: monitor registrati di nuovo"),
            (t + 1000, "ocr", "degradato", "manca il permesso Registrazione schermo: solo testo AX")])
        c.execute("INSERT OR REPLACE INTO meta(chiave, valore) VALUES ('permesso_schermo', '0')")
        c.commit()
        c.close()
        codice, out = self.cli("stato")
        riga = next(r for r in out.splitlines() if r.startswith("Sensori:"))
        self.assertNotIn("input", riga, "input degradato dopo il permesso: %s" % riga)
        self.assertNotIn("ocr", riga, "ocr facoltativo contato come guasto: %s" % riga)
        self.assertIn("Spenti per scelta", out)
        codice, d = self.cli_json("oggi", "--json")
        self.assertFalse(any("sensore input" in x for x in d.get("limiti", [])), d.get("limiti"))

    def test_37_conta_routine_ritrova_le_volte(self):
        codice, d = self.cli_json("routine", "--top", "3", "--json")
        for r in d["routine"]:
            codice, c = self.cli_json("conta", "--routine", str(r["id"]), "--json")
            self.assertEqual(codice, 0, c)
            self.assertEqual(c["volte"], r["volte"], "conta --routine %s smentisce le volte della routine" % r["id"])

    def test_39_riprendi_testo_e_stato_con_registratore_fermo(self):
        c = sqlite3.connect(str(self.dati / "registro.sqlite"))
        c.execute("UPDATE meta SET valore = ? WHERE chiave = 'ultimo_battito'", (str(ora_ms() - 3600000),))
        c.commit()
        c.close()
        codice, out = self.cli("riprendi")
        self.assertIn(cli.APRI_APP, out)
        self.assertNotIn("registra di nuovo", out)
        codice, out = self.cli("stato")
        self.assertIn(cli.APRI_APP, out)
        prima = self.conta("SELECT COUNT(*) FROM consenso")
        codice, d = self.cli_json("testo", "--da", "10:00", "--a", "10:30", "--json")
        self.assertEqual(d.get("consenso"), "impossibile", d)
        self.assertEqual(self.conta("SELECT COUNT(*) FROM consenso"), prima, "richiesta di consenso che nessuno vedrà")

    def test_40_errori_in_italiano(self):
        codice, out = self.cli("pausa", "2h")
        self.assertNotEqual(codice, 0)
        self.assertNotIn("invalid literal", out)
        self.assertIn("minuti", out)
        self.assertFalse(out.strip().startswith("{"), "errore in JSON a una persona: %s" % out)
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            cli.main(["dimentica", "dieci"])
        self.assertIn("numero intero", err.getvalue())
        self.assertNotIn("invalid int value", err.getvalue())
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            cli.main([])
        self.assertIn("mancano", err.getvalue())
        codice, out = self.cli("cancella-tutto", stdin="si\n")
        self.assertEqual(codice, 1)
        self.assertIn("maiuscolo", out)


class TestUscitaL2(Base):
    def test_5_url_senza_schema_perde_la_query(self):
        t = uscita.pulisci_l2("apri portale.esempio.it/reset?token=QUERYVELENO2&cliente=RossiSpa")
        self.assertNotIn("QUERYVELENO2", t)
        self.assertNotIn("RossiSpa", t)
        self.assertEqual(uscita.pulisci_l2("Totale 1.250,00 euro"), "Totale 1.250,00 euro")


class TestDocumenti(Base):
    def leggi(self, rel):
        return (RADICE / rel).read_text(encoding="utf-8")

    def test_33_installatore_e_readme_dicono_che_i_campi_si_annotano(self):
        for rel in ("README.md", "installa.sh"):
            t = self.leggi(rel)
            self.assertNotIn("non registra quello che scrivi", t, rel)
            self.assertNotIn("Non vede cosa scrivi", t, rel)
            self.assertIn("valore dei campi", t, rel)

    def test_38_perimetro_della_memoria(self):
        self.assertNotIn("scrivono solo la memoria locale", self.leggi("skill/SKILL.md"))
        readme = self.leggi("README.md")
        self.assertNotIn("Ci sono due perimetri", readme)
        self.assertIn("memoria di Claude", readme)

    def test_41_le_voci_di_menu_del_readme_esistono(self):
        import re
        readme = self.leggi("README.md")
        app = self.leggi("registratore/Sorgenti/App.swift") + self.leggi("registratore/Sorgenti/FinestraPrincipale.swift")
        righe = [r for r in readme.splitlines() if r.startswith("| ") and r.count("|") == 4]
        voci = []
        for r in righe:
            menu = r.split("|")[2].strip()
            voci += [v.strip() for v in menu.split(",") if v.strip() and v.strip() != "Finestra o menu"]
        self.assertTrue(voci)
        for v in voci:
            base = re.sub(r"\s*<[^>]+>$", "", v)
            self.assertIn('"%s' % base, app, "voce di menu del README che l'app non ha: %s" % v)


class TestInstallatore(Base):
    def test_35_aggiorna_da_una_cartella_nuova_ricollega_cli_e_skill(self):
        home = self.tmp / "casa"
        vecchia = self.tmp / "vecchia"
        (vecchia / "bin").mkdir(parents=True)
        (vecchia / "skill").mkdir()
        (vecchia / "bin" / "lancillotto").write_text("#!/bin/sh\n")
        (vecchia / "skill" / "SKILL.md").write_text("vecchia\n")
        (home / ".local" / "bin").mkdir(parents=True)
        (home / ".claude" / "skills").mkdir(parents=True)
        (home / "Applications" / "Lancillotto.app").mkdir(parents=True)
        os.symlink(str(vecchia / "bin" / "lancillotto"), str(home / ".local" / "bin" / "lancillotto"))
        os.symlink(str(vecchia / "skill"), str(home / ".claude" / "skills" / "lancillotto"))
        env = dict(os.environ, HOME=str(home), LANCILLOTTO_DIR=str(self.tmp / "dati-inst"),
                   PATH=str(home / ".local" / "bin") + os.pathsep + os.environ.get("PATH", ""))
        r = subprocess.run(["bash", str(RADICE / "installa.sh"), "--solo-verifica", "--aggiorna"],
                           capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ricollegare", r.stdout)
        self.assertNotIn("non lo tocco", r.stdout)
        r = subprocess.run(["bash", str(RADICE / "installa.sh"), "--solo-verifica"],
                           capture_output=True, text=True, env=env, timeout=120)
        self.assertIn("rm \"", r.stdout, "senza --aggiorna manca il comando esatto")
        self.assertIn("--aggiorna", r.stdout)
