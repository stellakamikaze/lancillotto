"""Percorsi della cartella dati e dei suoi file (docs/CONTRATTO.md, "Percorsi").

LANCILLOTTO_DIR sostituisce la cartella dati: i test la puntano sempre a una cartella temporanea.
LANCILLOTTO_HOME_TEST sostituisce la home per i test (raggiungo, memoria, cartella dati di default).
LANCILLOTTO_MEMORIA_DIR sostituisce la cartella della memoria Melchior.
LANCILLOTTO_APP_DIRS sostituisce le cartelle in cui 'escludi app' cerca le app installate (test).
"""
from __future__ import annotations

import os
import time
from pathlib import Path


def home() -> Path:
    v = os.environ.get("LANCILLOTTO_HOME_TEST", "").strip()
    return Path(v) if v else Path.home()


def cartella_dati() -> Path:
    v = os.environ.get("LANCILLOTTO_DIR", "").strip()
    if v:
        return Path(v).expanduser()
    return home() / "Library" / "Application Support" / "Lancillotto"


def registro() -> Path:
    return cartella_dati() / "registro.sqlite"


def analisi() -> Path:
    return cartella_dati() / "analisi.sqlite"


def impostazioni() -> Path:
    return cartella_dati() / "impostazioni.json"


def chiave() -> Path:
    return cartella_dati() / "chiave"


def pagina_mostra() -> Path:
    return cartella_dati() / "mostra.html"


def vocabolario_persona() -> Path:
    """Parole in più che la persona ammette in uscita, una per riga."""
    return cartella_dati() / "vocabolario.txt"


def memoria() -> Path:
    v = os.environ.get("LANCILLOTTO_MEMORIA_DIR", "").strip()
    if v:
        return Path(v).expanduser()
    return home() / ".claude" / "data" / "memory"


def cartelle_app() -> list:
    """Dove cercare le app installate per risolvere un nome in bundle id."""
    v = os.environ.get("LANCILLOTTO_APP_DIRS", "").strip()
    if v:
        return [Path(x).expanduser() for x in v.split(os.pathsep) if x.strip()]
    return [home() / "Applications", Path("/Applications"), Path("/Applications/Utilities"),
            Path("/System/Applications"), Path("/System/Applications/Utilities")]


def assicura_cartella() -> Path:
    """Crea la cartella dati con permessi 700 se manca."""
    c = cartella_dati()
    if not c.exists():
        c.mkdir(parents=True, mode=0o700)
        os.chmod(str(c), 0o700)
    return c


def crea_600(p: Path) -> None:
    """Crea il file vuoto con permessi 600 se manca, e li rimette a 600 se c'è."""
    fd = os.open(str(p), os.O_WRONLY | os.O_CREAT, 0o600)
    os.close(fd)
    os.chmod(str(p), 0o600)


def scrivi_600(p: Path, testo: str) -> None:
    """Scrittura atomica con permessi 600: file .tmp nella stessa cartella, fsync, rename."""
    tmp = p.with_name(p.name + ".tmp")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, testo.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(str(tmp), 0o600)
    os.replace(str(tmp), str(p))


def ora_ms() -> int:
    return int(time.time() * 1000)
