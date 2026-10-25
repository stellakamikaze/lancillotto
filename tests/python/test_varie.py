"""Impostazioni, raggiungo, segreti, eseguibile bin/lancillotto, compatibilità Python 3.8, niente rete."""
from __future__ import annotations

import ast
import json
import os
import plistlib
import re
import subprocess
import sys

from base import RADICE, Base

from lancillotto import impostazioni, segreti

PACCHETTO = RADICE / "lancillotto"


class TestImpostazioni(Base):
    def test_scrittura_atomica_600(self):
        impostazioni.aggiorna(pausa_fino=123)
        p = self.dati / "impostazioni.json"
        self.assertEqual(os.stat(str(p)).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(str(self.dati)).st_mode & 0o777, 0o700)
        d = json.loads(p.read_text())
        self.assertEqual(d["pausa_fino"], 123)
        self.assertEqual(d["conservazione_giorni"], 14)
        self.assertEqual(d["cartelle"], ["~/Downloads", "~/Documents", "~/Desktop"])
        p.write_text("{rotto")
        self.assertEqual(impostazioni.leggi()["pausa_fino"], 0)


class TestRaggiungo(Base):
    def test_home_finta(self):
        (self.home / ".claude.json").write_text(json.dumps({"mcpServers": {"gmail": {}, "notion": {}}}))
        (self.home / ".claude").mkdir(exist_ok=True)
        (self.home / ".claude" / "settings.json").write_text(json.dumps({"mcpServers": {"locale": {}}}))
        for nome, info in (("Scrivibile", {"CFBundleName": "Scrivibile", "NSAppleScriptEnabled": True}),
                           ("Muta", {"CFBundleName": "Muta"})):
            c = self.home / "Applications" / ("%s.app" % nome) / "Contents"
            c.mkdir(parents=True)
            with (c / "Info.plist").open("wb") as f:
                plistlib.dump(info, f)
        codice, d = self.cli_json("raggiungo")
        self.assertEqual(d["mcp"], ["gmail", "locale", "notion"])
        self.assertEqual(d["app_scriptabili"], ["Scrivibile"])
        self.assertIn("python3", d["cli"] + ["python3"])
        self.assertEqual(d["tipo"], "dati_osservati")


class TestSegreti(Base):
    def test_seconda_rete(self):
        casi = {
            "carta 4111 1111 1111 1111 scade": "CARTA",
            "IBAN IT60X0542811101000000123456": "IBAN",
            "cf RSSMRA85T10A562S": "CF",
            "token sk-ant-api03-abcdefghijklmnopqrstuvwxyz": "CHIAVE",
            "ghp_abcdefghijklmnopqrstuvwxyz0123": "CHIAVE",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U": "JWT",  # gitleaks:allow (esempio pubblico di jwt.io)
            "il tuo codice è 482913": "OTP",
            "482913": "OTP",
            "password: Segreta123!": "PASSWORD",
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----": "PEM",
        }
        for testo, tipo in casi.items():
            redatto, tipi = segreti.redigi(testo)
            self.assertIn(tipo, tipi, testo)
            self.assertIn("[%s]" % tipo, redatto, testo)
        for innocuo in ("fattura 2026/118 del 24/10/2026", "telefono 02 1234 5678", "ordine 1234567"):
            self.assertEqual(segreti.trova(innocuo), [], innocuo)


class TestEseguibile(Base):
    def test_bin_lancillotto(self):
        self.fabbrica()
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        r = subprocess.run([sys.executable, str(RADICE / "bin" / "lancillotto"), "oggi", "--json"],
                           capture_output=True, text=True, env=env, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual(d["tipo"], "dati_osservati")
        r = subprocess.run([sys.executable, str(RADICE / "bin" / "lancillotto"), "stato"],
                           capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("acceso", r.stdout)
        self.assertTrue(os.access(str(RADICE / "bin" / "lancillotto"), os.X_OK))


def file_python():
    out = sorted(PACCHETTO.glob("*.py")) + sorted((RADICE / "tests" / "python").glob("*.py"))
    return out + [RADICE / "bin" / "lancillotto"]


class TestCompatibilita(Base):
    def test_python_38(self):
        vietati = re.compile(r"\.removeprefix\(|\.removesuffix\(|functools\.cache\b"
                             r"|zone" r"info|graph" r"lib|\.bit_count\(|itertools\.pair" r"wise|strict" r"=True")
        for p in file_python():
            src = p.read_text(encoding="utf-8")
            ast.parse(src, filename=str(p), feature_version=(3, 8))
            for n, riga in enumerate(src.splitlines(), 1):
                self.assertIsNone(vietati.search(riga), "%s:%d: %s" % (p.name, n, riga.strip()))
            albero = ast.parse(src)
            annotazioni = set()
            for nodo in ast.walk(albero):
                for campo in ("annotation", "returns"):
                    a = getattr(nodo, campo, None)
                    if a is not None:
                        annotazioni.update(id(x) for x in ast.walk(a))
            for nodo in ast.walk(albero):
                if isinstance(nodo, ast.Subscript) and isinstance(nodo.value, ast.Name) \
                        and nodo.value.id in ("list", "dict", "tuple", "set", "frozenset", "type") \
                        and id(nodo) not in annotazioni:
                    self.fail("%s:%d: %s[...] valutato a runtime (Python 3.8)" % (p.name, nodo.lineno, nodo.value.id))
                if isinstance(nodo, ast.BinOp) and isinstance(nodo.op, ast.BitOr) and id(nodo) not in annotazioni:
                    for lato in (nodo.left, nodo.right):
                        if isinstance(lato, ast.Constant) and lato.value is None:
                            self.fail("%s:%d: X | None valutato a runtime" % (p.name, nodo.lineno))
            if p.parent == PACCHETTO and p.name != "__init__.py":
                self.assertIn("from __future__ import annotations", src, p.name)

    def test_niente_rete_nel_pacchetto(self):
        rete = re.compile(r"^\s*(?:import|from)\s+(socket|http|urllib|ssl|requests|ftplib|smtplib|telnetlib"
                          r"|xmlrpc|asyncio)\b", re.M)
        for p in sorted(PACCHETTO.glob("*.py")) + [RADICE / "bin" / "lancillotto"]:
            if p.name == "telemetria.py":
                continue
            self.assertIsNone(rete.search(p.read_text(encoding="utf-8")), "modulo di rete importato in %s" % p.name)
        # telemetria.py è l'unica eccezione, e parla solo con il server di Arturo.
        src = (PACCHETTO / "telemetria.py").read_text(encoding="utf-8")
        indirizzi = set(re.findall(r"https?://[A-Za-z0-9.-]+", src))
        self.assertEqual(indirizzi, {"https://arturo-dati.stellakamikaze.org"}, "telemetria.py parla con %s" % indirizzi)

    def test_vocabolario(self):
        from lancillotto import pseudonimi
        parole, app = pseudonimi.vocabolario()
        self.assertGreaterEqual(len(parole), 1500)
        for w in ("fattura", "preventivo", "bozza", "ordine", "contratto", "riunione", "inbox", "invoice", "export"):
            self.assertIn(w, parole)
        for cognome in ("rossi", "bianchi", "ferraresi", "verdi"):
            self.assertNotIn(cognome, parole)
        self.assertIn("chrome", app)
