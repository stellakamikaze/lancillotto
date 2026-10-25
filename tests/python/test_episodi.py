"""Episodi: tagli su inattività, sonno e oggetto principale; ricucitura; compressione."""
from __future__ import annotations

from base import Base

from lancillotto import episodi as epm


def ev(i, ts, tipo, app_id=1, bundle="com.apple.Notes", simbolo="Note:finestra", ancora="a:note", dur=0):
    return {"id": i, "ts": ts, "tipo": tipo, "app_id": app_id, "bundle": bundle, "dur_ms": dur,
            "_simbolo": simbolo, "_ancora": ancora, "det": {}}


MIN = 60000


class TestEpisodi(Base):
    def test_inattivita_taglia(self):
        eventi = [ev(1, 0, "finestra"), ev(2, 30000, "comando", simbolo="Note:copia"),
                  dict(ev(3, 60000, "inattivo", app_id=None, simbolo=None, ancora=None), dur=6 * MIN),
                  ev(4, 7 * MIN, "comando", simbolo="Mail:incolla", ancora="a:mail")]
        eps = epm.segmenta(eventi)
        self.assertEqual(len(eps), 2, "l'inattività oltre 5 minuti non taglia")

    def test_buco_senza_eventi_taglia(self):
        eventi = [ev(1, 0, "finestra"), ev(2, 20 * MIN, "comando", simbolo="Mail:copia", ancora="a:mail")]
        self.assertEqual(len(epm.segmenta(eventi)), 2)

    def test_sonno_e_blocco_tagliano(self):
        for tipo in ("sonno", "blocco", "pausa"):
            eventi = [ev(1, 0, "finestra"), ev(2, 10000, tipo, app_id=None, simbolo=None, ancora=None),
                      ev(3, 20000, "comando", simbolo="Mail:copia", ancora="a:mail")]
            self.assertEqual(len(epm.segmenta(eventi)), 2, tipo)

    def test_principale_che_non_torna_taglia_al_primo_oggetto_nuovo(self):
        eventi = []
        t = 0
        for k in range(10):          # 10 minuti sul documento A
            eventi.append(ev(len(eventi) + 1, t, "comando", simbolo="Pages:salva", ancora="f:A"))
            t += MIN
        for k in range(12):          # poi 12 minuti sul sito B, senza tornare su A
            eventi.append(ev(len(eventi) + 1, t, "url", simbolo="Chrome:visita:x", ancora="d:b.it"))
            t += MIN
        eps = epm.segmenta(eventi)
        self.assertEqual(len(eps), 2)
        self.assertEqual(eps[1].eventi[0]["_ancora"], "d:b.it", "il taglio non cade sul primo oggetto nuovo")

    def test_ricucitura_entro_due_ore(self):
        eventi = [ev(1, 0, "comando", simbolo="Pages:salva", ancora="f:A"),
                  ev(2, MIN, "comando", simbolo="Pages:salva", ancora="f:A"),
                  dict(ev(3, 2 * MIN, "sonno", app_id=None, simbolo=None, ancora=None)),
                  ev(4, 60 * MIN, "comando", simbolo="Pages:salva", ancora="f:A")]
        self.assertEqual(len(epm.segmenta(eventi)), 1, "lo stesso oggetto entro 2 ore si ricuce")
        eventi[-1]["ts"] = 3 * 3600000
        self.assertEqual(len(epm.segmenta(eventi)), 2)

    def test_comprimi(self):
        righe = [{"evento_id": i, "simbolo": s, "ts": i * 1000, "fine": i * 1000 + 500}
                 for i, s in enumerate(["Mail:finestra", "Chrome:finestra", "Chrome:incolla:x", "Chrome:incolla:x",
                                        "Chrome:incolla:x", "Mail:finestra"])]
        token = epm.comprimi(righe)
        self.assertEqual(epm.firma(token), "Mail:finestra > Chrome:incolla:x×3 > Mail:finestra")


class TestSimboli(Base):
    def test_simboli_del_contratto(self):
        from lancillotto import analisi, pseudonimi
        an = analisi.apri()
        self.addCleanup(an.close)
        ctx = epm.Contesto(pseudonimi.Pseudonimi(an))
        base = {"app_id": 3, "bundle": "com.google.Chrome", "app_nome": "Google Chrome", "ts": 0}
        self.assertEqual(ctx.simbolo(dict(base, tipo="finestra", det={})), "Chrome:finestra")
        self.assertEqual(ctx.simbolo(dict(base, tipo="url", dominio="mail.google.com", det={})),
                         "Chrome:visita:mail.google.com")
        ctx.simbolo(dict(base, tipo="campo_focus", det={"ruolo": "AXTextField"}))
        self.assertEqual(ctx.simbolo(dict(base, tipo="comando", det={"tasti": "cmd+v"})),
                         "Chrome:incolla:mail.google.com/campo")
        self.assertEqual(ctx.simbolo(dict(base, tipo="menu", det={"percorso": "Modifica > Incolla"})),
                         "Chrome:incolla:mail.google.com/campo")
        self.assertIsNone(ctx.simbolo(dict(base, tipo="comando", det={"tasti": "cmd+tab"})))
        self.assertEqual(ctx.simbolo({"app_id": None, "tipo": "file_crea", "ext": "PDF", "cartella": "download",
                                      "det": {}, "ts": 0}), "File:scarica:pdf")
        self.assertEqual(ctx.simbolo(dict(base, tipo="escluso", det={"perche": "app"})), "[esclusa]:escluso")
        self.assertEqual(ctx.simbolo(dict(base, tipo="clic", det={"ruolo": "AXButton", "etichetta": "Carica file"})),
                         "Chrome:clic:carica-file")
        self.assertEqual(ctx.simbolo(dict(base, tipo="clic", det={"ruolo": "AXLink", "web": 1})), "Chrome:clic:web")
