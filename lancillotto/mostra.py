"""Pagina locale con esattamente ciò che Claude può vedere oggi a L0 e L1.

Il contenuto viene dalle stesse funzioni di uscita.py che rispondono a Claude: la pagina mostra
il JSON identico, più una lettura a parole, cosa è stato escluso e quanto pesa il registro.
Nessuna risorsa esterna: CSS in linea, niente script, niente font da internet.
"""
from __future__ import annotations

import html
import json

from . import impostazioni, percorsi, uscita

CSS = """
:root{--sfondo:#fbfaf7;--testo:#1d1d1f;--tenue:#5f5f66;--bordo:#dedbd2;--riquadro:#ffffff;
--accento:#2f5d50;--codice:#f3f1ea}
@media (prefers-color-scheme: dark){:root{--sfondo:#161616;--testo:#ececec;--tenue:#a6a6ad;
--bordo:#353535;--riquadro:#1f1f1f;--accento:#8cc7b3;--codice:#262626}}
*{box-sizing:border-box}
body{margin:0;background:var(--sfondo);color:var(--testo);
font:16px/1.55 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Helvetica,Arial,sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 16px 64px}
h1{font-size:1.7rem;margin:0 0 4px}h2{font-size:1.2rem;margin:36px 0 8px;color:var(--accento)}
p{margin:6px 0}.tenue{color:var(--tenue)}
section{background:var(--riquadro);border:1px solid var(--bordo);border-radius:10px;padding:16px;margin:12px 0}
table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--bordo);
vertical-align:top}th{font-weight:600;color:var(--tenue);font-size:.9rem}
code,pre{font:13px/1.45 ui-monospace,Menlo,monospace}
pre{background:var(--codice);padding:12px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;word-break:break-word}
details summary{cursor:pointer;color:var(--accento);margin-top:8px}
ul{margin:6px 0 6px 20px;padding:0}
"""


def e(x) -> str:
    return html.escape(str(x), quote=True)


def _tabella(intestazioni: list, righe: list) -> str:
    if not righe:
        return '<p class="tenue">Niente da mostrare.</p>'
    th = "".join("<th>%s</th>" % e(h) for h in intestazioni)
    tr = "".join("<tr>%s</tr>" % "".join("<td>%s</td>" % e(c) for c in r) for r in righe)
    return "<table><tr>%s</tr>%s</table>" % (th, tr)


def _json(obj) -> str:
    return "<details><summary>Il JSON esatto che riceve Claude (%d token stimati)</summary><pre>%s</pre></details>" % (
        uscita.stima_token(obj), e(json.dumps(obj, ensure_ascii=False, indent=1)))


def _mb(n) -> str:
    return "%.1f MB" % (n / 1048576.0)


def _peso() -> list:
    out = []
    for nome, p in (("registro", percorsi.registro()), ("analisi", percorsi.analisi())):
        tot = 0
        for suff in ("", "-wal", "-shm"):
            q = p.with_name(p.name + suff)
            try:
                tot += q.stat().st_size
            except OSError:
                pass
        out.append((nome, _mb(tot)))
    return out


def genera(reg, an, ps, data: str) -> str:
    l0 = uscita.giorno(reg, an, ps, data)
    l0_routine = uscita.routine(an, 5)
    l1 = uscita.episodi(an, data)
    l1_catene = uscita.catene(an, data)
    t0, t1 = uscita.giorno_intervallo(data)
    escluse = [r["nome"] or r["bundle"] for r in reg.execute("SELECT bundle, nome FROM app WHERE esclusa = 1")]
    prot = reg.execute("SELECT COALESCE(SUM(dur_ms), 0) FROM evento WHERE tipo = 'protetto' AND ts >= ? AND ts < ?",
                       (t0, t1)).fetchone()[0]
    escl = reg.execute("SELECT COALESCE(SUM(dur_ms), 0) FROM evento WHERE tipo = 'escluso' AND ts >= ? AND ts < ?",
                       (t0, t1)).fetchone()[0]
    n_eventi = reg.execute("SELECT COUNT(*) FROM evento WHERE ts >= ? AND ts < ?", (t0, t1)).fetchone()[0]
    imp = impostazioni.leggi()
    parti = ["<!doctype html><html lang=\"it\"><head><meta charset=\"utf-8\">",
             "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
             "<title>Cosa vede Claude</title><style>%s</style></head><body><main>" % CSS,
             "<h1>Cosa vede Claude</h1>",
             "<p class=\"tenue\">Giornata del %s. Questa pagina sta solo sul tuo Mac. Mostra esattamente "
             "ciò che Claude riceve quando gli chiedi di guardare Lancillotto: i titoli delle finestre "
             "escono solo con parole comuni, ogni altra parola diventa un segnaposto come [P3], i siti "
             "poco noti diventano [SITO_2].</p>" % e(data)]
    parti.append("<h2>Livello 0: i riassunti</h2><section>")
    parti.append("<p>Tempo attivo: <b>%s minuti</b>, in pausa: %s minuti.</p>" % (e(l0.get("attivo_min")),
                                                                               e(l0.get("pausa_min"))))
    parti.append(_tabella(["App", "Minuti"], l0.get("app", [])))
    parti.append("<p><b>Lavori più lunghi</b></p>")
    parti.append(_tabella(["N.", "Ora", "Minuti", "Passaggi"],
                          [[x["id"], x["ora"], x["min"], x["firma"]] for x in l0.get("episodi", [])]))
    parti.append("<p><b>Routine</b></p>")
    parti.append(_tabella(["N.", "Passaggi", "Volte", "Giorni", "Minuti in tutto", "Stato"],
                          [[x["id"], x["schema"], x["volte"], x["giorni"], x["tempo_tot_min"], x["stato"]]
                           for x in l0_routine.get("routine", [])]))
    if l0.get("limiti"):
        parti.append("<p class=\"tenue\">Limiti: %s</p>" % e("; ".join(l0["limiti"])))
    parti.append(_json(l0))
    parti.append(_json(l0_routine))
    parti.append("</section><h2>Livello 1: i passaggi, con i segnaposto</h2><section>")
    parti.append(_tabella(["N.", "Dalle", "Alle", "App", "Parole"],
                          [[x["id"], x["ora"], x.get("fine", ""), ", ".join(x.get("app", [])),
                            ", ".join(x.get("parole", []))] for x in l1.get("episodi", [])]))
    parti.append(_json(l1))
    parti.append("<p><b>Collegamenti fra app</b> (copia e incolla, download, file)</p>")
    parti.append(_tabella(["Ora", "Tipo", "Da", "A", "Fiducia"],
                          [[x["ora"], x["tipo"], x["da"], x["a"], x["confidenza"]]
                           for x in l1_catene.get("catene", [])[:60]]))
    parti.append(_json(l1_catene))
    parti.append("</section><h2>Livello 2: il testo a schermo</h2><section><p>Il testo delle finestre "
                 "non esce mai da solo. Claude lo riceve solo se tu fai clic su <b>Mostra</b> nel menu "
                 "di Lancillotto, per l'intervallo scritto lì, e per 10 minuti.</p></section>")
    parti.append("<h2>Cosa è stato escluso oggi</h2><section><ul>")
    parti.append("<li>Campi protetti (password e simili): %d minuti, senza nessun dato.</li>" % uscita.minuti(prot))
    parti.append("<li>App e siti esclusi: %d minuti, solo app e durata.</li>" % uscita.minuti(escl))
    parti.append("<li>App escluse in più: %s.</li>" % e(", ".join(escluse) or "nessuna"))
    parti.append("<li>Siti esclusi in più: %s.</li>" % e(", ".join(imp.get("escludi_domini") or []) or "nessuno"))
    parti.append("<li>Sempre esclusi: gestori di password, Portachiavi, banche e trading, Messaggi, WhatsApp, "
                 "Signal, Telegram, Beeper, finestre in incognito, home banking, Agenzia Entrate, INPS, "
                 "Fascicolo Sanitario e le pagine di accesso.</li></ul></section>")
    parti.append("<h2>Quanto pesa</h2><section>")
    parti.append(_tabella(["File", "Peso"], _peso()))
    parti.append("<p>Eventi registrati oggi: %d. Il grezzo si tiene %s giorni.</p>" % (
        int(n_eventi), e(imp.get("conservazione_giorni"))))
    parti.append("</section><p class=\"tenue\">Per fermare la registrazione: <code>lancillotto pausa</code>. "
                 "Per cancellare gli ultimi 10 minuti: <code>lancillotto dimentica 10</code>.</p>")
    parti.append("</main></body></html>\n")
    return "".join(parti)
