"""Routine dalle sequenze di simboli (docs/PROGETTAZIONE.md, sezione 5, punto 4).

  sequenze compresse per sessione (episodi consecutivi senza buchi oltre 5 minuti)
        │
        v
  DFG: un arco A->B vale solo con lift >= 3 (P(B|A) almeno 3 volte P(B)): il cmd+tab sparisce
        │
        v
  n-gram di 3-8 simboli fatti solo di archi forti; occorrenze senza sovrapposizione
        │  barriera: un'app esclusa o un campo protetto non sta dentro un n-gram (non si sa cosa c'era)
        │  supporto: occorrenze, episodi e giorni distinti; soglia 3 occorrenze
        v
  lavoro: un pattern di sola navigazione (finestre, siti, clic, schede) cade; serve almeno un
        │ gesto che produce o sposta qualcosa (compila, copia, incolla, salva, apri, scarica, menu...)
        v
  pattern chiusi: cade un pattern se uno più lungo ha lo stesso numero di occorrenze
        │
        v
  scelta golosa: il pattern migliore prende le varianti a distanza di edit <= 2;
  un pattern con metà delle occorrenze già dentro una routine scelta cade (frammenti, rotazioni)
        │
        v
  estensione: le occorrenze si allungano a destra e a sinistra finché l'80% continua con lo
  stesso simbolo su un arco forte (una routine di 13 passaggi esce intera, non a pezzi da 8)
        │
        v
  punteggio = minuti totali × coesione × 1/varianti, × 1,5 con legami fra app,
              × 1,25 se Claude raggiunge almeno un'app della routine
  avvio a freddo: meno di 3 episodi o un giorno solo -> ripetizioni dentro l'episodio, dichiarato
"""
from __future__ import annotations

import hashlib
from collections import Counter, defaultdict

from . import episodi as epm

MIN_N = 3
MAX_N = 8
SOGLIA = 3
LIFT = 3.0
MAX_CANDIDATI = 400
MAX_ROUTINE = 40
MAX_ESTESA = 24
BUCO_MS = 60000
# Le azioni che producono o spostano qualcosa. Il resto (finestra, visita, clic, nuova_scheda,
# chiudi, ricarica, indirizzo, cerca, tasti, annulla) è navigazione: da sola non fa una routine.
GESTI_LAVORO = {"compila", "copia", "taglia", "incolla", "salva", "salva_come", "esporta", "invia",
                "stampa", "apri", "apri_allegato", "scarica", "crea", "modifica", "sposta", "elimina",
                "menu", "nuovo"}


def e_barriera(s: str) -> bool:
    """Un passo di cui non si sa niente: app esclusa o campo protetto."""
    return s.endswith(":escluso") or s.endswith(":protetto")


def e_lavoro(s: str) -> bool:
    """Vero se il simbolo (o un simbolo del blocco) è un gesto di lavoro."""
    for x in epm.simboli_di(s):
        parti = x.split(":")
        if len(parti) > 1 and parti[1].split("×")[0] in GESTI_LAVORO:
            return True
    return False


def distanza(a, b) -> int:
    """Distanza di edit (Levenshtein) fra due sequenze di simboli."""
    if a == b:
        return 0
    prec = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prec[j] + 1, cur[j - 1] + 1, prec[j - 1] + (x != y)))
        prec = cur
    return prec[-1]


def firma_h(g) -> str:
    return hashlib.sha256(" > ".join(g).encode("utf-8")).hexdigest()[:16]


def archi_forti(sequenze: dict) -> set:
    """Gli archi del DFG con lift >= 3 e almeno 2 passaggi."""
    simboli = defaultdict(int)
    archi = defaultdict(int)
    uscite = defaultdict(int)
    totale = 0
    for seq in sequenze.values():
        s = [t["s"] for t in seq["token"]]
        for x in s:
            simboli[x] += 1
            totale += 1
        for a, b in zip(s, s[1:]):
            archi[(a, b)] += 1
            uscite[a] += 1
    forti = set()
    if not totale:
        return forti
    for (a, b), n in archi.items():
        if n < 2:
            continue
        p_b_dato_a = n / uscite[a]
        p_b = simboli[b] / totale
        if p_b > 0 and p_b_dato_a / p_b >= LIFT:
            forti.add((a, b))
    return forti


def _senza_sovrapposizioni(posizioni: list, n: int) -> list:
    out = []
    ultimo = {}
    for ep, i in sorted(posizioni):
        if ep in ultimo and i < ultimo[ep]:
            continue
        out.append((ep, i))
        ultimo[ep] = i + n
    return out


def _occorrenza(seq: list, i: int, n: int) -> dict:
    tok = seq[i:i + n]
    t0, t1 = tok[0]["t0"], max(t["t1"] for t in tok)
    durata = max(1, t1 - t0)
    buchi = 0
    for a, b in zip(tok, tok[1:]):
        g = b["t0"] - a["t1"]
        if g > BUCO_MS:
            buchi += g
    return {"t0": t0, "t1": t1, "durata": durata, "coesione": max(0.1, 1.0 - buchi / durata)}


def candidati(sequenze: dict, forti: set) -> dict:
    grezzi = defaultdict(list)
    for ep, seq in sequenze.items():
        s = [t["s"] for t in seq["token"]]
        for i in range(len(s)):
            if e_barriera(s[i]):
                continue
            for n in range(2, MAX_N + 1):
                if i + n > len(s) or e_barriera(s[i + n - 1]):
                    break
                if (s[i + n - 2], s[i + n - 1]) not in forti:
                    break
                if n >= MIN_N:
                    grezzi[tuple(s[i:i + n])].append((ep, i))
    out = {}
    for g, pos in grezzi.items():
        occ = _senza_sovrapposizioni(pos, len(g))
        if len(occ) >= 2:  # le varianti possono avere 2 occorrenze; una routine ne vuole SOGLIA
            out[g] = occ
    return out


def chiusi(cand: dict) -> dict:
    """Toglie i pattern che hanno un'estensione con le stesse occorrenze."""
    aperti = set()
    for g, occ in cand.items():
        if len(g) <= MIN_N:
            continue
        for sotto in (g[1:], g[:-1]):
            if sotto in cand and len(cand[sotto]) == len(occ):
                aperti.add(sotto)
    return {g: o for g, o in cand.items() if g not in aperti}


def _posizioni(occ: list) -> set:
    """Le posizioni (episodio, indice) coperte da occorrenze (ep, i, n)."""
    return {(ep, j) for ep, i, n in occ for j in range(i, i + n)}


def _estendi(occ: list, sequenze: dict, forti: set, coperti: set) -> list:
    """Allunga le occorrenze, a destra e poi a sinistra, finché almeno l'80% continua su un arco
    forte verso al massimo 3 simboli diversi (i rami delle varianti).

    Così una routine più lunga di 8 simboli esce intera, e i suoi pezzi non diventano routine a sé.
    """
    occ = [list(o) for o in occ]
    for verso in (1, -1):
        while max(o[2] for o in occ) < MAX_ESTESA:
            occupate = _posizioni([tuple(o) for o in occ]) | coperti
            passi = []
            for o in occ:
                ep, i, n = o
                seq = sequenze[ep]["token"]
                j = i + n if verso == 1 else i - 1
                if not (0 <= j < len(seq)) or (ep, j) in occupate:
                    continue
                arco = (seq[j - 1]["s"], seq[j]["s"]) if verso == 1 else (seq[j]["s"], seq[i]["s"])
                if arco in forti and not e_barriera(seq[j]["s"]):
                    passi.append((o, seq[j]["s"]))
            simboli = {s for _o, s in passi}
            if len(passi) < 0.8 * len(occ) or len(simboli) > 3:
                break
            for o, _s in passi:
                if verso == 1:
                    o[2] += 1
                else:
                    o[1] -= 1
                    o[2] += 1
    return [tuple(o) for o in occ]


def _corse(occ: list) -> list:
    """Le occorrenze attaccate una all'altra nella stessa sessione, unite: (ep, i, n, quante)."""
    out = []
    for ep, i, n in sorted(occ):
        if out and out[-1][0] == ep and out[-1][1] + out[-1][2] == i:
            e, i0, n0, k = out[-1]
            out[-1] = (e, i0, n0 + n, k + 1)
        else:
            out.append((ep, i, n, 1))
    return out


def _corse_estese(occ: list, sequenze: dict, forti: set, coperti: set):
    """Un ciclo dentro una routine più grande: apri l'allegato, poi sei volte copia e incolla.

    Se le occorrenze vengono a corse (più ripetizioni attaccate) e le corse, non le singole
    ripetizioni, hanno lo stesso contorno, la routine è la corsa con il suo contorno: le
    occorrenze diventano le corse estese. Altrimenti None, e restano le ripetizioni singole
    (una routine fatta due volte di fila resta due volte).
    """
    corse = _corse(occ)
    if len(corse) == len(occ) or len(corse) < SOGLIA:
        return None
    if sum(1 for c in corse if c[3] > 1) < 0.5 * len(corse):
        return None
    base = [(ep, i, n) for ep, i, n, _k in corse]
    estese = _estendi(base, sequenze, forti, coperti)
    cresciute = sum(1 for a, b in zip(base, estese) if b[2] > a[2])
    if cresciute < 0.8 * len(corse):
        return None
    return estese


def scopri(sequenze: dict, legami: list = (), raggiungibili=None) -> list:
    """Le routine, in ordine di punteggio. raggiungibili(simbolo) -> lista di canali."""
    forti = archi_forti(sequenze)
    cand = {g: o for g, o in chiusi(candidati(sequenze, forti)).items() if any(e_lavoro(s) for s in g)}
    info = {}
    for g, occ in cand.items():
        dati = [_occorrenza(sequenze[ep]["token"], i, len(g)) for ep, i in occ]
        tempo = sum(d["durata"] for d in dati)
        coes = sum(d["coesione"] for d in dati) / len(dati)
        info[g] = (tempo * coes, [(ep, i, len(g)) for ep, i in occ])
    ordine = sorted(info, key=lambda g: (-info[g][0], -len(g), g))[:MAX_CANDIDATI]
    usati = set()
    coperti = set()
    scelte = []
    for g in ordine:
        if g in usati:
            continue
        usati.add(g)
        tutte = info[g][1]
        libere = [o for o in tutte if not (_posizioni([o]) & coperti)]
        if len(libere) < SOGLIA or len(libere) < 0.5 * len(tutte):
            continue
        occ = list(libere)
        mie = _posizioni(occ)
        for d in ordine:
            if d in usati or abs(len(d) - len(g)) > 2 or distanza(d, g) > 2:
                continue
            usati.add(d)
            for o in info[d][1]:
                p = _posizioni([o])
                if p & (mie | coperti):
                    continue
                occ.append(o)
                mie |= p
        occ = _corse_estese(occ, sequenze, forti, coperti) or _estendi(occ, sequenze, forti, coperti)
        coperti |= _posizioni(occ)
        scelte.append(occ)
        if len(scelte) >= MAX_ROUTINE:
            break
    out = [_valuta(o, sequenze, legami, raggiungibili) for o in scelte]
    out.sort(key=lambda r: (-r["punteggio"], r["schema"]))
    return out


def varianti_raggruppate(forme: Counter) -> int:
    """Quante varianti vere: le forme a distanza di edit <= 2 da una più frequente sono la stessa."""
    rappresentanti = []
    for f, _n in forme.most_common():
        if not any(abs(len(f) - len(r)) <= 2 and distanza(f, r) <= 2 for r in rappresentanti):
            rappresentanti.append(f)
    return len(rappresentanti)


def _valuta(occ: list, sequenze: dict, legami: list, raggiungibili) -> dict:
    occorrenze = []
    forme = Counter()
    for sid, i, n in occ:
        seq = sequenze[sid]["token"]
        o = _occorrenza(seq, i, n)
        forma = tuple(t["s"] for t in seq[i:i + n])
        o.update({"sessione": sid, "ep": seq[i].get("ep", sid), "i": i, "n": n, "forma": forma})
        forme[forma] += 1
        occorrenze.append(o)
    occorrenze.sort(key=lambda o: o["t0"])
    g = max(forme, key=lambda f: (forme[f], len(f), f))
    episodi = {o["ep"] for o in occorrenze}
    giorni = {sequenze[o["sessione"]]["giorno"] for o in occorrenze}
    tempo = sum(o["durata"] for o in occorrenze)
    coesione = sum(o["coesione"] for o in occorrenze) / len(occorrenze)
    tra_app = 0
    for lg in legami:
        if lg.get("da_app") == lg.get("a_app"):
            continue
        da_ts = lg["a_ts"] - lg["ritardo_ms"]
        for o in occorrenze:
            membri = sequenze[o["sessione"]].get("episodi")
            if (membri is None or lg.get("episodio") in membri) and o["t0"] <= da_ts and lg["a_ts"] <= o["t1"]:
                tra_app += 1
                break
    ordinate = [f for f, _n in forme.most_common()]
    semplici = [x for s in g for x in epm.simboli_di(s)]
    app = []
    for s in semplici:
        a = s.split(":", 1)[0]
        if a not in app:
            app.append(a)
    ragg = []
    if raggiungibili is not None:
        for s in semplici:
            for canale in raggiungibili(s):
                if canale not in ragg:
                    ragg.append(canale)
    n_var = varianti_raggruppate(forme)
    punteggio = (tempo / 60000.0) * coesione / n_var
    if tra_app:
        punteggio *= 1.5
    if ragg:
        punteggio *= 1.25
    freddo = len(episodi) < SOGLIA or len(giorni) < 2
    return {
        "g": g, "firma_h": firma_h(g), "schema": epm.schema_breve(g),
        "varianti": [epm.schema_breve(f) for f in ordinate[:5]],
        "forme": [list(f) for f in ordinate[:10]],
        "volte": len(occorrenze), "episodi": len(episodi), "giorni": len(giorni),
        "lunghezza": len(g), "tempo_totale_ms": int(tempo), "coesione": round(coesione, 3),
        "n_varianti": n_var, "legami_tra_app": tra_app, "app": app, "raggiungibile": ragg,
        "punteggio": round(punteggio, 3), "avvio_a_freddo": freddo,
        "occorrenze": occorrenze,
        "dal": min(sequenze[o["sessione"]]["giorno"] for o in occorrenze),
        "al": max(sequenze[o["sessione"]]["giorno"] for o in occorrenze),
    }
