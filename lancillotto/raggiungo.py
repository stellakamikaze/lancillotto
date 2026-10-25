"""Cosa Claude Code (e Arturo) raggiunge su questo Mac, senza eseguire niente in rete.

- CLI presenti nel PATH;
- server MCP: solo i nomi delle chiavi mcpServers di ~/.claude.json e ~/.claude/settings.json;
- app scriptabili: Info.plist con NSAppleScriptEnabled o OSAScriptingDefinition, in /Applications
  e ~/Applications, solo i nomi.
Con LANCILLOTTO_HOME_TEST la home è finta e /Applications non si guarda: è il caso dei test.
"""
from __future__ import annotations

import json
import os
import plistlib
import shutil
from pathlib import Path

from . import percorsi

CLI = ("gws", "gh", "scrape", "bw", "sqlite3", "python3", "node", "claude", "osascript", "jq")

# Simbolo -> canali che lo raggiungono, se presenti.
DOMINI_CLI = {
    "google.com": "gws", "gmail.com": "gws", "mail.google.com": "gws", "drive.google.com": "gws",
    "docs.google.com": "gws", "sheets.google.com": "gws", "calendar.google.com": "gws",
    "github.com": "gh",
}


def _cartelle_app() -> list:
    out = [percorsi.home() / "Applications"]
    if not os.environ.get("LANCILLOTTO_HOME_TEST", "").strip():
        out = [Path("/Applications"), Path("/System/Applications")] + out
    return out


def _app_in(cartella: Path) -> list:
    out = []
    try:
        voci = sorted(cartella.iterdir())
    except OSError:
        return out
    for v in voci:
        if v.suffix == ".app":
            out.append(v)
        elif v.is_dir() and not v.name.startswith("."):
            try:
                out.extend(sorted(x for x in v.iterdir() if x.suffix == ".app"))
            except OSError:
                continue
    return out


def app_scriptabili() -> list:
    nomi = []
    for c in _cartelle_app():
        for app in _app_in(c):
            plist = app / "Contents" / "Info.plist"
            try:
                with plist.open("rb") as f:
                    info = plistlib.load(f)
            except Exception:
                continue
            if not isinstance(info, dict):
                continue
            if info.get("NSAppleScriptEnabled") in (True, "YES", "true") or info.get("OSAScriptingDefinition"):
                nome = str(info.get("CFBundleName") or info.get("CFBundleDisplayName") or app.stem)
                if nome not in nomi:
                    nomi.append(nome)
    return sorted(nomi, key=str.lower)


def server_mcp() -> list:
    nomi = []
    for p in (percorsi.home() / ".claude.json", percorsi.home() / ".claude" / "settings.json"):
        try:
            dati = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        servers = dati.get("mcpServers") if isinstance(dati, dict) else None
        if isinstance(servers, dict):
            for k in servers:
                if k not in nomi:
                    nomi.append(str(k))
    return sorted(nomi)


def cli_presenti() -> list:
    return [c for c in CLI if shutil.which(c)]


def raggiungo() -> dict:
    return {"cli": cli_presenti(), "mcp": server_mcp(), "app_scriptabili": app_scriptabili()}


def canali(mappa: dict):
    """Una funzione simbolo -> canali che lo raggiungono, data la mappa di raggiungo()."""
    cli = set(mappa.get("cli") or [])
    app = {a.lower() for a in (mappa.get("app_scriptabili") or [])}
    sinonimi = {"anteprima": "preview", "calendario": "calendar", "note": "notes",
                "promemoria": "reminders", "contatti": "contacts", "terminale": "terminal"}

    def f(simbolo: str) -> list:
        parti = simbolo.split(":")
        out = []
        nome = parti[0]
        if nome == "File":
            out.append("file locali")
        elif nome.lower() in app or sinonimi.get(nome.lower(), "") in app:
            out.append(nome)
        for p in parti[1:]:
            pulito = p.split("/")[0]
            c = DOMINI_CLI.get(pulito)
            if c and c in cli:
                out.append(c)
        return out
    return f
