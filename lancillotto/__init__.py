"""Lancillotto: analisi del registro e CLI per Claude Code.

Il registratore Swift scrive registro.sqlite; questo pacchetto lo legge, ricava episodi,
legami e routine in analisi.sqlite, e dà a Claude solo aggregati e metadati pseudonimizzati.
Le regole che legano i due lati stanno in docs/CONTRATTO.md.
Solo libreria standard, Python 3.8 o successivo. L'unico modulo che usa la rete è telemetria.py,
che manda a chi mantiene Lancillotto solo eventi da un elenco chiuso, e si spegne.
"""

VERSIONE = "0.2.0"
