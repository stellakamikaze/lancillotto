"""Telemetria: elenco chiuso, invio a un server finto locale, spegnimento, allineamento con il server di Arturo."""
from __future__ import annotations

import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

from base import ARTURO, Base
from lancillotto import telemetria


class ServerFinto(HTTPServer):
    def __init__(self, stato=200):
        self.ricevuti = []
        self.agenti = []
        self.stato = stato

        class Gestore(BaseHTTPRequestHandler):
            def do_POST(gestore):
                n = int(gestore.headers.get("content-length") or 0)
                self.ricevuti.append(json.loads(gestore.rfile.read(n)))
                self.agenti.append(gestore.headers.get("user-agent", ""))
                gestore.send_response(self.stato)
                gestore.end_headers()
                gestore.wfile.write(b"{}")

            def log_message(gestore, *a):
                pass

        super().__init__(("127.0.0.1", 0), Gestore)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/lancillotto/eventi" % self.server_address[1]


class TestTelemetria(Base):
    def setUp(self):
        super().setUp()
        self._env = {k: os.environ.pop(k, None) for k in ("DO_NOT_TRACK", "LANCILLOTTO_TELEMETRIA", "LANCILLOTTO_TELEMETRIA_URL")}

    def tearDown(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        super().tearDown()

    def coda(self):
        p = self.dati / "telemetria-coda.jsonl"
        return [json.loads(r) for r in p.read_text(encoding="utf-8").splitlines()] if p.exists() else []

    def test_elenco_chiuso(self):
        self.assertTrue(telemetria.registra("giorno", "eventi:2"))
        for evento, valore in [("url_assente", "com.esempio.GestionaleRossi"), ("comando", "cerca Mario Rossi"),
                               ("giorno", "eventi:1234"), ("titolo", "Fattura 2026"), ("errore", "Traceback /Users/x"),
                               ("finestra", "https://web.bbva.it")]:
            self.assertFalse(telemetria.registra(evento, valore), "%s=%s accettato" % (evento, valore))
        self.assertEqual([r["evento"] for r in self.coda()], ["giorno"])

    def test_invio_svuota_la_coda_e_manda_solo_campi_noti(self):
        srv = ServerFinto()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        os.environ["LANCILLOTTO_TELEMETRIA_URL"] = srv.url
        telemetria.registra("installa", "nuova")
        telemetria.registra("permesso", "ax:si")
        esito = telemetria.invia(forza=True)
        self.assertEqual(esito["in_coda"], 0, esito)
        self.assertTrue(srv.ricevuti, "niente arrivato al server")
        corpo = srv.ricevuti[-1]
        self.assertTrue(srv.agenti[-1].startswith("Lancillotto/"), "user-agent di default: Cloudflare lo blocca (1010)")
        self.assertEqual(sorted(corpo), ["eventi", "installazione", "sistema", "versione"])
        self.assertRegex(corpo["sistema"], r"^macos-\d{2}$")
        for e in corpo["eventi"]:
            self.assertEqual(sorted(e), ["evento", "giorno", "valore"])
            self.assertTrue(telemetria.valido(e["evento"], e["valore"]), e)
        self.assertEqual(self.coda(), [])

    def test_errore_del_server_tiene_la_coda(self):
        srv = ServerFinto(stato=503)
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        os.environ["LANCILLOTTO_TELEMETRIA_URL"] = srv.url
        telemetria.registra("installa", "nuova")
        telemetria.invia(forza=True)
        self.assertIn({"evento": "installa", "valore": "nuova"},
                      [{"evento": r["evento"], "valore": r["valore"]} for r in self.coda()])

    def test_spenta_non_registra_e_cancella(self):
        telemetria.registra("installa", "nuova")
        telemetria.spegni()
        self.assertEqual(self.coda(), [])
        self.assertFalse(telemetria.registra("installa", "nuova"))
        self.assertEqual(telemetria.invia(forza=True).get("spenta"), "spenta da te")
        telemetria.accendi()
        os.environ["DO_NOT_TRACK"] = "1"
        self.assertFalse(telemetria.registra("installa", "nuova"))

    def test_registro_di_prova_non_va_al_server_vero(self):
        # LANCILLOTTO_DIR è impostata da Base: senza un URL esplicito non parte niente.
        self.assertEqual(telemetria.invia(forza=True).get("motivo"), "registro di prova")

    def test_registra_in_parallelo_non_rovina_la_coda(self):
        import subprocess
        import sys
        from base import RADICE
        cli = str(RADICE / "bin" / "lancillotto")
        proc = [subprocess.Popen([sys.executable, cli, "telemetria", "registra", "permesso", "ax:si"],
                                 stdout=subprocess.DEVNULL, env=dict(os.environ)) for _ in range(16)]
        for p in proc:
            p.wait()
        righe = (self.dati / "telemetria-coda.jsonl").read_text(encoding="utf-8").splitlines()
        for r in righe:
            json.loads(r)  # una riga a metà fa fallire qui
        self.assertEqual(sum(1 for r in righe if '"permesso"' in r), 16)

    def test_fasce(self):
        self.assertEqual([telemetria.fascia("eventi", n) for n in (0, 50, 500, 3000, 10000, 50000)], [0, 1, 2, 3, 4, 5])
        self.assertEqual(telemetria.fascia("ore", 0), 0)

    def test_uguale_al_server_di_arturo(self):
        p = ARTURO / "server" / "lancillotto.js"
        if not p.exists():
            self.skipTest("server di Arturo non accanto")
        nomi = re.findall(r"^  ([a-z_]+): ", re.search(r"EVENTI_LANCILLOTTO = \{(.*?)\n\};", p.read_text(encoding="utf-8"),
                                                       re.S).group(1), re.M)
        self.assertEqual(sorted(nomi), sorted(telemetria.EVENTI))
        verbi = re.findall(r'"([a-z-]+)"', re.search(r"export const VERBI = \[(.*?)\];", p.read_text(encoding="utf-8"),
                                                     re.S).group(1))
        self.assertEqual(sorted(verbi), sorted(telemetria._VERBI.split("|")))

    def test_ogni_verbo_della_cli_e_nell_elenco(self):
        from lancillotto import cli
        sub = next(a for a in cli.parser()._actions if a.__class__.__name__ == "_SubParsersAction")
        self.assertEqual(sorted(sub.choices), sorted(telemetria._VERBI.split("|")))
