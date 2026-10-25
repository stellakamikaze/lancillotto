"""Ponte verso la memoria Melchior (docs/PROGETTAZIONE.md, sezione 7).

- conferma ID: solo dopo il sì scritto della persona. Scrive <memoria>/pattern/
  pattern-lancillotto-<slug>.md. Descrizione, trigger e domande le scrive Claude con parole sue
  (--descrizione, --trigger, --domanda): la CLI rifiuta URL, segnaposto, segreti e ID lunghi.
  Il corpo nasce dagli aggregati della routine, mai dal testo del registro.
- rifiuta ID "motivo": lo stato diventa rifiutata e una riga va nella nota unica
  feedback/feedback-lancillotto-cosa-non-automatizzare.md.
- automatizzata ID "con cosa": lo stato e, se la nota c'è, una riga nella nota.
- precedenti ["testo"]: le routine già decise e le note vicine (melchior_recall.py se c'è,
  altrimenti una ricerca semplice sui file pattern-lancillotto-*).
Memoria = LANCILLOTTO_MEMORIA_DIR o ~/.claude/data/memory. Se la cartella non esiste, niente nota:
lo stato resta in analisi.sqlite e il messaggio suggerisce 'arturo memoria accendi'.
Il frontmatter passa i controlli di arturo/hooks/melchior-postwrite.py (YAML valido, scalari tra
virgolette dritte, liste a blocchi) e di memory-write-scanner.py (niente URL, base64, segreti,
frasi da iniezione; almeno 2 parole nei trigger e qualche answers).
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

from . import analisi, episodi, percorsi, pseudonimi, segreti

URL_RE = re.compile(r"(?i)(?:https?://|ftp://|www\.|\b[a-z0-9-]+\.(?:it|com|org|net|io|eu|so|ai|app|dev|co"
                    r"|info|biz|me|gov|edu|uk|de|fr|es|ch)\b)")
SEGNAPOSTO_RE = re.compile(r"\[(?:P\d+|SITO_\d+|APP_\d+|CARTA|IBAN|CF|CHIAVE|JWT|PEM|OTP|PASSWORD|URL"
                           r"|PERCORSO|EMAIL|esclusa)[^\]]*\]")
ID_LUNGO = re.compile(r"(?<![\w-])(?=[\w-]*\d)(?=[\w-]*[A-Za-z])[\w-]{12,}(?![\w-])|\d{9,}|\b[0-9a-fA-F]{12,}\b")
INIEZIONE = re.compile(r"(?i)ignora\s+(?:le\s+|tutte\s+le\s+)?istruzioni|dimentica\s+(?:quanto|le istruzioni)"
                       r"|ignore\s+(?:all\s+)?(?:previous|prior)|new\s+system\s+prompt|system\s+prompt")
INVISIBILI = re.compile(r"[​‌‍⁠﻿‪-‮⁦-⁩]")
PERCORSO_RE = re.compile(r"(?:~|/)(?:[^\s/]+/)+")
BASE64 = re.compile(r"[A-Za-z0-9+/]{40,}={0,2}")
VUOTE = {"di", "a", "da", "in", "con", "su", "per", "tra", "fra", "il", "lo", "la", "i", "gli", "le", "un",
         "uno", "una", "e", "o", "del", "della", "dei", "delle", "al", "alla", "dal", "dalla", "nel",
         "nella", "che", "ogni", "circa", "the", "of", "and", "to"}
NOTA_RIFIUTI = "feedback-lancillotto-cosa-non-automatizzare"
DOMANDE_BASE = ("Cosa ha osservato Lancillotto su questa routine?",
                "Come abbiamo deciso di gestire questa routine ripetuta?")
SUGGERIMENTO = ("la memoria Melchior non è accesa su questo computer: lo stato è salvato nell'analisi. "
                "Per avere la nota lancia 'arturo memoria accendi', poi ripeti il comando.")


class Rifiutato(Exception):
    """Un testo di Claude o della persona non può entrare in una nota."""


def problemi_testo(campo: str, testo: str, massimo: int = 300) -> list:
    t = testo or ""
    out = []
    if not t.strip():
        out.append("%s vuoto" % campo)
        return out
    if len(t) > massimo:
        out.append("%s oltre %d caratteri" % (campo, massimo))
    if '"' in t or "\\" in t or "\n" in t or "\r" in t:
        out.append("%s contiene virgolette doppie, barre rovesciate o a capo: usa parole semplici" % campo)
    if URL_RE.search(t):
        out.append("%s contiene un URL o un dominio" % campo)
    if PERCORSO_RE.search(t):
        out.append("%s contiene un percorso di file" % campo)
    if SEGNAPOSTO_RE.search(t):
        out.append("%s contiene un segnaposto del registro ([P#], [SITO_n]...): scrivi con parole tue" % campo)
    if segreti.trova(t):
        out.append("%s contiene un segreto (%s)" % (campo, ", ".join(segreti.trova(t))))
    if ID_LUNGO.search(t) or BASE64.search(t):
        out.append("%s contiene un identificativo lungo" % campo)
    if INIEZIONE.search(t):
        out.append("%s contiene una frase da istruzione nascosta" % campo)
    if INVISIBILI.search(t):
        out.append("%s contiene caratteri invisibili" % campo)
    return out


def valida(campi: list) -> None:
    """campi: lista di (nome, testo). Solleva Rifiutato con tutti i problemi trovati."""
    probl = []
    for nome, testo in campi:
        probl.extend(problemi_testo(nome, testo))
    if probl:
        raise Rifiutato("; ".join(probl))


def slug(testo: str, massimo: int = 50) -> str:
    t = unicodedata.normalize("NFKD", testo or "").encode("ascii", "ignore").decode("ascii").lower()
    parole = [w for w in re.findall(r"[a-z0-9]+", t) if w not in VUOTE]
    out = "-".join(parole[:6])[:massimo].strip("-")
    return out or "routine"


def _q(testo: str) -> str:
    """Scalare YAML tra virgolette dritte (il testo è già validato: niente virgolette né a capo)."""
    return '"%s"' % testo.replace('"', "'")


def frontmatter(nome: str, descrizione: str, tipo: str, entity: str, triggers: list,
                answers: list, sources: list, oggi: str) -> str:
    righe = ["---", "name: %s" % _q(nome), "description: %s" % _q(descrizione), "type: %s" % _q(tipo),
             "entity_type: %s" % _q(entity), "created: %s" % _q(oggi), "updated: %s" % _q(oggi),
             "last_verified: %s" % _q(oggi), "triggers:"]
    righe += ["  - %s" % _q(t) for t in triggers]
    righe.append("answers:")
    righe += ["  - %s" % _q(a) for a in answers]
    righe.append("sources:")
    righe += ["  - %s" % _q(s) for s in sources]
    righe.append("---")
    return "\n".join(righe) + "\n"


AZIONI = {
    "finestra": "passa all'app", "apri": "apre un file", "apri_allegato": "apre un allegato",
    "visita": "va su un sito", "copia": "copia", "taglia": "taglia", "incolla": "incolla",
    "compila": "compila un campo", "clic": "fa clic", "menu": "usa il menu", "tasti": "usa una scorciatoia",
    "scarica": "scarica un file", "crea": "crea un file", "modifica": "modifica un file",
    "sposta": "sposta o rinomina un file", "elimina": "elimina un file", "salva": "salva",
    "salva_come": "salva con nome", "invia": "invia", "esporta": "esporta", "stampa": "stampa",
    "nuovo": "crea un elemento nuovo", "nuova_scheda": "apre una scheda", "chiudi": "chiude",
    "protetto": "scrive in un campo protetto", "escluso": "usa un'app esclusa",
}


def passaggio(simbolo: str) -> str:
    """Un simbolo detto a parole, senza segnaposto né domini. Un blocco "(A + B)" è un gruppo
    di passaggi ripetuti di seguito."""
    if episodi.e_blocco(simbolo):
        return "più volte di seguito: " + "; ".join(passaggio(s) for s in episodi.simboli_di(simbolo))
    parti = simbolo.split(":")
    app = parti[0]
    if "[" in app:
        app = "un'app non in elenco"
    azione = parti[1] if len(parti) > 1 else ""
    tipo = parti[2] if len(parti) > 2 else ""
    frase = AZIONI.get(azione, azione.replace("_", " "))
    dettaglio = ""
    if azione in ("apri", "apri_allegato", "scarica", "crea", "modifica", "sposta", "elimina"):
        if re.fullmatch(r"[a-z0-9]{1,6}", tipo or ""):
            dettaglio = tipo
    elif azione in ("clic", "menu"):
        voce = " ".join(w for w in (tipo or "").split("-") if w and "[" not in w)
        if voce and not URL_RE.search(voce):
            dettaglio = voce
    elif azione in ("incolla", "compila") and tipo.endswith("campo"):
        dettaglio = "in un campo" if azione == "incolla" else ""
    testo = "%s: %s" % (app, frase)
    if dettaglio:
        testo += " " + dettaglio
    return testo


def _routine(an, rid: int):
    rec = an.execute("SELECT * FROM routine_stato WHERE id = ?", (rid,)).fetchone()
    r = an.execute("SELECT * FROM routine WHERE id = ?", (rid,)).fetchone()
    return rec, r


def _app_leggibili(r) -> list:
    try:
        app = json.loads(r["app"] or "[]")
    except ValueError:
        app = []
    return [a for a in app if "[" not in a]


def _elenco(voci: list) -> str:
    if not voci:
        return "nessuna"
    if len(voci) == 1:
        return voci[0]
    return ", ".join(voci[:-1]) + " e " + voci[-1]


def corpo_nota(rid: int, r, descrizione: str, oggi: str) -> str:
    righe = ["# Routine osservata da Lancillotto", "", descrizione.rstrip(".") + ".", "",
             "Nota scritta da Claude il %s, dopo il sì della persona. Il testo non viene dal registro: "
             "sono parole di Claude sugli aggregati." % oggi, ""]
    if r is not None:
        volte, giorni = int(r["volte"]), int(r["giorni"])
        minuti = int(round((r["tempo_totale_ms"] or 0) / 60000.0))
        medi = minuti / max(1, volte)
        righe += ["## Cosa ha visto Lancillotto", "",
                  "- Ripetizioni: %d volte in %d giorni diversi, dal %s al %s." % (volte, giorni, r["dal"], r["al"]),
                  "- Tempo totale osservato: circa %d minuti, in media %.0f minuti a volta." % (minuti, medi),
                  "- App coinvolte: %s." % _elenco(_app_leggibili(r)),
                  "- Varianti: %d." % int(r["n_varianti"])]
        if r["legami_tra_app"]:
            righe.append("- Passaggi di dati fra app (copia e incolla, file, download): %d." % int(r["legami_tra_app"]))
        try:
            ragg = [x for x in json.loads(r["raggiungibile"] or "[]") if "[" not in x]
        except ValueError:
            ragg = []
        if ragg:
            righe.append("- Cosa Claude raggiunge su questo computer per questa routine: %s." % _elenco(ragg))
        if r["avvio_a_freddo"]:
            righe.append("- Osservata soprattutto come ripetizione dentro lo stesso lavoro (avvio a freddo).")
        passi = [passaggio(s) for s in (r["schema"] or "").split(" > ") if s]
        if passi:
            righe += ["", "## Passaggi tipici", ""]
            righe += ["%d. %s." % (i, p) for i, p in enumerate(passi, 1)]
    righe += ["", "## Stato", "", "- Confermata il %s (routine %d di Lancillotto)." % (oggi, rid), ""]
    return "\n".join(righe)


def _controlla_nota(testo: str) -> None:
    probl = []
    if SEGNAPOSTO_RE.search(testo):
        probl.append("segnaposto nella nota")
    if re.search(r"(?i)https?://|www\.", testo):
        probl.append("URL nella nota")
    if segreti.trova(testo):
        probl.append("segreto nella nota")
    if INVISIBILI.search(testo):
        probl.append("caratteri invisibili nella nota")
    if probl:
        raise Rifiutato("; ".join(probl))


def _scrivi(p, testo: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    percorsi.scrivi_600(p, testo)


def conferma(rid: int, descrizione: str, triggers: list, domande: list, nome: str = None) -> dict:
    an = analisi.apri()
    try:
        rec, r = _routine(an, rid)
        if rec is None:
            raise Rifiutato("routine %s non trovata: guarda 'lancillotto routine --json'" % rid)
        triggers = [t.strip() for t in (triggers or []) if t and t.strip()]
        domande = [d.strip() for d in (domande or []) if d and d.strip()]
        campi = [("descrizione", descrizione)] + [("trigger", t) for t in triggers] + \
            [("domanda", d) for d in domande]
        if nome:
            campi.append(("slug", nome))
        valida(campi)
        if len({w for t in triggers for w in re.findall(r"\w+", t.lower()) if len(w) > 2}) < 2 or len(triggers) < 2:
            raise Rifiutato("servono almeno 2 --trigger, con almeno 2 parole di più di 2 lettere in tutto")
        if not domande:
            raise Rifiutato("serve almeno una --domanda a cui la nota risponde")
        answers = list(dict.fromkeys(domande + [d for d in DOMANDE_BASE]))[:max(3, len(domande))]
        oggi = dt.date.today().isoformat()
        an.execute("UPDATE routine_stato SET stato = 'confermata', aggiornata = ? WHERE id = ?", (oggi, rid))
        an.execute("UPDATE routine SET stato = 'confermata' WHERE id = ?", (rid,))
        mem = percorsi.memoria()
        if not mem.is_dir():
            an.commit()
            return {"routine": rid, "stato": "confermata", "nota": None, "messaggio": SUGGERIMENTO}
        base = "pattern-lancillotto-" + slug(nome or descrizione)
        cartella = mem / "pattern"
        p = cartella / (base + ".md")
        n = 2
        while p.exists() and str(p) != (rec["nota"] or ""):
            p = cartella / ("%s-%d.md" % (base, n))
            n += 1
        sorgente = "Lancillotto, routine %d" % rid
        if r is not None:
            sorgente += ", registro dal %s al %s" % (r["dal"], r["al"])
        testo = frontmatter(p.stem, "Routine osservata da Lancillotto: " + descrizione.rstrip("."),
                            "reference", "pattern-operativo", triggers, answers, [sorgente], oggi)
        testo += "\n" + corpo_nota(rid, r, descrizione, oggi)
        _controlla_nota(testo)
        _scrivi(p, testo)
        an.execute("UPDATE routine_stato SET nota = ? WHERE id = ?", (str(p), rid))
        an.commit()
        return {"routine": rid, "stato": "confermata", "nota": str(p)}
    finally:
        an.close()


def _tocca_updated(testo: str, oggi: str) -> str:
    return re.sub(r'(?m)^updated:\s*.*$', 'updated: "%s"' % oggi, testo, count=1)


def _descrivi_routine(r) -> str:
    if r is None:
        return "una routine"
    return "routine fra %s, %d volte in %d giorni" % (_elenco(_app_leggibili(r)), int(r["volte"]), int(r["giorni"]))


def rifiuta(rid: int, motivo: str) -> dict:
    valida([("motivo", motivo)])
    an = analisi.apri()
    try:
        rec, r = _routine(an, rid)
        if rec is None:
            raise Rifiutato("routine %s non trovata" % rid)
        oggi = dt.date.today().isoformat()
        # il ritmo al rifiuto: tempo di una volta, non il totale che cresce con i giorni (analisi.stato_effettivo)
        tempo = analisi.ms_per_volta(dict(r)) if r is not None else (rec["tempo_rif_ms"] or 0)
        an.execute("UPDATE routine_stato SET stato = 'rifiutata', motivo = ?, tempo_rif_ms = ?, aggiornata = ?"
                   " WHERE id = ?", (motivo.strip(), tempo, oggi, rid))
        an.execute("UPDATE routine SET stato = 'rifiutata' WHERE id = ?", (rid,))
        mem = percorsi.memoria()
        if not mem.is_dir():
            an.commit()
            return {"routine": rid, "stato": "rifiutata", "nota": None, "messaggio": SUGGERIMENTO}
        p = mem / "feedback" / (NOTA_RIFIUTI + ".md")
        try:
            testo = p.read_text(encoding="utf-8")
        except OSError:
            testo = frontmatter(
                NOTA_RIFIUTI, "Routine osservate da Lancillotto che la persona non vuole automatizzare, con il motivo",
                "feedback", "feedback",
                ["lancillotto", "non automatizzare", "routine rifiutate", "cosa non delegare"],
                ["Quali routine la persona non vuole automatizzare?",
                 "Perché la persona ha rifiutato una routine di Lancillotto?",
                 "Cosa non devo riproporre come automazione?"],
                ["Lancillotto, rifiuti scritti dopo il no della persona"], oggi)
            testo += ("\n# Cosa non automatizzare\n\nUna riga per rifiuto. Una routine rifiutata non torna, "
                      "salvo che il tempo di una sua ripetizione sia più che raddoppiato.\n\n## Rifiuti\n\n")
        riga = "- %s, routine %d (%s). Motivo: %s.\n" % (oggi, rid, _descrivi_routine(r), motivo.strip().rstrip("."))
        _controlla_nota(riga)
        if not testo.endswith("\n"):
            testo += "\n"
        testo = _tocca_updated(testo, oggi) + riga
        _scrivi(p, testo)
        an.commit()
        return {"routine": rid, "stato": "rifiutata", "nota": str(p)}
    finally:
        an.close()


def automatizzata(rid: int, con_cosa: str) -> dict:
    valida([("con cosa", con_cosa)])
    an = analisi.apri()
    try:
        rec, _r = _routine(an, rid)
        if rec is None:
            raise Rifiutato("routine %s non trovata" % rid)
        oggi = dt.date.today().isoformat()
        an.execute("UPDATE routine_stato SET stato = 'automatizzata', con_cosa = ?, aggiornata = ? WHERE id = ?",
                   (con_cosa.strip(), oggi, rid))
        an.execute("UPDATE routine SET stato = 'automatizzata' WHERE id = ?", (rid,))
        nota = rec["nota"]
        aggiornata = None
        if nota and os.path.isfile(nota):
            p = Path(nota)
            testo = p.read_text(encoding="utf-8")
            riga = "- Automatizzata il %s con: %s.\n" % (oggi, con_cosa.strip().rstrip("."))
            _controlla_nota(riga)
            if not testo.endswith("\n"):
                testo += "\n"
            _scrivi(p, _tocca_updated(testo, oggi) + riga)
            aggiornata = str(p)
        an.commit()
        out = {"routine": rid, "stato": "automatizzata", "nota": aggiornata}
        if not percorsi.memoria().is_dir():
            out["messaggio"] = SUGGERIMENTO
        return out
    finally:
        an.close()


# --- precedenti ---------------------------------------------------------------------------

def script_recall():
    cand = []
    v = os.environ.get("LANCILLOTTO_RECALL", "").strip()
    if v:
        cand.append(v)
    h = percorsi.home()
    cand += [str(h / ".claude" / "scripts" / "melchior_recall.py"), str(h / ".claude" / "bin" / "melchior_recall.py")]
    for c in cand:
        if os.path.isfile(c):
            return c
    return None


def _grep(mem, testo: str) -> list:
    parole = [w for w in re.findall(r"\w+", (testo or "").lower()) if len(w) > 2]
    out = []
    # Fino al 25/10/2026 il progetto si chiamava Ancillotto: le note di allora hanno quel nome.
    note = sorted(set(mem.rglob("*lancillotto*.md")) | set(mem.rglob("*ancillotto*.md"))) if mem.is_dir() else []
    for p in note:
        try:
            t = p.read_text(encoding="utf-8").lower()
        except OSError:
            continue
        punti = sum(t.count(w) for w in parole) if parole else 1
        if punti:
            m = re.search(r'(?m)^description:\s*"?(.*?)"?\s*$', p.read_text(encoding="utf-8"))
            out.append({"name": p.stem, "path": str(p), "score": punti,
                        "description": m.group(1) if m else ""})
    out.sort(key=lambda x: -x["score"])
    return out[:8]


def precedenti(testo: str = None) -> dict:
    an = analisi.apri()
    try:
        decise = []
        for r in an.execute("SELECT id, schema, stato, motivo, con_cosa, nota, aggiornata FROM routine_stato"
                            " WHERE stato IN ('confermata', 'rifiutata', 'automatizzata') ORDER BY id"):
            try:
                schema = json.loads(r["schema"] or "[]")
            except ValueError:
                schema = []
            voce = {"id": r["id"], "stato": r["stato"], "schema": " > ".join(schema), "quando": r["aggiornata"]}
            if r["motivo"]:
                voce["motivo"] = r["motivo"]
            if r["con_cosa"]:
                voce["con_cosa"] = r["con_cosa"]
            if r["nota"]:
                voce["nota"] = os.path.basename(r["nota"])
            decise.append(voce)
    finally:
        an.close()
    mem = percorsi.memoria()
    note, fonte = [], "nessuna"
    if not mem.is_dir():
        fonte = "memoria spenta"
    else:
        script = script_recall()
        if testo and script and len(re.findall(r"\w{3,}", testo)) >= 2:
            try:
                r = subprocess.run([sys.executable, script, testo, "--json", "-n", "8", "--memory-dir", str(mem)],
                                   capture_output=True, text=True, timeout=30)
                if r.returncode == 0 and r.stdout.strip().startswith("["):
                    note = [{"name": x.get("name"), "path": x.get("path"), "score": x.get("score"),
                             "description": x.get("description", "")} for x in json.loads(r.stdout)]
                    fonte = "melchior_recall"
            except (OSError, ValueError, subprocess.SubprocessError):
                note = []
        if fonte != "melchior_recall":
            note = _grep(mem, testo or "")
            fonte = "ricerca semplice sui file lancillotto"
    for n in note:
        n["description"] = pseudonimi.pulisci(str(n.get("description") or ""))[:200]
    return {"routine_decise": decise, "note": note, "fonte_note": fonte}
