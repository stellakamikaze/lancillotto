// SchermoProve.swift: prove del testo a schermo per --selftest e --scenario-sintetico.
//
// SelftestSchermo.controlli(): funzioni pure di SchermoTesto.swift (normalizzazione, deduplica,
// delta, visita con budget su alberi finti, calendario delle letture, ordine dell'OCR,
// scelta della finestra, riduzione). Nessun AX, nessuno schermo, nessuna finestra.
// Sulla build VELENO la visita legge anche AXSecureTextField: il controllo "campo protetto"
// fallisce, ed è il veleno che attacca.
//
// ScenarioSchermo.aggiungi(): un albero AX finto passa dalla stessa visita, dalle stesse righe
// e dalla stessa deduplica del sensore vero, poi dall'Annotatore. Contiene due veleni già
// cercati dal banco (il valore di un AXSecureTextField e una chiave sk-ant a schermo) e una
// seconda istantanea identica, che non deve diventare un evento.

import CoreGraphics
import Foundation

/// Nodo di un albero AX finto: indice nell'array, ruolo, testo e figli.
private struct NodoFinto {
    var ruolo: String
    var subruolo: String? = nil
    var testo: String? = nil
    var figli: [Int] = []
}

private final class Letti {
    var indici = Set<Int>()
}

private final class OrologioFinto {
    var ns: UInt64 = 0
}

private func visitaFinta(_ albero: [NodoFinto], budget: inout Budget, valoriCampi: Bool, letti: Letti? = nil) -> RisultatoVisita {
    VisitaAX.visita(radice: 0, budget: &budget, valoriCampi: valoriCampi,
                    struttura: { i in (albero[i].ruolo, albero[i].subruolo) },
                    figli: { i, _ in albero[i].figli },
                    testo: { i, _ in
                        letti?.indici.insert(i)
                        return albero[i].testo
                    })
}

enum SelftestSchermo {
    static func controlli() -> [(Bool, String)] {
        var c: [(Bool, String)] = []
        func vero(_ b: Bool, _ nome: String) { c.append((b, "schermo: " + nome)) }
        func uguale<T: Equatable>(_ a: T, _ b: T, _ nome: String) {
            c.append((a == b, "schermo: \(nome): \(a) invece di \(b)"))
        }

        // Normalizzazione: spazi, righe corte, righe senza lettere né cifre, a capo di ogni tipo.
        let n = TestoSchermo.righe(["  Riga   uno  \n\tRiga due\r\n x \n---\n•\u{2028}Terza\triga"])
        uguale(n.righe, ["Riga uno", "Riga due", "Terza riga"], "normalizzazione")
        vero(!n.troncato, "normalizzazione non troncata")

        // Deduplica dentro l'istantanea, con l'ordine della prima comparsa.
        let d = TestoSchermo.righe(["Totale 10", "Totale  10", "Iva 2", "Totale 10\nIva 2"])
        uguale(d.righe, ["Totale 10", "Iva 2"], "deduplica")

        // Tetto di righe.
        let molte = TestoSchermo.righe((0..<2500).map { "riga \($0)" })
        uguale(molte.righe.count, TestoSchermo.massimoRighe, "tetto di righe")
        vero(molte.troncato, "tetto di righe segna troncato")

        // Delta.
        uguale(DeltaSchermo.calcola(prima: nil, dopo: [1, 2, 3]), DeltaSchermo(aggiunte: 3, tolte: 0), "delta prima istantanea")
        uguale(DeltaSchermo.calcola(prima: [1, 2, 3], dopo: [2, 3, 4]), DeltaSchermo(aggiunte: 1, tolte: 1), "delta una dentro una fuori")
        vero(DeltaSchermo.calcola(prima: [1, 2], dopo: [2, 1]).invariato, "delta invariato")

        // ElaboraSchermo: la stessa finestra con le stesse righe non dà un secondo evento.
        let e = ElaboraSchermo()
        vero(e.nuove(chiave: "A", righe: ["uno", "due"]) != nil, "prima istantanea di A")
        vero(e.nuove(chiave: "A", righe: ["due", "uno"]) == nil, "A invariata")
        vero(e.nuove(chiave: "B", righe: ["uno", "due"]) != nil, "B indipendente da A")
        uguale(e.nuove(chiave: "A", righe: ["uno", "tre"]), DeltaSchermo(aggiunte: 1, tolte: 1), "A cambiata")
        vero(e.nuove(chiave: "C", righe: []) == nil, "istantanea vuota senza evento")

        // Visita: ordine di lettura, campi protetti mai letti, valori dei campi solo se ammessi.
        let albero: [NodoFinto] = [
            NodoFinto(ruolo: "AXWindow", figli: [1, 2, 3, 4, 5, 6, 8]),
            NodoFinto(ruolo: "AXStaticText", testo: "Fattura n. 118"),
            NodoFinto(ruolo: "AXTextArea", testo: "Riga uno\nRiga due"),
            NodoFinto(ruolo: "AXSecureTextField", testo: "SegretaUno"),
            NodoFinto(ruolo: "AXTextField", subruolo: "AXSecureTextField", testo: "SegretaDue"),
            NodoFinto(ruolo: "AXTextField", testo: "Importo 10"),
            NodoFinto(ruolo: "AXGroup", testo: "testo di un gruppo: non si legge", figli: [7]),
            NodoFinto(ruolo: "AXStaticText", testo: "Dentro il gruppo"),
            NodoFinto(ruolo: "AXButton", testo: "Salva", figli: [9]),
            NodoFinto(ruolo: "AXStaticText", testo: "figlio di un pulsante: non si visita"),
        ]
        let letti = Letti()
        var b1 = Budget()
        let v1 = visitaFinta(albero, budget: &b1, valoriCampi: true, letti: letti)
        uguale(v1.testi, ["Fattura n. 118", "Riga uno\nRiga due", "Importo 10", "Dentro il gruppo", "Salva"], "visita: testi in ordine")
        vero(!letti.indici.contains(3) && !letti.indici.contains(4), "visita: campo protetto mai letto")
        uguale(v1.protetti, 2, "visita: campi protetti contati")
        vero(!v1.testi.joined().contains("Segreta"), "visita: nessun valore protetto nei testi")
        uguale(v1.nodi, 9, "visita: nodi visitati")
        vero(!v1.troncato, "visita: non troncata")
        var b2 = Budget()
        let v2 = visitaFinta(albero, budget: &b2, valoriCampi: false)
        vero(!v2.testi.contains("Importo 10"), "visita: valori_campi falso salta i campi")

        // Budget di nodi: 5000 nodi, tetto 3000.
        var largo = [NodoFinto(ruolo: "AXGroup", figli: Array(1..<5000))]
        for i in 1..<5000 { largo.append(NodoFinto(ruolo: "AXStaticText", testo: "voce \(i)")) }
        var b3 = Budget()
        let v3 = visitaFinta(largo, budget: &b3, valoriCampi: true)
        uguale(v3.nodi, Budget.nodiDefault, "budget: tetto di nodi")
        vero(v3.troncato, "budget: tetto di nodi segna troncato")
        uguale(v3.testi.first, "voce 1", "budget: si parte dall'alto")

        // Budget di tempo: ogni lettura dell'orologio avanza di 1 ms, tetto 50 ms.
        let orologio = OrologioFinto()
        var b4 = Budget(ms: 50, ora: {
            orologio.ns += 1_000_000
            return orologio.ns
        })
        let v4 = visitaFinta(largo, budget: &b4, valoriCampi: true)
        vero(v4.nodi >= 40 && v4.nodi <= 50 && v4.troncato, "budget: tetto di tempo (\(v4.nodi) nodi)")

        // Budget di caratteri.
        var b5 = Budget(caratteri: 25)
        let v5 = visitaFinta(albero, budget: &b5, valoriCampi: true)
        vero(v5.testi.joined().count <= 25 && v5.troncato, "budget: tetto di caratteri")

        // Calendario: attesa di 2 s dopo un cambio, poi ogni 20 s solo con input.
        var p = Pianificatore()
        p.osserva("A", ts: 0)
        vero(!p.daLeggere(ts: 1_000, attivita: true), "calendario: niente prima di 2 s")
        vero(p.daLeggere(ts: 2_000, attivita: true), "calendario: lettura dopo 2 s")
        p.letto(ts: 2_000)
        vero(!p.daLeggere(ts: 21_000, attivita: true), "calendario: niente prima di 20 s")
        vero(p.daLeggere(ts: 22_000, attivita: true), "calendario: lettura dopo 20 s con input")
        vero(!p.daLeggere(ts: 22_000, attivita: false), "calendario: senza input niente lettura")
        p.letto(ts: 22_000)
        p.osserva("A", ts: 23_000)
        vero(!p.daLeggere(ts: 23_000, attivita: true), "calendario: stessa chiave non è un cambio")
        p.osserva("B", ts: 24_000)
        p.osserva("C", ts: 25_000)
        vero(!p.daLeggere(ts: 26_000, attivita: true), "calendario: un cambio ricomincia l'attesa")
        vero(p.daLeggere(ts: 27_000, attivita: false), "calendario: dopo il cambio basta l'attesa")
        p.osserva(nil, ts: 27_500)
        vero(!p.daLeggere(ts: 40_000, attivita: true), "calendario: chiave nulla non legge")
        // Un titolo che cambia ogni secondo si legge comunque una volta per intervallo.
        var q = Pianificatore()
        for s in 0..<20 { q.osserva("T\(s)", ts: Int64(s) * 1_000) }
        vero(!q.daLeggere(ts: 19_500, attivita: true), "calendario: titolo instabile, prima dell'intervallo no")
        q.osserva("T20", ts: 20_000)
        vero(q.daLeggere(ts: 20_000, attivita: true), "calendario: titolo instabile, dopo l'intervallo sì")
        // Rinvio: si riprova solo dopo un'altra attesa.
        q.rinvia(ts: 20_000)
        vero(!q.daLeggere(ts: 21_000, attivita: true) && q.daLeggere(ts: 22_000, attivita: true), "calendario: rinvio")
        // OCR: uno per intervallo, e l'OCR rimasto in sospeso parte quando tocca.
        var o = Pianificatore()
        o.osserva("A", ts: 0)
        o.ocrAvviato(ts: 2_000)
        vero(!o.ocrAmmesso(ts: 10_000) && o.ocrAmmesso(ts: 22_000), "calendario: un OCR ogni 20 s")
        o.osserva("B", ts: 10_000)
        o.letto(ts: 12_000)
        o.ocrPendente = true
        vero(!o.daLeggere(ts: 15_000, attivita: false) && o.daLeggere(ts: 22_000, attivita: false), "calendario: OCR in sospeso")
        // Riduzione: oltre 40 MB l'intervallo raddoppia.
        uguale(TestoSchermo.fattoreRiduzione(pesoByte: 39_000_000), Int64(1), "riduzione sotto 40 MB")
        uguale(TestoSchermo.fattoreRiduzione(pesoByte: 41_000_000), Int64(2), "riduzione oltre 40 MB")
        uguale(TestoSchermo.fattoreRiduzione(pesoByte: 81_000_000), Int64(4), "riduzione oltre 80 MB")
        uguale(TestoSchermo.fattoreRiduzione(pesoByte: 900_000_000), Int64(8), "riduzione con tetto")
        var r = Pianificatore()
        r.fattore = TestoSchermo.fattoreRiduzione(pesoByte: 41_000_000)
        uguale(r.intervallo, Int64(40_000), "riduzione: intervallo 40 s")

        // Livello dell'OCR.
        var l = LivelloOCR()
        vero(l.scegliAccurate(), "ocr: accurate senza misure")
        l.misura(ms: 200, accurate: true)
        vero(l.scegliAccurate(), "ocr: accurate se costa poco")
        var l2 = LivelloOCR()
        l2.misura(ms: 1150, accurate: true)
        _ = l2.scegliAccurate()
        vero(!l2.scegliAccurate(), "ocr: fast dopo una sola misura accurate da 1,1 s")
        for _ in 0..<10 { l.misura(ms: 4000, accurate: true) }
        var scelte = [Bool]()
        for _ in 0..<40 { scelte.append(l.scegliAccurate()) }
        uguale(scelte.filter { $0 }.count, 2, "ocr: fast se costa troppo, accurate una volta ogni 20")

        // Ordine dell'OCR: bande dall'alto, da sinistra dentro la banda.
        let voci = [
            VoceOCR(testo: "basso", x: 0.1, y: 0.10, altezza: 0.04),
            VoceOCR(testo: "alto destra", x: 0.6, y: 0.80, altezza: 0.04),
            VoceOCR(testo: "alto sinistra", x: 0.1, y: 0.805, altezza: 0.04),
            VoceOCR(testo: "mezzo", x: 0.3, y: 0.50, altezza: 0.04),
        ]
        uguale(TestoSchermo.ordinaOCR(voci), ["alto sinistra", "alto destra", "mezzo", "basso"], "ordine dell'OCR")

        // Finestra da catturare: stesso processo, livello 0, stessa cornice.
        let cornice = CGRect(x: 100, y: 50, width: 800, height: 600)
        let finestre = [
            VoceFinestra(id: 1, pid: 7, livello: 25, cornice: cornice),
            VoceFinestra(id: 2, pid: 9, livello: 0, cornice: cornice),
            VoceFinestra(id: 3, pid: 7, livello: 0, cornice: CGRect(x: 0, y: 0, width: 400, height: 300)),
            VoceFinestra(id: 4, pid: 7, livello: 0, cornice: CGRect(x: 101, y: 52, width: 798, height: 601)),
        ]
        uguale(TestoSchermo.scegliFinestra(finestre, pid: 7, cornice: cornice), UInt32(4), "finestra da catturare")
        vero(TestoSchermo.scegliFinestra(Array(finestre.prefix(3)), pid: 7, cornice: cornice) == nil,
             "nessuna finestra con la stessa cornice: niente cattura")

        // Costi in salute: numeri, niente testo osservato.
        var m = MediaCosti()
        m.aggiungi(fonte: "ax", ms: 10)
        m.aggiungi(fonte: "ax", ms: 20)
        m.aggiungi(fonte: "ocr", ms: 700)
        uguale(m.descrizione(intervallo: 20_000, pesoByte: 12_300_000, livelloFast: false),
               "costo medio ax 15 ms su 2 letture, ocr 700 ms su 1 (accurate), intervallo 20 s, peso del giorno 12 MB",
               "costi in salute")
        return c
    }
}

enum ScenarioSchermo {
    /// Un'istantanea da un albero AX finto, poi la stessa una seconda volta (deduplicata).
    static func aggiungi(ann: Annotatore, ts: Int64) {
        // La chiave si compone qui per non lasciarla intera nel sorgente.
        let chiave = "sk-ant-" + "api03-VELENOCHIAVE" + String(repeating: "x", count: 24)
        let albero: [NodoFinto] = [
            NodoFinto(ruolo: "AXWindow", figli: [1, 2, 3, 4, 5, 6]),
            NodoFinto(ruolo: "AXHeading", testo: "Riepilogo ordine"),
            NodoFinto(ruolo: "AXStaticText", testo: "Totale da pagare: 1.234,56 EUR"),
            NodoFinto(ruolo: "AXTextArea", testo: "Nota per il fornitore\nConsegna entro venerdì\nRiepilogo ordine"),
            NodoFinto(ruolo: "AXTextField", subruolo: "AXSecureTextField", testo: "Segreta123!Veleno"),
            NodoFinto(ruolo: "AXStaticText", testo: "Chiave di prova: " + chiave),
            NodoFinto(ruolo: "AXGroup", figli: [7]),
            NodoFinto(ruolo: "AXStaticText", testo: "Totale da pagare:  1.234,56 EUR"),
        ]
        let elabora = ElaboraSchermo()
        for k in 0..<2 {
            var budget = Budget()
            let visita = visitaFinta(albero, budget: &budget, valoriCampi: true)
            let righe = TestoSchermo.righe(visita.testi)
            guard elabora.nuove(chiave: "scenario", righe: righe.righe) != nil else { continue }
            ann.schermo(fonte: "ax", ms: 9, righe: righe.righe, troncato: visita.troncato || righe.troncato, ts: ts + Int64(k) * 1000)
        }
    }
}
