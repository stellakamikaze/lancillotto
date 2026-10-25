"""Aggiornamento automatico: un repository finto con un remoto locale, nessuna rete."""
from __future__ import annotations

import subprocess
from pathlib import Path

from base import Base
from lancillotto import aggiorna


def git(cartella, *a):
    return subprocess.run(["git", "-C", str(cartella)] + list(a), capture_output=True, text=True, check=True).stdout


class TestAggiorna(Base):
    def setUp(self):
        super().setUp()
        self.remoto = self.tmp / "remoto.git"
        subprocess.run(["git", "init", "--bare", "-b", "main", str(self.remoto)], capture_output=True, check=True)
        self.lavoro = self.tmp / "lavoro"
        subprocess.run(["git", "clone", "-q", str(self.remoto), str(self.lavoro)], capture_output=True, check=True)
        for k, v in (("user.email", "t@t"), ("user.name", "t")):
            git(self.lavoro, "config", k, v)
        (self.lavoro / "lancillotto").mkdir()
        (self.lavoro / "lancillotto" / "a.py").write_text("x = 1\n")
        git(self.lavoro, "add", "-A")
        git(self.lavoro, "commit", "-qm", "uno")
        git(self.lavoro, "push", "-q", "origin", "main")
        self.copia = self.tmp / "copia"
        subprocess.run(["git", "clone", "-q", str(self.remoto), str(self.copia)], capture_output=True, check=True)

    def nuovo_commit(self, percorso, testo):
        p = self.lavoro / percorso
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(testo)
        git(self.lavoro, "add", "-A")
        git(self.lavoro, "commit", "-qm", "nuovo")
        git(self.lavoro, "push", "-q", "origin", "main")

    def test_niente_di_nuovo(self):
        self.assertEqual(aggiorna.aggiorna(radice=self.copia)["esito"], "nessuno")

    def test_avanti_veloce_python(self):
        self.nuovo_commit("lancillotto/a.py", "x = 2\n")
        self.assertEqual(aggiorna.aggiorna(radice=self.copia, installa=False)["esito"], "applicato")
        self.assertEqual((self.copia / "lancillotto" / "a.py").read_text(), "x = 2\n")

    def test_binario_cambiato_chiede_installazione(self):
        self.nuovo_commit("registratore/Sorgenti/App.swift", "// nuovo\n")
        esito = aggiorna.aggiorna(radice=self.copia, installa=False)
        self.assertEqual(esito["esito"], "binario")

    def test_copia_con_modifiche_locali_non_si_tocca(self):
        self.nuovo_commit("lancillotto/a.py", "x = 2\n")
        (self.copia / "lancillotto" / "a.py").write_text("x = 99\n")
        self.assertEqual(aggiorna.aggiorna(radice=self.copia, installa=False)["esito"], "bloccato")
        self.assertEqual((self.copia / "lancillotto" / "a.py").read_text(), "x = 99\n")

    def test_una_volta_al_giorno(self):
        aggiorna.aggiorna(radice=self.copia)
        self.assertEqual(aggiorna.aggiorna(se_serve=True, radice=self.copia)["esito"], "rimandato")
