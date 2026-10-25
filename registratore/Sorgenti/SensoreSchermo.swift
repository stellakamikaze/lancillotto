// SensoreSchermo.swift: il testo della finestra attiva, da AX e, se serve, dall'OCR.
//
//   main, ogni 1 s: legge Contesto, impostazioni, secure input, secondi dall'ultimo input
//        └─> coda "schermo" (seriale): Pianificatore decide se leggere
//              FILTRI PRIMA DI TUTTO: esito .pieno (niente pausa, protetto, app o dominio
//              escluso, finestra privata), Accessibilità concessa, titolo noto, niente
//              inattività, sonno o blocco. Altrimenti non si legge niente.
//              ├─ AX: albero della finestra a fuoco con budget 50 ms e 3000 nodi,
//              │      timeout 0,05 s per chiamata, AXSecureTextField mai letto né visitato;
//              │      nei browser solo la pagina (AXWebArea): mai schede, barra, preferiti
//              ├─ meno di 3 righe utili, ocr acceso, permesso Registrazione schermo già dato:
//              │      coda "ocr" (al massimo un OCR in volo, al massimo uno ogni 20 s):
//              │      cattura della SOLA finestra (ScreenCaptureKit su 14+, CGWindowListCreateImage
//              │      su 13) -> Vision it-IT + en-US -> l'immagine si butta, mai su disco;
//              │      nei browser restano solo le righe dentro la cornice della pagina
//              └─ verifica che la finestra sia ancora la stessa -> ElaboraSchermo (righe uguali:
//                 niente evento) -> Annotatore.schermo (rifà i filtri) -> Registro.righe
//                 (redazione, riga.h con volte e ultima_ts, delta, impronte delle righe nuove)
//   ombra: Accessibilità assente -> niente testo (senza titolo non si sa se la finestra è
//          privata o di una banca: nel dubbio no). Salute la scrive SensoreAX.
//   ombra: permesso schermo assente o ocr spento -> solo AX, una riga in salute "ocr".
//   ombra: OCR senza risposta per 30 s -> si libera il turno, salute "guasto".
//   ombra: peso del giorno oltre 40 MB -> intervallo raddoppiato, salute "degradato".
// Ogni ora: costo medio di AX e OCR in salute. Il permesso schermo non si chiede da qui:
// lo chiede la finestra dei permessi (Permessi.swift).
//
// App Electron: l'albero AX è vuoto finché nessuno imposta AXManualAccessibility sull'app.
// Si imposta solo se impostazioni.json ha "ax_electron": true (default no): fa costruire
// all'app l'albero completo, con un costo di CPU nell'app stessa. Senza, interviene l'OCR.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

final class SensoreSchermo: NSObject, Sensore {
    let dip: Dipendenze

    /// Quello che il tick del main thread passa alla coda.
    private struct Foto {
        let ts: Int64
        let stato: Contesto.Stato
        let secure: Bool
        let sospeso: Bool
        let msDaInput: Int64
        let ocrRichiesto: Bool
        let permessoSchermo: Bool
        let valoriCampi: Bool
        let electron: Bool
        let testoSchermo: Bool
        var ocr: Bool { ocrRichiesto && permessoSchermo }
    }

    // Solo main thread.
    private var timer: Timer?
    private var sospeso = false
    private var permessoSchermo = false
    private var ultimoPreflight: Int64 = Int64.min / 4
    private var statoTesto: Bool?
    private var electronPerPid: [pid_t: Bool] = [:]

    // Solo su `coda`.
    private let coda = DispatchQueue(label: "org.stellakamikaze.lancillotto.schermo", qos: .utility)
    private let codaOCR = DispatchQueue(label: "org.stellakamikaze.lancillotto.schermo.ocr", qos: .utility)
    private var fermo = true
    private var pianificatore = Pianificatore()
    private let elabora = ElaboraSchermo()
    private var livello = LivelloOCR()
    private var ultimoFast = false
    private var costi = MediaCosti()
    private var ocrInVolo = false
    private var ocrAvviatoTs: Int64 = 0
    private var ocrGenerazione = 0
    private var giorno = ""
    private var inizioGiorno: Int64 = 0
    private var pesoGiorno: Int64?
    private var ultimoControlloPeso: Int64 = Int64.min / 4
    private var ultimaSaluteCosti: Int64 = 0
    private var statoOCR: String?
    private var electronAccesi: Set<pid_t> = []
    private var segnalati: [String: Int64] = [:]

    static let controlloPeso: Int64 = 600_000
    static let saluteCosti: Int64 = 3_600_000
    static let ocrScaduto: Int64 = 30_000

    init(dip: Dipendenze) {
        self.dip = dip
        super.init()
    }

    // MARK: Avvio e arresto (main thread)

    func avvia() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(sospendi), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(sospendi), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(riprendi), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(riprendi), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(sospendi), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(riprendi), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        let ora = oraMs()
        coda.async {
            self.fermo = false
            self.ultimaSaluteCosti = ora
        }
        dip.registro.salute(sensore: "schermo", stato: "ok",
                            dettaglio: "avviato: budget AX \(Budget.msDefault) ms e \(Budget.nodiDefault) nodi, intervallo \(Pianificatore.intervalloBase / 1000) s")
        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func ferma() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        timer?.invalidate()
        timer = nil
        coda.async {
            self.fermo = true
            self.ocrGenerazione += 1
            self.ocrInVolo = false
            self.elabora.dimentica()
        }
    }

    @objc private func sospendi() { sospeso = true }
    @objc private func riprendi() { sospeso = false }

    @objc private func tick() {
        let ts = oraMs()
        let stato = dip.contesto.leggi()
        let imp = dip.impostazioni?.attuali
        let ocrRichiesto = imp?.ocr ?? false
        if ocrRichiesto && ts - ultimoPreflight >= 30_000 {
            // Solo il controllo: la richiesta del permesso la fa la finestra dei permessi.
            permessoSchermo = CGPreflightScreenCaptureAccess()
            ultimoPreflight = ts
        }
        var electron = false
        if imp?.axElectron == true, stato.pid > 0 {
            if let e = electronPerPid[stato.pid] {
                electron = e
            } else {
                electron = SensoreSchermo.eElectron(pid: stato.pid)
                if electronPerPid.count > 200 { electronPerPid.removeAll() }
                electronPerPid[stato.pid] = electron
            }
        }
        let tutti = CGEventType(rawValue: UInt32.max) ?? .null
        let secondi = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: tutti)
        let foto = Foto(ts: ts, stato: stato, secure: dip.annotatore.secureInput(), sospeso: sospeso,
                        msDaInput: Int64(max(0, secondi) * 1000), ocrRichiesto: ocrRichiesto,
                        permessoSchermo: permessoSchermo, valoriCampi: imp?.valoriCampi ?? false, electron: electron,
                        testoSchermo: imp?.testoSchermo ?? false)
        coda.async { [weak self] in self?.passo(foto) }
    }

    /// App Electron: ha Electron Framework.framework nel bundle. Solo uno stat nel bundle dell'app.
    private static func eElectron(pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let quadro = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path
        return FileManager.default.fileExists(atPath: quadro)
    }

    // MARK: Decisione (coda)

    private func chiave(_ s: Contesto.Stato) -> String? {
        guard let f = s.finestra else { return nil }
        return "\(s.pid)\u{1}" + f.valore
    }

    private func passo(_ f: Foto) {
        guard !fermo else { return }
        manutenzione(f.ts)
        aggiornaStatoOCR(f)
        aggiornaStatoTesto(f)
        let s = f.stato
        let ammesso = f.testoSchermo && !f.sospeso && !f.secure && s.permessoAX && !s.inattivo && !s.pausa
            && s.esito == .pieno && s.app != nil && s.finestra != nil && s.pid > 0
            && !dip.filtri.inPausa(f.ts)
        pianificatore.osserva(ammesso ? chiave(s) : nil, ts: f.ts)
        guard ammesso, !ocrInVolo else { return }
        guard pianificatore.daLeggere(ts: f.ts, attivita: f.msDaInput < pianificatore.intervallo) else { return }
        leggi(f)
    }

    // MARK: Lettura AX (coda)

    private func leggi(_ f: Foto) {
        let s = f.stato
        guard let fin = s.finestra, let app = s.app else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let elApp = AXUIElementCreateApplication(s.pid)
        AXUIElementSetMessagingTimeout(elApp, LettoreAX.timeout)
        if f.electron { accendiElectron(pid: s.pid, elemento: elApp, bundle: app.bundle) }
        guard let w = LettoreAX.finestraAFuoco(elApp), stessaFinestra(w, fin, s.finestraAX) else {
            pianificatore.rinvia(ts: f.ts)
            return
        }
        var budget = Budget()
        let browser = Esclusioni.browser.contains(app.bundle)
        var pagina: AXUIElement?
        let visita = VisitaAX.visita(radice: w, budget: &budget, valoriCampi: f.valoriCampi, soloWebArea: browser,
                                     struttura: LettoreAX.struttura, figli: LettoreAX.figli, testo: LettoreAX.testo,
                                     webArea: { pagina = $0 })
        let ax = TestoSchermo.righe(visita.testi)
        let msAX = SensoreSchermo.ms(da: t0)
        costi.aggiungi(fonte: "ax", ms: msAX)
        let troncatoAX = visita.troncato || ax.troncato
        if ax.righe.count >= TestoSchermo.righeMinimeAX || !f.ocr {
            consegna(f, fonte: "ax", ms: msAX, righe: ax.righe, troncato: troncatoAX)
            return
        }
        guard pianificatore.ocrAmmesso(ts: f.ts) else {
            consegna(f, fonte: "ax", ms: msAX, righe: ax.righe, troncato: troncatoAX)
            pianificatore.ocrPendente = true
            return
        }
        guard let cornice = LettoreAX.cornice(w),
              let id = TestoSchermo.scegliFinestra(LettoreFinestre.elenco(), pid: s.pid, cornice: cornice) else {
            segnala("finestra_non_trovata", stato: "degradato", dettaglio: "ocr: finestra da catturare non trovata per " + app.bundle)
            consegna(f, fonte: "ax", ms: msAX, righe: ax.righe, troncato: troncatoAX)
            return
        }
        // Browser: l'OCR tiene solo la pagina. Senza la cornice della pagina, niente OCR.
        var ritaglio: CGRect?
        if browser {
            guard let p = pagina, let area = LettoreAX.cornice(p),
                  let r = TestoSchermo.ritaglioNormalizzato(finestra: cornice, area: area) else {
                consegna(f, fonte: "ax", ms: msAX, righe: ax.righe, troncato: troncatoAX)
                return
            }
            ritaglio = r
        }
        avviaOCR(f, finestra: id, cornice: cornice, ritaglio: ritaglio, msAX: msAX, ax: ax, troncatoAX: troncatoAX)
    }

    /// La finestra letta è quella che l'Annotatore conosce: stesso elemento e stesso titolo pulito.
    private func stessaFinestra(_ w: AXUIElement, _ fin: OggettoRif, _ nota: AXUIElement?) -> Bool {
        if let n = nota, !CFEqual(n, w) { return false }
        guard let t = AX.stringa(w, kAXTitleAttribute), !t.isEmpty else { return false }
        return dip.redattore.pulisciTitolo(t) == fin.etichetta
    }

    private func accendiElectron(pid: pid_t, elemento: AXUIElement, bundle: String) {
        guard !electronAccesi.contains(pid) else { return }
        if electronAccesi.count > 200 { electronAccesi.removeAll() }
        electronAccesi.insert(pid)
        let esito = AXUIElementSetAttributeValue(elemento, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        dip.registro.salute(sensore: "schermo", stato: esito == .success ? "ok" : "degradato",
                            dettaglio: "AXManualAccessibility " + (esito == .success ? "acceso" : "rifiutato") + " per " + bundle)
    }

    // MARK: OCR (coda -> codaOCR -> coda)

    private func avviaOCR(_ f: Foto, finestra id: UInt32, cornice: CGRect, ritaglio: CGRect?, msAX: Int, ax: RigheSchermo, troncatoAX: Bool) {
        ocrInVolo = true
        ocrAvviatoTs = f.ts
        ocrGenerazione += 1
        let generazione = ocrGenerazione
        pianificatore.ocrAvviato(ts: f.ts)
        let accurate = livello.scegliAccurate()
        let t0 = DispatchTime.now().uptimeNanoseconds
        Cattura.finestra(id, cornice: cornice) { [weak self] immagine in
            guard let self = self else { return }
            self.codaOCR.async {
                // L'immagine vive solo dentro questo blocco: niente copie, niente disco.
                let voci: [String]? = immagine.flatMap { OCR.righe($0, accurate: accurate, ritaglio: ritaglio) }
                let ms = SensoreSchermo.ms(da: t0)
                self.coda.async {
                    self.ocrFinito(f, generazione: generazione, voci: voci, catturata: immagine != nil, msOCR: ms,
                                   accurate: accurate, msAX: msAX, ax: ax, troncatoAX: troncatoAX)
                }
            }
        }
    }

    private func ocrFinito(_ f: Foto, generazione: Int, voci: [String]?, catturata: Bool, msOCR: Int, accurate: Bool,
                           msAX: Int, ax: RigheSchermo, troncatoAX: Bool) {
        guard generazione == ocrGenerazione, !fermo else { return }
        ocrInVolo = false
        if voci != nil {
            livello.misura(ms: msOCR, accurate: accurate)
            ultimoFast = !accurate
            costi.aggiungi(fonte: "ocr", ms: msAX + msOCR)
        } else {
            segnala("ocr_errore", stato: "guasto", dettaglio: catturata ? "ocr: Vision non ha letto l'immagine" : "ocr: cattura della finestra non riuscita")
        }
        // Durante l'OCR la finestra può essere cambiata: si controlla di nuovo, dal vivo.
        let s = f.stato
        guard let fin = s.finestra else { return }
        let elApp = AXUIElementCreateApplication(s.pid)
        AXUIElementSetMessagingTimeout(elApp, LettoreAX.timeout)
        guard let w = LettoreAX.finestraAFuoco(elApp), stessaFinestra(w, fin, dip.contesto.leggi().finestraAX) else {
            pianificatore.rinvia(ts: oraMs())
            return
        }
        if let v = voci {
            let r = TestoSchermo.righe(v)
            if r.righe.count >= ax.righe.count && !r.righe.isEmpty {
                consegna(f, fonte: "ocr", ms: msAX + msOCR, righe: r.righe, troncato: r.troncato)
                return
            }
        }
        consegna(f, fonte: "ax", ms: msAX, righe: ax.righe, troncato: troncatoAX)
    }

    // MARK: Consegna (coda)

    private func consegna(_ f: Foto, fonte: String, ms: Int, righe: [String], troncato: Bool) {
        let ora = dip.contesto.leggi()
        guard ora.pid == f.stato.pid, ora.finestra?.valore == f.stato.finestra?.valore,
              ora.esito == .pieno, !ora.pausa, !ora.inattivo, let k = chiave(f.stato) else {
            pianificatore.rinvia(ts: oraMs())
            return
        }
        pianificatore.letto(ts: f.ts)
        guard !righe.isEmpty, elabora.nuove(chiave: k, righe: righe) != nil else { return }
        // L'Annotatore rifà i filtri con secure input dal vivo; il Registro redige ogni riga.
        dip.annotatore.schermo(fonte: fonte, ms: ms, righe: righe, troncato: troncato, ts: f.ts)
    }

    // MARK: Manutenzione (coda)

    private func manutenzione(_ ts: Int64) {
        let g = Registro.giornoDi(ts)
        if g.data != giorno {
            let primo = giorno.isEmpty
            giorno = g.data
            inizioGiorno = g.inizio
            pesoGiorno = nil
            ultimoControlloPeso = Int64.min / 4
            if !primo && pianificatore.fattore != 1 {
                pianificatore.fattore = 1
                dip.registro.salute(sensore: "schermo", stato: "ok",
                                    dettaglio: "nuovo giorno: intervallo \(pianificatore.intervallo / 1000) s")
            }
        }
        if ts - ultimoControlloPeso >= SensoreSchermo.controlloPeso {
            ultimoControlloPeso = ts
            if let p = misuraPeso(da: inizioGiorno) {
                pesoGiorno = p
                let k = TestoSchermo.fattoreRiduzione(pesoByte: p)
                if k > pianificatore.fattore {
                    pianificatore.fattore = k
                    dip.registro.salute(sensore: "schermo", stato: "degradato",
                                        dettaglio: "peso del giorno \(p / 1_000_000) MB oltre \(TestoSchermo.sogliaPeso / 1_000_000) MB: intervallo \(pianificatore.intervallo / 1000) s")
                }
            }
        }
        if ts - ultimaSaluteCosti >= SensoreSchermo.saluteCosti {
            ultimaSaluteCosti = ts
            dip.registro.salute(sensore: "schermo", stato: pianificatore.fattore > 1 ? "degradato" : "ok",
                                dettaglio: costi.descrizione(intervallo: pianificatore.intervallo, pesoByte: pesoGiorno, livelloFast: ultimoFast))
            costi = MediaCosti()
        }
        if ocrInVolo && ts - ocrAvviatoTs > SensoreSchermo.ocrScaduto {
            ocrInVolo = false
            ocrGenerazione += 1
            dip.registro.salute(sensore: "ocr", stato: "guasto", dettaglio: "ocr senza risposta da 30 s: turno liberato")
        }
    }

    /// Stima del peso del giorno: testi delle righe nuove, istantanee ed eventi da mezzanotte.
    private func misuraPeso(da inizio: Int64) -> Int64? {
        let letto: Int64?? = try? dip.registro.leggi { d -> Int64 in
            let righe = try d.intero("SELECT COALESCE(SUM(LENGTH(testo_z)), 0) + COUNT(*) * 64 FROM riga WHERE prima_ts >= ?", [inizio]) ?? 0
            let schermi = try d.intero("SELECT COALESCE(SUM(LENGTH(aggiunte) + LENGTH(tolte)), 0) + COUNT(*) * 48 FROM schermo WHERE ts >= ?", [inizio]) ?? 0
            let eventi = try d.intero("SELECT COALESCE(SUM(LENGTH(COALESCE(dettaglio, ''))), 0) + COUNT(*) * 48 FROM evento WHERE ts >= ?", [inizio]) ?? 0
            return righe + schermi + eventi
        }
        return letto ?? nil
    }

    /// Una riga in salute quando la scelta sul testo delle finestre cambia (sensore facoltativo "testo").
    private func aggiornaStatoTesto(_ f: Foto) {
        guard f.testoSchermo != statoTesto else { return }
        statoTesto = f.testoSchermo
        dip.registro.salute(sensore: "testo", stato: f.testoSchermo ? "ok" : "spento",
                            dettaglio: f.testoSchermo ? "legge il testo delle finestre" : "impostazione testo_schermo falsa: niente testo delle finestre")
    }

    private func aggiornaStatoOCR(_ f: Foto) {
        let nuovo: String
        if !f.ocrRichiesto {
            nuovo = "spento"
        } else if !f.permessoSchermo {
            nuovo = "degradato"
        } else {
            nuovo = "ok"
        }
        guard nuovo != statoOCR else { return }
        let primo = statoOCR == nil
        statoOCR = nuovo
        switch nuovo {
        case "spento":
            dip.registro.salute(sensore: "ocr", stato: "spento", dettaglio: "impostazione ocr falsa: solo testo AX")
        case "degradato":
            dip.registro.salute(sensore: "ocr", stato: "degradato", dettaglio: "manca il permesso Registrazione schermo: solo testo AX")
            dip.registro.meta("permesso_schermo", "0")
        default:
            dip.registro.salute(sensore: "ocr", stato: "ok", dettaglio: primo ? "pronto" : "permesso Registrazione schermo presente")
            dip.registro.meta("permesso_schermo", "1")
        }
    }

    /// Una riga in salute per motivo, al massimo ogni 10 minuti.
    private func segnala(_ motivo: String, stato: String, dettaglio: String) {
        let ts = oraMs()
        if let u = segnalati[motivo], ts - u < 600_000 { return }
        segnalati[motivo] = ts
        dip.registro.salute(sensore: "schermo", stato: stato, dettaglio: dettaglio)
    }

    static func ms(da t0: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000)
    }
}

// MARK: - Letture AX per la visita

enum LettoreAX {
    /// Timeout di ogni chiamata AX: un'app bloccata non tiene ferma la visita oltre il budget.
    static let timeout: Float = 0.05
    static let figliMassimi = 300
    static let caratteriCampo = 20_000

    static func finestraAFuoco(_ app: AXUIElement) -> AXUIElement? {
        guard let w = AX.elemento(app, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(w, timeout)
        return w
    }

    /// Ruolo e subruolo in una sola chiamata. Nessun valore: quello si chiede dopo il filtro.
    static func struttura(_ el: AXUIElement) -> (ruolo: String?, subruolo: String?)? {
        AXUIElementSetMessagingTimeout(el, timeout)
        let v = multipli(el, [kAXRoleAttribute, kAXSubroleAttribute])
        guard let ruolo = stringa(v.first ?? nil) else { return nil }
        return (ruolo, stringa(v.count > 1 ? v[1] : nil))
    }

    /// Figli da visitare: per tabelle e liste solo quelli visibili, sempre al massimo 300.
    static func figli(_ el: AXUIElement, _ ruolo: String) -> [AXUIElement] {
        if ruolo == "AXTable" || ruolo == "AXOutline" {
            if let r = elementi(el, kAXVisibleRowsAttribute) { return Array(r.prefix(figliMassimi)) }
        }
        if ruolo == "AXList" || ruolo == "AXBrowser" {
            if let r = elementi(el, kAXVisibleChildrenAttribute) { return Array(r.prefix(figliMassimi)) }
        }
        var n: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(el, kAXChildrenAttribute as CFString, &n) == .success, n > 0 else { return [] }
        var arr: CFArray?
        guard AXUIElementCopyAttributeValues(el, kAXChildrenAttribute as CFString, 0, min(n, figliMassimi), &arr) == .success,
              let lista = arr as [AnyObject]? else { return [] }
        return lista.compactMap { o in CFGetTypeID(o) == AXUIElementGetTypeID() ? (o as! AXUIElement) : nil }
    }

    /// Testo di un nodo già filtrato. Aree e campi di testo: solo la parte visibile.
    static func testo(_ el: AXUIElement, _ ruolo: String) -> String? {
        if ruolo == "AXTextArea" || VisitaAX.ruoliCampo.contains(ruolo) {
            if let s = visibile(el) { return s }
            var n: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success,
               let num = n, CFGetTypeID(num) == CFNumberGetTypeID(), ((num as! NSNumber).intValue) > caratteriCampo {
                return nil
            }
            return AX.stringa(el, kAXValueAttribute).map { String($0.prefix(caratteriCampo)) }
        }
        for v in multipli(el, [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]) {
            if let s = stringa(v), !s.isEmpty { return s }
        }
        return nil
    }

    /// Testo nel rettangolo visibile di un'area di testo (AXVisibleCharacterRange).
    private static func visibile(_ el: AXUIElement) -> String? {
        guard let v = AX.valore(el, kAXVisibleCharacterRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r), r.length > 0 else { return nil }
        var limitato = CFRange(location: r.location, length: min(r.length, caratteriCampo))
        guard let arg = AXValueCreate(.cfRange, &limitato) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, arg, &out) == .success,
              let s = out, CFGetTypeID(s) == CFStringGetTypeID() else { return nil }
        return (s as! CFString) as String
    }

    /// Posizione e dimensione della finestra, in punti con origine in alto a sinistra.
    static func cornice(_ w: AXUIElement) -> CGRect? {
        guard let p = AX.valore(w, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let d = AX.valore(w, kAXSizeAttribute), CFGetTypeID(d) == AXValueGetTypeID() else { return nil }
        var punto = CGPoint.zero
        var misura = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &punto), AXValueGetValue(d as! AXValue, .cgSize, &misura),
              misura.width > 40, misura.height > 40 else { return nil }
        return CGRect(origin: punto, size: misura)
    }

    private static func multipli(_ el: AXUIElement, _ nomi: [String]) -> [CFTypeRef?] {
        var v: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, nomi as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
              let lista = v as [AnyObject]? else { return [] }
        return lista.map { $0 as CFTypeRef }
    }

    private static func stringa(_ v: CFTypeRef?) -> String? {
        guard let v = v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }

    private static func elementi(_ el: AXUIElement, _ nome: String) -> [AXUIElement]? {
        guard let v = AX.valore(el, nome), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        let lista = (v as! CFArray) as [AnyObject]
        return lista.compactMap { o in CFGetTypeID(o) == AXUIElementGetTypeID() ? (o as! AXUIElement) : nil }
    }
}

// MARK: - Finestre, cattura e OCR

enum LettoreFinestre {
    /// Finestre a schermo, dalla più in alto. Senza permesso schermo mancano i nomi: non servono.
    static func elenco() -> [VoceFinestra] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let livello = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let b = d[kCGWindowBounds as String] as? NSDictionary,
                  let cornice = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return VoceFinestra(id: id, pid: pid, livello: livello, cornice: cornice)
        }
    }
}

enum Cattura {
    /// Lato lungo massimo dell'immagine in pixel: tiene basso il costo dell'OCR.
    static let latoMassimo: CGFloat = 2400

    /// Immagine della sola finestra `id`, in memoria. fatto si chiama una volta, su una coda qualunque.
    static func finestra(_ id: UInt32, cornice: CGRect, fatto: @escaping (CGImage?) -> Void) {
        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { contenuto, _ in
                guard let w = contenuto?.windows.first(where: { $0.windowID == id }) else {
                    fatto(nil)
                    return
                }
                let filtro = SCContentFilter(desktopIndependentWindow: w)
                let conf = SCStreamConfiguration()
                let scala = CGFloat(filtro.pointPixelScale)
                var larghezza = w.frame.width * scala
                var altezza = w.frame.height * scala
                let lato = max(larghezza, altezza)
                if lato > latoMassimo {
                    larghezza *= latoMassimo / lato
                    altezza *= latoMassimo / lato
                }
                conf.width = max(1, Int(larghezza))
                conf.height = max(1, Int(altezza))
                conf.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filtro, configuration: conf) { immagine, _ in
                    fatto(immagine)
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                fatto(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(id), [.boundsIgnoreFraming, .bestResolution]))
            }
        }
    }
}

enum OCR {
    static let lingue = ["it-IT", "en-US"]
    static let fiduciaMinima: Float = 0.3

    /// Righe riconosciute, in ordine di lettura. nil se Vision non riesce.
    /// ritaglio: solo le voci dentro questa cornice normalizzata (la pagina di un browser).
    static func righe(_ immagine: CGImage, accurate: Bool, ritaglio: CGRect? = nil) -> [String]? {
        if let r = prova(immagine, accurate: accurate, lingue: lingue, ritaglio: ritaglio) { return r }
        // Il livello fast di alcune versioni non accetta l'italiano: si riprova con le lingue di default.
        return prova(immagine, accurate: accurate, lingue: nil, ritaglio: ritaglio)
    }

    private static func prova(_ immagine: CGImage, accurate: Bool, lingue: [String]?, ritaglio: CGRect?) -> [String]? {
        let richiesta = VNRecognizeTextRequest()
        richiesta.recognitionLevel = accurate ? .accurate : .fast
        richiesta.usesLanguageCorrection = accurate
        richiesta.preferBackgroundProcessing = true
        if let l = lingue { richiesta.recognitionLanguages = l }
        let gestore = VNImageRequestHandler(cgImage: immagine, options: [:])
        do {
            try gestore.perform([richiesta])
        } catch {
            return nil
        }
        let voci: [VoceOCR] = (richiesta.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= fiduciaMinima else { return nil }
            let b = o.boundingBox
            return VoceOCR(testo: c.string, x: Double(b.minX), y: Double(b.minY), altezza: Double(b.height))
        }
        return TestoSchermo.ordinaOCR(TestoSchermo.dentroRitaglio(voci, ritaglio))
    }
}
