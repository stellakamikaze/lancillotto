"""Base comune dei test: cartelle temporanee, ambiente isolato, veleni, CLI in processo.

Ogni test ha la sua cartella temporanea: LANCILLOTTO_DIR (dati), LANCILLOTTO_HOME_TEST (home finta)
e LANCILLOTTO_MEMORIA_DIR (memoria Melchior finta) puntano lì. Mai la cartella dati vera.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

QUI = Path(__file__).resolve().parent
RADICE = QUI.parents[1]
for p in (str(RADICE), str(QUI)):
    if p not in sys.path:
        sys.path.insert(0, p)

import fabbrica  # noqa: E402
import veleni  # noqa: E402
from lancillotto import cli  # noqa: E402

VARIABILI = ("LANCILLOTTO_DIR", "LANCILLOTTO_HOME_TEST", "LANCILLOTTO_MEMORIA_DIR", "LANCILLOTTO_RECALL",
             "LANCILLOTTO_APP_DIRS")
ARTURO = Path(os.environ.get("LANCILLOTTO_ARTURO", str(RADICE.parent / "arturo")))


class Base(unittest.TestCase):
    memoria = True

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lancillotto-test-"))
        self.dati = self.tmp / "dati"
        self.home = self.tmp / "home"
        self.mem = self.home / ".claude" / "data" / "memory"
        self.home.mkdir()
        if self.memoria:
            self.mem.mkdir(parents=True)
        self._prima = {k: os.environ.get(k) for k in VARIABILI}
        os.environ["LANCILLOTTO_DIR"] = str(self.dati)
        os.environ["LANCILLOTTO_HOME_TEST"] = str(self.home)
        os.environ["LANCILLOTTO_MEMORIA_DIR"] = str(self.mem)
        os.environ.pop("LANCILLOTTO_RECALL", None)
        # 'escludi app' cerca le app installate solo qui: mai in /Applications del Mac che fa i test
        self.app_dir = self.tmp / "Applications"
        self.app_dir.mkdir()
        os.environ["LANCILLOTTO_APP_DIRS"] = str(self.app_dir)
        # il registratore finto della fabbrica è "acceso" ma non conferma le esclusioni: non si
        # aspettano 6 s a ogni 'escludi'
        p = mock.patch.object(cli, "ATTESA_ESCLUSIONI_S", 0.3)
        p.start()
        self.addCleanup(p.stop)
        veleni.applica(self)

    def tearDown(self):
        for k, v in self._prima.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(str(self.tmp), ignore_errors=True)

    # --- aiuti -----------------------------------------------------------------------------
    def fabbrica(self, **kw):
        f = fabbrica.Fabbrica(self.dati, **kw).cinque_giorni()
        f.chiudi()
        return f

    def cli(self, *argv, stdin: str = None):
        out = io.StringIO()
        vecchio_stdin = sys.stdin
        if stdin is not None:
            sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out):
                codice = cli.main(list(argv))
        finally:
            sys.stdin = vecchio_stdin
        return codice, out.getvalue()

    def cli_json(self, *argv):
        codice, out = self.cli(*argv)
        riga = out.strip().splitlines()[-1] if out.strip() else ""
        try:
            return codice, json.loads(riga)
        except ValueError:
            self.fail("uscita non JSON di %s: %r" % (argv, out[:300]))

    def assertNessunNome(self, testo: str, dove: str):
        for nome in fabbrica.NOMI_VIETATI + fabbrica.CLIENTI:
            self.assertNotIn(nome.lower(), testo.lower(), "nome cliente in uscita (%s): %s" % (dove, nome))
