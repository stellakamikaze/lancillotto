"""impostazioni.json: lettura e scrittura atomica (docs/CONTRATTO.md, "Impostazioni").

La scrittura passa da un file .tmp nella stessa cartella e da os.replace, come
arturo/bin/memoria.py. Il registratore sorveglia la cartella e rilegge entro 2 s.
"""
from __future__ import annotations

import copy
import datetime as dt
import json

from . import percorsi

PREDEFINITE = {
    "versione": 1,
    "pausa_fino": 0,
    "conservazione_giorni": 14,
    "ocr": True,
    "testo_schermo": False,
    "valori_campi": False,
    "telemetria": True,
    "cartelle": ["~/Downloads", "~/Documents", "~/Desktop"],
    "escludi_app": [],
    "escludi_domini": [],
    "dimentica_richieste": [],
}


def leggi() -> dict:
    dati = copy.deepcopy(PREDEFINITE)
    p = percorsi.impostazioni()
    try:
        letto = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return dati
    if isinstance(letto, dict):
        dati.update(letto)
    return dati


def scrivi(dati: dict) -> None:
    percorsi.assicura_cartella()
    testo = json.dumps(dati, ensure_ascii=False, indent=1) + "\n"
    percorsi.scrivi_600(percorsi.impostazioni(), testo)


def aggiorna(**campi) -> dict:
    dati = leggi()
    dati.update(campi)
    scrivi(dati)
    return dati


def pausa_fino_ms(arg: str, ora_ms: int) -> int:
    """'domani' = mezzanotte locale di domani; un numero = minuti da adesso (default 60)."""
    a = (arg or "").strip().lower()
    if a == "domani":
        oggi = dt.datetime.fromtimestamp(ora_ms / 1000).date()
        mezzanotte = dt.datetime.combine(oggi + dt.timedelta(days=1), dt.time(0, 0))
        return int(mezzanotte.timestamp() * 1000)
    try:
        minuti = int(a) if a else 60
    except ValueError:
        raise ValueError("scrivi la durata in minuti, come numero (lancillotto pausa 120), "
                         "oppure lancillotto pausa domani")
    if minuti <= 0:
        raise ValueError("i minuti di pausa devono essere più di zero")
    return ora_ms + minuti * 60000


def aggiungi_a_lista(chiave: str, valore) -> dict:
    dati = leggi()
    lista = list(dati.get(chiave) or [])
    if valore not in lista:
        lista.append(valore)
    dati[chiave] = lista
    scrivi(dati)
    return dati
