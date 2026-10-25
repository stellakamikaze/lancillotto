"""lancillotto: la CLI di Lancillotto per la persona e per Claude Code.

Verbi per la persona:
  stato [--json]                    acceso, in pausa o fermo; permessi, peso, sensori
  pausa [MINUTI|domani]             ferma la registrazione (60 minuti se non dici niente)
  riprendi                          riprende subito
  escludi app|sito NOME             esclude un'app o un sito, anche all'indietro
  dimentica MINUTI                  cancella gli ultimi MINUTI
  cancella-tutto [--si]             cancella tutto il registro (chiede di scrivere SI)
  mostra [--apri] [--giorno DATA]   pagina locale con ciò che Claude può vedere
  rivedi [ID "intento"]             i lavori più lunghi di oggi, o cosa stavi facendo in uno
Livello 0, aggregati:
  oggi | giorno DATA | settimana | routine [--top N] [--stato S] | raggiungo
Livello 1, metadati pseudonimizzati:
  episodi [--giorno DATA] | episodio ID | catene [--tipo T] [--giorno DATA] | cerca "parole"
  conta "pattern" [--dal DATA] | conta --routine ID [--dal DATA] | verifica --sql "SELECT ... FROM v_..."
Livello 2, testo redatto, solo con il clic della persona nel menu:
  testo --da HH:MM --a HH:MM [--giorno DATA] [--richiedi]
Melchior:
  conferma ID --descrizione "..." --trigger "..." --trigger "..." --domanda "..." [--slug S]
  rifiuta ID "motivo" | automatizzata ID "con cosa" | precedenti ["testo"]
  valuta ID --compito "titolo" --come "cosa farebbe Claude" | valuta ID --non-compito "perché"
Analisi:
  analizza [--da-zero]

Ogni verbo di dati risponde in JSON (anche senza --json) e prima aggiorna l'analisi.
Solo `telemetria invia` usa la rete: manda a chi mantiene Lancillotto eventi da un elenco chiuso (telemetria.py).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import plistlib
import re
import subprocess
import sys
import time

from . import analisi, impostazioni, melchior, mostra, percorsi, raggiungo, registro, segreti, uscita, verifica
from .pseudonimi import Pseudonimi

BATTITO_MS = 120000
# Quanto la CLI aspetta che il registratore acceso confermi le esclusioni nuove (meta.esclusioni_applicate)
ATTESA_ESCLUSIONI_S = 6.0
APRI_APP = "open ~/Applications/Lancillotto.app"
VERBI_PERSONA = {"stato", "pausa", "riprendi", "escludi", "dimentica", "cancella-tutto", "mostra", "rivedi"}
# Sensori facoltativi: spenti per scelta della persona non sono un guasto
FACOLTATIVI = {"ocr": "lettura dello schermo (OCR)", "testo": "testo delle finestre", "avvio_login": "avvio al login"}


def stampa(obj) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")


def errore(msg: str, codice: int = 2, persona: bool = False) -> int:
    """Un errore: per i verbi della persona senza --json una frase, per gli altri JSON."""
    if persona:
        print("Errore: %s" % msg)
    else:
        stampa({"errore": msg})
    return codice


_TRADUZIONI = (
    (re.compile(r"^the following arguments are required: (.*)$"), "mancano questi argomenti: %s"),
    (re.compile(r"^argument (\S+): invalid int value: (.*)$"), "l'argomento %s vuole un numero intero, non %s"),
    (re.compile(r"^argument (\S+): invalid choice: (\S+) \(choose from (.*)\)$"), "l'argomento %s non ammette %s: scegli fra %s"),
    (re.compile(r"^argument (\S+): expected one argument$"), "l'argomento %s vuole un valore"),
    (re.compile(r"^unrecognized arguments: (.*)$"), "argomenti non riconosciuti: %s"),
    (re.compile(r"^argument (\S+): (.*)$"), "argomento %s: %s"),
)


def traduci(messaggio: str) -> str:
    for rx, modello in _TRADUZIONI:
        m = rx.match(messaggio)
        if m:
            return modello % m.groups()
    return messaggio


class ParserItaliano(argparse.ArgumentParser):
    """argparse con gli errori in italiano: la persona legge "mancano questi argomenti", non
    "the following arguments are required"."""

    def format_usage(self):
        return super().format_usage().replace("usage:", "uso:", 1)

    def format_help(self):
        return super().format_help().replace("usage:", "uso:", 1).replace("positional arguments:", "argomenti:") \
            .replace("options:", "opzioni:").replace("optional arguments:", "opzioni:") \
            .replace("show this help message and exit", "mostra questo aiuto ed esce")

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, "%s: errore: %s\n" % (self.prog, traduci(message)))


def _data(s) -> str:
    if not s:
        return uscita.oggi_str()
    try:
        return dt.datetime.strptime(s, "%Y-%m-%d").strftime("%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError("data non valida: usa AAAA-MM-GG")


# --- Persona ------------------------------------------------------------------------------

def _stato_dati() -> dict:
    reg = registro.apri()
    imp = impostazioni.leggi()
    ora = percorsi.ora_ms()
    if reg is None:
        return {"stato": "fermo", "causa": registro.CAUSA_MAI_AVVIATO}
    try:
        m = registro.meta(reg)
        try:
            battito = int(m.get("ultimo_battito") or 0)
        except ValueError:
            battito = 0
        pausa_fino = int(imp.get("pausa_fino") or 0)
        if not battito or ora - battito > BATTITO_MS:
            stato = {"stato": "fermo", "dalle": uscita.quando(battito) if battito else None}
        elif pausa_fino > ora:
            stato = {"stato": "in pausa", "fino": uscita.quando(pausa_fino)}
        else:
            stato = {"stato": "acceso"}
        oggi = uscita.oggi_str()
        g = reg.execute("SELECT eventi, byte FROM giorno WHERE data = ?", (oggi,)).fetchone()
        # giorno.byte è il peso di tutto il registro (docs/CONTRATTO.md): con la conservazione a
        # regime la crescita da ieri è vicina a zero. Il peso di oggi si stima dai dati di oggi.
        inizio = dt.datetime.strptime(oggi, "%Y-%m-%d")
        byte_oggi = registro.peso_giorno(reg, int(inizio.timestamp() * 1000),
                                         int((inizio + dt.timedelta(days=1)).timestamp() * 1000))
        peso_file = 0
        for suff in ("", "-wal", "-shm"):
            p = percorsi.registro().with_name(percorsi.registro().name + suff)
            try:
                peso_file += p.stat().st_size
            except OSError:
                pass
        giorni = reg.execute("SELECT COUNT(DISTINCT date(ts / 1000, 'unixepoch', 'localtime')) FROM evento").fetchone()[0]
        sensori = {}
        for r in reg.execute("SELECT sensore, stato, dettaglio, ts FROM salute ORDER BY ts"):
            sensori[r["sensore"]] = {"stato": r["stato"], "dal": uscita.quando(r["ts"])}
        # un sensore facoltativo spento per scelta (OCR senza Registrazione schermo, avvio al login
        # saltato) non è un guasto: si dice a parte
        facoltativi = {}
        for k in list(sensori):
            v = sensori[k]
            if k in FACOLTATIVI and (v["stato"] == "spento" or (
                    k == "ocr" and v["stato"] == "degradato" and m.get("permesso_schermo") != "1")):
                facoltativi[k] = dict(v, cosa=FACOLTATIVI[k])
                del sensori[k]
        try:
            persi = int(m.get("persi") or 0)
        except ValueError:
            persi = 0
        stato.update({
            "permessi": {"accessibilita": m.get("permesso_ax") == "1", "schermo": m.get("permesso_schermo") == "1"},
            "oggi": {"eventi": int(g["eventi"]) if g else 0, "mb": round(byte_oggi / 1048576.0, 2)},
            "registro_mb": round(peso_file / 1048576.0, 2),
            "giorni_tenuti": int(giorni), "conservazione_giorni": imp.get("conservazione_giorni"),
            "sensori": sensori, "facoltativi_spenti": facoltativi, "persi": persi,
            "versione_binario": m.get("versione_binario"),
        })
        if stato["stato"] == "fermo":
            stato["rimedio"] = "apri l'app: " + APRI_APP
        return stato
    finally:
        reg.close()


def _stato_parole(s: dict) -> str:
    if s.get("causa"):
        return "Lancillotto è fermo: %s. Per installarlo lancia ./installa.sh nella sua cartella." % s["causa"]
    righe = []
    if s["stato"] == "acceso":
        righe.append("Lancillotto è acceso e registra.")
    elif s["stato"] == "in pausa":
        righe.append("Lancillotto è in pausa fino a %s." % s["fino"])
    else:
        righe.append("Lancillotto è fermo%s. Per farlo ripartire apri l'app: %s" % (
            " dalle %s" % s["dalle"] if s.get("dalle") else "", APRI_APP))
    p = s["permessi"]
    righe.append("Permessi: Accessibilità %s, Registrazione schermo %s." % (
        "sì" if p["accessibilita"] else "no", "sì" if p["schermo"] else "no"))
    righe.append("Oggi: %d eventi, %.1f MB. Registro: %.1f MB, %d giorni tenuti (conservazione %s giorni)." % (
        s["oggi"]["eventi"], s["oggi"]["mb"], s["registro_mb"], s["giorni_tenuti"], s["conservazione_giorni"]))
    guasti = ["%s %s" % (k, v["stato"]) for k, v in sorted(s["sensori"].items()) if v["stato"] != "ok"]
    righe.append("Sensori: %s." % (", ".join(guasti) if guasti else "tutti a posto"))
    spenti = [v["cosa"] for _k, v in sorted((s.get("facoltativi_spenti") or {}).items())]
    if spenti:
        righe.append("Spenti per scelta (facoltativi, non è un guasto): %s." % ", ".join(spenti))
    if s["persi"]:
        righe.append("Eventi persi per coda piena: %d." % s["persi"])
    return "\n".join(righe)


def cmd_stato(a) -> int:
    s = _stato_dati()
    if a.json:
        stampa(s)
    else:
        print(_stato_parole(s))
    return 0


def cmd_pausa(a) -> int:
    fino = impostazioni.pausa_fino_ms(a.quanto or "", percorsi.ora_ms())
    impostazioni.aggiorna(pausa_fino=fino)
    out = {"stato": "in pausa", "fino": uscita.quando(fino)}
    stampa(out) if a.json else print("In pausa fino a %s. Per riprendere: lancillotto riprendi." % out["fino"])
    return 0


def cmd_riprendi(a) -> int:
    impostazioni.aggiorna(pausa_fino=0)
    reg = registro.apri()
    try:
        vivo = reg is not None and _vivo(reg)
    finally:
        if reg is not None:
            reg.close()
    if vivo:
        stampa({"stato": "registra"}) if a.json else print("Ripreso: Lancillotto registra di nuovo.")
        return 0
    out = {"stato": "fermo", "pausa": "tolta", "rimedio": "apri l'app: " + APRI_APP}
    stampa(out) if a.json else print("Pausa tolta, ma Lancillotto è fermo e non registra. "
                                     "Per farlo ripartire apri l'app: %s" % APRI_APP)
    return 0


def _vivo(reg) -> bool:
    try:
        b = int(registro.meta(reg).get("ultimo_battito") or 0)
    except ValueError:
        return False
    return b > 0 and percorsi.ora_ms() - b <= BATTITO_MS


def _dopo_cancellazione() -> None:
    if percorsi.registro().exists():
        analisi.analizza(da_zero=True)


def _app_installate(nome: str) -> list:
    """Le app installate (Info.plist in ~/Applications, /Applications...) il cui nome corrisponde:
    [(bundle, nome)]. Serve quando l'app non è ancora nel registro."""
    out = []
    for cartella in percorsi.cartelle_app():
        try:
            voci = sorted(cartella.iterdir())
        except OSError:
            continue
        for v in voci:
            if v.suffix != ".app":
                continue
            try:
                with open(str(v / "Contents" / "Info.plist"), "rb") as f:
                    info = plistlib.load(f)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
            bundle = str(info.get("CFBundleIdentifier") or "")
            if not bundle:
                continue
            nomi = {str(info.get(k) or "") for k in ("CFBundleDisplayName", "CFBundleName")} | {v.stem}
            if bundle.lower() == nome.lower() or any(registro.nome_corrisponde(n, nome) for n in nomi if n):
                out.append((bundle, v.stem))
    return out


def _sembra_bundle(nome: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}", nome))


def _aspetta_esclusioni(dal_ms: int) -> bool:
    """Aspetta che il registratore acceso scriva meta.esclusioni_applicate dopo dal_ms: allora
    ha riletto le regole e messo su disco gli eventi che teneva in RAM. True se è successo."""
    fine = time.time() + ATTESA_ESCLUSIONI_S
    while True:
        reg = registro.apri()
        try:
            v = registro.meta(reg).get("esclusioni_applicate") if reg is not None else None
        finally:
            if reg is not None:
                reg.close()
        try:
            if v is not None and int(v) >= dal_ms:
                return True
        except ValueError:
            pass
        if time.time() >= fine:
            return False
        time.sleep(0.2)


def cmd_escludi(a) -> int:
    persona = not a.json
    nome = a.nome.strip()
    if a.cosa == "sito":
        nome = re.sub(r"^[a-z]+://", "", nome.lower()).split("/")[0].split("?")[0].split("#")[0]
        if nome.startswith("www."):
            nome = nome[4:]
        if "." not in nome.strip(".") or not re.fullmatch(r"[a-z0-9.-]+", nome):
            return errore("\"%s\" non è un sito: scrivi il dominio, per esempio lancillotto escludi sito fineco.it"
                          % a.nome.strip(), persona=persona)
        voci = [nome]
    else:
        reg = registro.apri()
        try:
            voci = [x["bundle"] for x in registro.app_corrispondenti(reg, nome)] if reg is not None else []
        finally:
            if reg is not None:
                reg.close()
        if not voci:
            voci = sorted({b for b, _n in _app_installate(nome)})
        if not voci and _sembra_bundle(nome):
            voci = [nome]
        if not voci:
            return errore("non trovo un'app che si chiama \"%s\". Scrivi il nome come appare nel menu in alto "
                          "quando l'app è aperta, oppure il suo bundle id (per esempio com.google.Chrome). "
                          "Non ho escluso niente." % nome, persona=persona)
    # Prima la regola: il registratore la rilegge e non scrive più niente di quell'app o sito.
    scritta = percorsi.ora_ms()
    for v in voci:
        impostazioni.aggiungi_a_lista("escludi_domini" if a.cosa == "sito" else "escludi_app", v)
    reg = registro.apri(scrittura=True)
    esito = {"eventi": 0}
    registratore = "fermo"
    if reg is not None:
        try:
            if _vivo(reg):
                # Il registratore ha eventi in RAM (fino a 10 s): si cancella dopo che li ha scritti.
                registratore = "confermato" if _aspetta_esclusioni(scritta) else "non ha risposto"
            if a.cosa == "sito":
                esito = registro.escludi_dominio(reg, nome)
            else:
                for v in voci:
                    esito["eventi"] += registro.escludi_app(reg, v)["eventi"]
        finally:
            reg.close()
    _dopo_cancellazione()
    out = {"escluso": a.cosa, "nome": nome, "eventi_cancellati": esito.get("eventi", 0), "registratore": registratore}
    if a.cosa == "app":
        out["app"] = voci
    if a.json:
        stampa(out)
    else:
        print("Escluso %s %s%s. Cancellati %d eventi già registrati." % (
            "il sito" if a.cosa == "sito" else "l'app", nome,
            "" if a.cosa == "sito" or voci == [nome] else " (" + ", ".join(voci) + ")", out["eventi_cancellati"]))
        if registratore == "non ha risposto":
            print("Il registratore non ha confermato in tempo: rilancia lo stesso comando fra un minuto.")
    return 0


def cmd_dimentica(a) -> int:
    if a.minuti <= 0:
        return errore("i minuti devono essere più di zero")
    ora = percorsi.ora_ms()
    da = ora - a.minuti * 60000
    reg = registro.apri(scrittura=True)
    esito = {"eventi": 0, "righe": 0}
    if reg is not None:
        try:
            if _vivo(reg):
                # il registratore può avere eventi in RAM: cancella anche lui, poi toglie la richiesta
                impostazioni.aggiungi_a_lista("dimentica_richieste", {"da": da, "a": ora})
            esito = registro.dimentica(reg, da, ora)
        finally:
            reg.close()
    _dopo_cancellazione()
    out = {"dimenticati_minuti": a.minuti, "dalle": uscita.ora(da), "alle": uscita.ora(ora),
           "eventi_cancellati": esito["eventi"]}
    stampa(out) if a.json else print("Dimenticato dalle %s alle %s: %d eventi cancellati." % (
        out["dalle"], out["alle"], out["eventi_cancellati"]))
    return 0


def cmd_cancella_tutto(a) -> int:
    if not a.si:
        sys.stdout.write("Scrivi SI (maiuscolo) per cancellare tutto il registro di Lancillotto: ")
        sys.stdout.flush()
        risposta = sys.stdin.readline().strip()
        if risposta != "SI":
            if risposta.upper() == "SI":
                print("Niente cancellato: serve SI scritto in maiuscolo.")
            else:
                print("Niente cancellato: per cancellare tutto scrivi SI (maiuscolo).")
            return 1
    reg = registro.apri(scrittura=True)
    n = 0
    if reg is not None:
        try:
            if _vivo(reg):
                # il registratore ha eventi in RAM e id in memoria: cancella anche lui tutto
                # quello che ha fino ad ora, poi svuota la sua memoria degli id
                impostazioni.aggiungi_a_lista("dimentica_richieste", {"da": 0, "a": percorsi.ora_ms()})
            n = registro.cancella_tutto(reg)["eventi"]
        finally:
            reg.close()
    for p in (percorsi.analisi(), percorsi.pagina_mostra()):
        for suff in ("", "-journal", "-wal", "-shm"):
            q = p.with_name(p.name + suff)
            if q.exists():
                q.unlink()
    out = {"cancellato": True, "eventi": n}
    stampa(out) if a.json else print("Cancellato tutto: %d eventi, analisi e pagina mostra." % n)
    return 0


# --- Dati ---------------------------------------------------------------------------------

def _con_dati(funzione):
    """Aggiorna l'analisi, apre registro e analisi, chiama funzione(reg, an, ps)."""
    r = analisi.analizza()
    if r.get("dati", 1) is None:
        stampa(uscita.senza_dati(r["causa"]))
        return 0
    reg = registro.apri()
    an = analisi.apri()
    try:
        ps = Pseudonimi(an)
        out = funzione(reg, an, ps)
        an.commit()
    finally:
        an.close()
        reg.close()
    if out is not None:
        stampa(out)
    return 0


def cmd_oggi(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.giorno(reg, an, ps, uscita.oggi_str()))


def cmd_giorno(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.giorno(reg, an, ps, a.data))


def cmd_settimana(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.settimana(reg, an, ps))


def cmd_routine(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.routine(an, a.top, a.stato))


def cmd_raggiungo(a) -> int:
    stampa(uscita.involucro("L0", raggiungo.raggiungo()))
    return 0


def cmd_episodi(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.episodi(an, a.giorno))


def cmd_episodio(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.episodio(an, a.id))


def cmd_catene(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.catene(an, a.giorno, a.tipo))


def cmd_cerca(a) -> int:
    return _con_dati(lambda reg, an, ps: uscita.cerca(an, a.parole))


def cmd_conta(a) -> int:
    if a.routine is not None:
        return _con_dati(lambda reg, an, ps: uscita.involucro("L1", verifica.conta_routine(an, a.routine, a.dal)))
    if not a.pattern:
        return errore("serve un pattern di simboli oppure --routine ID")
    return _con_dati(lambda reg, an, ps: uscita.involucro("L1", verifica.conta(an, a.pattern, a.dal)))


def cmd_verifica(a) -> int:
    def f(reg, an, ps):
        return uscita.involucro("L1", verifica.esegui_sql(a.sql))
    return _con_dati(f)


def cmd_rivedi(a) -> int:
    if a.id is not None and a.intento:
        def salva(reg, an, ps):
            r = an.execute("SELECT t0 FROM episodio WHERE id = ?", (a.id,)).fetchone()
            if r is None:
                return {"errore": "episodio %d non trovato" % a.id}
            testo, _tipi = segreti.redigi(a.intento.strip()[:500])
            an.execute("INSERT OR REPLACE INTO intento(t0, testo, ts) VALUES (?, ?, ?)",
                       (r["t0"], testo, percorsi.ora_ms()))
            an.execute("UPDATE episodio_fts SET intento = ? WHERE rowid = ?", (testo, a.id))
            return {"episodio": a.id, "intento": "salvato"}
        return _con_dati(salva)

    def elenco(reg, an, ps):
        eps = an.execute("SELECT * FROM episodio WHERE giorno = ? ORDER BY attivo_ms DESC LIMIT 3",
                         (uscita.oggi_str(),)).fetchall()
        voci = [dict(uscita.episodio_breve(an, r, voci=8), fine=uscita.ora(r["t1"]), app=json.loads(r["app"] or "[]"))
                for r in eps]
        return uscita.involucro("L1", {"episodi": voci, "come": "lancillotto rivedi ID \"cosa stavi facendo\""})
    return _con_dati(elenco)


def _hhmm(s: str, giorno: str) -> int:
    m = re.fullmatch(r"(\d{1,2})[:.](\d{2})", (s or "").strip())
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        raise argparse.ArgumentTypeError("orario non valido: usa HH:MM")
    d = dt.datetime.strptime(giorno, "%Y-%m-%d").replace(hour=int(m.group(1)), minute=int(m.group(2)))
    return int(d.timestamp() * 1000)


def cmd_testo(a) -> int:
    t0, t1 = _hhmm(a.da, a.giorno), _hhmm(a.a, a.giorno)
    if t1 <= t0:
        return errore("l'orario di fine deve venire dopo quello di inizio")
    if t1 - t0 > 4 * 3600000:
        return errore("al massimo 4 ore di testo per volta")
    r = analisi.analizza()
    if r.get("dati", 1) is None:
        stampa(uscita.senza_dati(r["causa"]))
        return 0
    ora = percorsi.ora_ms()
    reg = registro.apri(scrittura=True)
    an = analisi.apri()
    try:
        ps = Pseudonimi(an)
        v = registro.valuta_consenso(registro.consensi(reg), t0, t1, ora)
        if v["esito"] != "valido" and not _vivo(reg):
            # Il menu che mostra la richiesta è del registratore: se è fermo nessuno la vede.
            out = uscita.involucro("L2", {"consenso": "impossibile", "causa": "registratore fermo",
                                          "dalle": uscita.ora(t0), "alle": uscita.ora(t1),
                                          "messaggio": "Lancillotto è fermo e la richiesta non arriverebbe al"
                                                       " menu: la persona deve prima aprire l'app (" + APRI_APP + ")"})
        elif v["esito"] == "valido":
            out = uscita.testo_l2(reg, an, t0, t1)
            out["scade"] = uscita.ora(v["scade_ts"])
        elif v["esito"] == "in_attesa":
            out = uscita.involucro("L2", {"consenso": "richiesto", "id": v["id"], "in_attesa": True,
                                          "dalle": uscita.ora(t0), "alle": uscita.ora(t1),
                                          "messaggio": "la richiesta aspetta il clic della persona su Mostra"
                                                       " nel menu di Lancillotto"})
        elif v["esito"] == "negato" and not a.richiedi:
            out = uscita.involucro("L2", {"consenso": "negato", "motivo": v["motivo"],
                                          "dalle": uscita.ora(t0), "alle": uscita.ora(t1),
                                          "messaggio": "per chiedere di nuovo, rilancia con --richiedi"})
        else:
            ident = registro.inserisci_consenso(reg, t0, t1, uscita.descrizione_consenso(reg, ps, t0, t1), ora)
            out = uscita.involucro("L2", {"consenso": "richiesto", "id": ident, "dalle": uscita.ora(t0),
                                          "alle": uscita.ora(t1),
                                          "messaggio": "chiedi alla persona di fare clic su Mostra nel menu"
                                                       " di Lancillotto, poi rilancia lo stesso comando"})
        an.commit()
    finally:
        an.close()
        reg.close()
    stampa(out)
    return 0


# --- Melchior -------------------------------------------------------------------------------

def _melchior(f, *arg, **kw) -> int:
    r = analisi.analizza()
    if r.get("dati", 1) is None:
        stampa(uscita.senza_dati(r["causa"]))
        return 0
    stampa(f(*arg, **kw))
    return 0


def cmd_conferma(a) -> int:
    return _melchior(melchior.conferma, a.id, a.descrizione, a.trigger, a.domanda, a.slug)


def cmd_rifiuta(a) -> int:
    return _melchior(melchior.rifiuta, a.id, a.motivo)


def cmd_automatizzata(a) -> int:
    return _melchior(melchior.automatizzata, a.id, a.con_cosa)


def cmd_valuta(a) -> int:
    return _melchior(melchior.valuta, a.id, a.compito, a.come, a.non_compito)


def cmd_precedenti(a) -> int:
    if percorsi.registro().exists():
        analisi.analizza()
    stampa(melchior.precedenti(a.testo))
    return 0


def cmd_analizza(a) -> int:
    stampa(analisi.analizza(da_zero=a.da_zero))
    return 0


def cmd_mostra(a) -> int:
    r = analisi.analizza()
    if r.get("dati", 1) is None:
        stampa(uscita.senza_dati(r["causa"]))
        return 0
    reg = registro.apri()
    an = analisi.apri()
    try:
        pagina = mostra.genera(reg, an, Pseudonimi(an), a.giorno)
        an.commit()
    finally:
        an.close()
        reg.close()
    p = percorsi.pagina_mostra()
    percorsi.scrivi_600(p, pagina)
    print(str(p))
    if a.apri:
        subprocess.run(["open", str(p)], check=False)
    return 0


# --- Parser -------------------------------------------------------------------------------

def cmd_aggiorna(a) -> int:
    from . import aggiorna
    out = aggiorna.aggiorna(se_serve=a.se_serve)
    if a.json:
        stampa(out)
    else:
        print({"nessuno": "Lancillotto è già all'ultima versione.", "rimandato": "Controllato da poco: riprovo più tardi.",
               "applicato": "Aggiornato: %s." % out["dettaglio"], "binario": "Aggiornato: %s." % out["dettaglio"]}
              .get(out["esito"], "Non aggiornato: %s." % out["dettaglio"]))
    return 0 if out["esito"] not in ("fallito",) else 1


def cmd_telemetria(a) -> int:
    from . import telemetria
    if a.azione == "invia":
        out = telemetria.invia(forza=a.forza)
    elif a.azione == "spegni":
        telemetria.spegni()
        out = {"telemetria": "spenta", "coda": "cancellata"}
    elif a.azione == "accendi":
        telemetria.accendi()
        out = {"telemetria": "accesa"}
    elif a.azione == "registra":
        out = {"registrato": telemetria.registra(a.evento, a.valore or "")}
    else:
        out = telemetria.mostra()
    if a.json or a.azione in ("invia", "registra"):
        stampa(out)
    elif a.azione == "mostra":
        print("Telemetria %s%s. Id: %s. Server: %s." % (
            "accesa" if out["accesa"] else "spenta", "" if out["accesa"] else " (%s)" % out["perche_spenta"],
            out["installazione"] or "non ancora creato", out["server"]))
        print("In coda, cioè cosa partirà al prossimo invio (%d righe):" % len(out["in_coda"]))
        for r in out["in_coda"]:
            print("  %s  %s %s" % (r.get("giorno"), r.get("evento"), r.get("valore")))
    else:
        print("Telemetria %s." % out["telemetria"])
    return 0


def parser() -> argparse.ArgumentParser:
    ap = ParserItaliano(prog="lancillotto", description="Lancillotto: cosa fai al computer, "
                                 "letto in locale, per trovare cosa delegare a Claude Code.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    sub = ap.add_subparsers(dest="verbo", metavar="VERBO")
    sub.required = True

    def verbo(nome, funzione, aiuto):
        p = sub.add_parser(nome, help=aiuto, description=aiuto)
        p.add_argument("--json", action="store_true", help="risposta in JSON")
        p.set_defaults(funzione=funzione)
        return p

    verbo("stato", cmd_stato, "acceso, in pausa o fermo, permessi, peso, sensori")
    p = verbo("pausa", cmd_pausa, "ferma la registrazione per MINUTI (60) o fino a domani")
    p.add_argument("quanto", nargs="?", default="", help="minuti oppure 'domani'")
    verbo("riprendi", cmd_riprendi, "riprende la registrazione")
    p = verbo("escludi", cmd_escludi, "esclude un'app o un sito, anche all'indietro")
    p.add_argument("cosa", choices=("app", "sito"))
    p.add_argument("nome")
    p = verbo("dimentica", cmd_dimentica, "cancella gli ultimi MINUTI")
    p.add_argument("minuti", type=int)
    p = verbo("cancella-tutto", cmd_cancella_tutto, "cancella tutto il registro")
    p.add_argument("--si", action="store_true", help="non chiedere conferma")
    p = verbo("aggiorna", cmd_aggiorna, "porta Lancillotto all'ultima versione del suo repository")
    p.add_argument("--se-serve", action="store_true", help="solo se l'ultimo controllo è di più di 20 ore fa")
    p = verbo("telemetria", cmd_telemetria, "cosa esce verso chi mantiene Lancillotto: mostra, spegni, accendi, invia")
    p.add_argument("azione", nargs="?", default="mostra", choices=["mostra", "spegni", "accendi", "invia", "registra"])
    p.add_argument("evento", nargs="?", help="solo con registra: un evento dell'elenco chiuso")
    p.add_argument("valore", nargs="?", help="solo con registra: il suo valore")
    p.add_argument("--forza", action="store_true", help="invia anche se è passata meno di un'ora")
    p = verbo("mostra", cmd_mostra, "pagina locale con ciò che Claude può vedere")
    p.add_argument("--apri", action="store_true", help="aprila nel browser")
    p.add_argument("--giorno", type=_data, default=uscita.oggi_str())
    p = verbo("rivedi", cmd_rivedi, "i lavori più lunghi di oggi, o cosa stavi facendo in uno")
    p.add_argument("id", nargs="?", type=int)
    p.add_argument("intento", nargs="?")
    verbo("oggi", cmd_oggi, "aggregati di oggi (L0)")
    p = verbo("giorno", cmd_giorno, "aggregati di un giorno (L0)")
    p.add_argument("data", type=_data)
    verbo("settimana", cmd_settimana, "aggregati degli ultimi 7 giorni (L0)")
    p = verbo("routine", cmd_routine, "routine candidate (L0)")
    p.add_argument("--top", type=int, default=5)
    p.add_argument("--stato", choices=analisi.STATI)
    verbo("raggiungo", cmd_raggiungo, "cosa Claude raggiunge su questo Mac")
    p = verbo("episodi", cmd_episodi, "episodi di un giorno (L1)")
    p.add_argument("--giorno", type=_data, default=uscita.oggi_str())
    p = verbo("episodio", cmd_episodio, "un episodio con i suoi legami (L1)")
    p.add_argument("id", type=int)
    p = verbo("catene", cmd_catene, "legami fra eventi di un giorno (L1)")
    p.add_argument("--tipo", choices=("appunti", "download", "file", "stesso_oggetto", "riuso"))
    p.add_argument("--giorno", type=_data, default=uscita.oggi_str())
    p = verbo("cerca", cmd_cerca, "dove compaiono delle parole, senza il testo (L1)")
    p.add_argument("parole")
    p = verbo("conta", cmd_conta, "quante volte compare un pattern di simboli, o tutte le forme di una routine (L1)")
    p.add_argument("pattern", nargs="?", default=None)
    p.add_argument("--routine", type=int, default=None, help="conta tutte le forme della routine ID")
    p.add_argument("--dal", type=_data, default=None)
    p = verbo("verifica", cmd_verifica, "SELECT sulle viste v_* (L1, massimo 200 righe)")
    p.add_argument("--sql", required=True)
    p = verbo("testo", cmd_testo, "testo redatto di un intervallo (L2, con consenso)")
    p.add_argument("--da", required=True)
    p.add_argument("--a", required=True)
    p.add_argument("--giorno", type=_data, default=uscita.oggi_str())
    p.add_argument("--richiedi", action="store_true", help="nuova richiesta dopo un rifiuto o una scadenza")
    p = verbo("conferma", cmd_conferma, "la persona ha detto sì: nota Melchior")
    p.add_argument("id", type=int)
    p.add_argument("--descrizione", required=True)
    p.add_argument("--trigger", action="append", default=[])
    p.add_argument("--domanda", action="append", default=[])
    p.add_argument("--slug", default=None)
    p = verbo("rifiuta", cmd_rifiuta, "la persona ha detto no: la routine non torna")
    p.add_argument("id", type=int)
    p.add_argument("motivo")
    p = verbo("automatizzata", cmd_automatizzata, "la routine è già automatizzata")
    p.add_argument("id", type=int)
    p.add_argument("con_cosa")
    p = verbo("valuta", cmd_valuta, "il giudizio di Claude su una routine: compito o no")
    p.add_argument("id", type=int)
    p.add_argument("--compito", default=None, help="titolo del compito, con le parole della persona")
    p.add_argument("--come", default=None, help="cosa farebbe Claude e con quale strumento")
    p.add_argument("--non-compito", dest="non_compito", default=None, help="perché non è un compito da delegare")
    p = verbo("precedenti", cmd_precedenti, "routine già decise e note vicine")
    p.add_argument("testo", nargs="?", default=None)
    p = verbo("analizza", cmd_analizza, "aggiorna l'analisi")
    p.add_argument("--da-zero", action="store_true")
    return ap


def _segna_uso(a) -> None:
    """Quale verbo è stato usato, in coda per la telemetria (senza rete, mai gli argomenti)."""
    if a.verbo == "telemetria" or os.environ.get("LANCILLOTTO_DALLA_APP"):
        return
    try:
        from . import telemetria
        telemetria.registra("comando", a.verbo)
        if a.verbo in ("conferma", "rifiuta", "automatizzata"):
            telemetria.registra("routine", {"conferma": "confermata", "rifiuta": "rifiutata"}.get(a.verbo, a.verbo))
    except Exception:
        pass


def main(argv=None) -> int:
    for flusso in (sys.stdout, sys.stderr):
        try:
            flusso.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    a = parser().parse_args(argv)
    persona = a.verbo in VERBI_PERSONA and not getattr(a, "json", False)
    _segna_uso(a)
    try:
        return a.funzione(a)
    except registro.SchemaTroppoNuovo as e:
        return errore(str(e), persona=persona)
    except registro.RegistroVuoto as e:
        stampa(uscita.senza_dati(str(e)))
        return 0
    except melchior.Rifiutato as e:
        return errore(str(e))
    except verifica.SqlRifiutato as e:
        return errore(str(e))
    except (ValueError, argparse.ArgumentTypeError) as e:
        return errore(str(e), persona=persona)


if __name__ == "__main__":
    sys.exit(main())
