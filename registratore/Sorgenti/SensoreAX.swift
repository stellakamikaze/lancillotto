// SensoreAX.swift: finestra a fuoco, titolo, documento, URL dei browser ed elemento a fuoco.
//
//   NSWorkspace -> SensoreApp -> .lancillottoAppAttiva -> SensoreAX.aggancia(pid)
//   AXObserver(pid): FocusedWindowChanged, MainWindowChanged, FocusedUIElementChanged,
//                    TitleChanged (sull'app e sulla finestra a fuoco)
//        -> lettura dopo 150 ms (le notifiche arrivano a raffica) -> Annotatore
//   ombra: AXIsProcessTrusted() falso -> niente observer, salute "degradato",
//          controllo ogni 5 s; resta attivo solo SensoreApp.
//   ombra: URL del browser non trovato -> salute "url_assente" (una volta ogni 10 minuti per app),
//          nuova lettura dopo 1 s (al massimo 3 per titolo); intanto il filtro dà escluso "dubbio".
//   Firefox: senza un lettore di schermo la finestra non ha figli AX (sonda del 25/10/2026: 0 figli,
//          ogni finestra esclusa "dubbio"). Si accende AXEnhancedUserInterface sull'app, una volta
//          per pid: l'albero arriva in circa 1 s e la nuova lettura trova l'URL (89 nodi, 30 ms).
//
// Timeout AX: 0,25 s per chiamata. La ricerca nell'albero ha un tetto di nodi e di tempo.
// Il valore di un campo si legge solo all'uscita, mai da un AXSecureTextField, mai dalla barra
// degli indirizzi e mai da un campo con l'etichetta di un segreto (password, PIN, CVV, OTP).
// Al cambio di finestra il campo aperto si chiude PRIMA di passare la finestra nuova all'Annotatore:
// così il suo valore si filtra con la finestra in cui è stato scritto.

import AppKit
import ApplicationServices
import Foundation

final class SensoreAX: NSObject, Sensore {
    let dip: Dipendenze
    private var osservatore: AXObserver?
    private var elementoApp: AXUIElement?
    private var pid: pid_t = 0
    private var finestraOsservata: AXUIElement?
    private var controlloPermesso: Timer?
    private var attivo = false
    private var degradatoSegnalato = false
    private var letturaFinestra: DispatchWorkItem?
    private var letturaFocus: DispatchWorkItem?
    private var urlAssenteSegnalato: [String: Int64] = [:]
    private var tentativiURL = 0
    private var titoloSenzaURL: String?
    private var alberiAccesi: Set<pid_t> = []
    /// Browser che costruiscono l'albero AX solo se qualcuno lo chiede (AXManualAccessibility qui non vale).
    static let alberoSuRichiesta: Set<String> = ["org.mozilla.firefox"]

    private struct CampoAperto {
        let elemento: AXUIElement
        let finestra: AXUIElement?
        let ruolo: String
        let subruolo: String?
        let etichetta: String?
        let barraIndirizzi: Bool
        let da: Int64
    }
    private var campoAperto: CampoAperto?

    static var browser: Set<String> { Esclusioni.browser }
    static let segniBarraIndirizzi: [String] = [
        "address and search bar", "barra degli indirizzi", "barra indirizzi", "address bar",
        "indirizzo e ricerca", "web_browser_address_and_search_field", "smart search field", "urlbar", "location",
        "inserisci un indirizzo", "enter address",
    ]

    init(dip: Dipendenze) {
        self.dip = dip
        super.init()
    }

    func avvia() {
        NotificationCenter.default.addObserver(self, selector: #selector(appAttiva(_:)), name: .lancillottoAppAttiva, object: nil)
        let t = Timer(timeInterval: 5, target: self, selector: #selector(controllaPermesso), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        controlloPermesso = t
        controllaPermesso()
    }

    func ferma() {
        NotificationCenter.default.removeObserver(self)
        controlloPermesso?.invalidate()
        controlloPermesso = nil
        sgancia()
        attivo = false
    }

    @objc private func controllaPermesso() {
        let fidato = AXIsProcessTrusted()
        if fidato && !attivo {
            attivo = true
            degradatoSegnalato = false
            dip.contesto.modifica { $0.permessoAX = true }
            dip.registro.meta("permesso_ax", "1")
            dip.registro.salute(sensore: "ax", stato: "ok")
            if let app = NSWorkspace.shared.frontmostApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                aggancia(app.processIdentifier)
            }
        } else if !fidato {
            if !degradatoSegnalato {
                degradatoSegnalato = true
                dip.registro.meta("permesso_ax", "0")
                dip.registro.salute(sensore: "ax", stato: "degradato", dettaglio: "Accessibilità non concessa: solo app e durata")
            }
            if attivo {
                attivo = false
                sgancia()
            }
            dip.contesto.modifica { $0.permessoAX = false }
        }
    }

    @objc private func appAttiva(_ n: Notification) {
        guard attivo, let p = n.userInfo?["pid"] as? Int32 else { return }
        aggancia(p)
    }

    // MARK: Observer

    private func aggancia(_ nuovoPid: pid_t) {
        sgancia()
        pid = nuovoPid
        campoAperto = nil
        let el = AXUIElementCreateApplication(nuovoPid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        elementoApp = el
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, elemento, notifica, refcon in
            guard let refcon = refcon else { return }
            let s = Unmanaged<SensoreAX>.fromOpaque(refcon).takeUnretainedValue()
            s.notifica(notifica as String, elemento)
        }
        guard AXObserverCreate(nuovoPid, callback, &obs) == .success, let o = obs else {
            dip.registro.salute(sensore: "ax", stato: "degradato", dettaglio: "AXObserverCreate non riuscito")
            programmaFinestra()
            return
        }
        osservatore = o
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(o, el, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        programmaFinestra()
        programmaFocus()
    }

    private func sgancia() {
        if let o = osservatore {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        }
        osservatore = nil
        elementoApp = nil
        finestraOsservata = nil
        letturaFinestra?.cancel()
        letturaFocus?.cancel()
    }

    fileprivate func notifica(_ nome: String, _ elemento: AXUIElement) {
        switch nome {
        case kAXFocusedUIElementChangedNotification:
            programmaFocus()
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            programmaFinestra()
            programmaFocus()
        default:
            programmaFinestra()
        }
    }

    private func programmaFinestra(dopo: Double = 0.15) {
        letturaFinestra?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.leggiFinestra() }
        letturaFinestra = w
        DispatchQueue.main.asyncAfter(deadline: .now() + dopo, execute: w)
    }

    private func programmaFocus() {
        letturaFocus?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.leggiFocus() }
        letturaFocus = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    // MARK: Letture

    private func leggiFinestra() {
        guard let app = elementoApp else { return }
        let ts = oraMs()
        let bundle = dip.contesto.leggi().app?.bundle ?? ""
        guard let finestra = AX.elemento(app, kAXFocusedWindowAttribute) else {
            chiudiCampo(ts)
            dip.annotatore.cambiaFinestra(titolo: nil, url: nil, documento: nil, ts: ts)
            return
        }
        // Il campo aperto sta in un'altra finestra: si chiude adesso, con la finestra vecchia ancora nota.
        if let c = campoAperto, c.finestra.map({ !CFEqual($0, finestra) }) ?? true {
            chiudiCampo(ts)
        }
        // Notifica del titolo anche sulla finestra: alcune app non la mandano all'elemento app.
        if let o = osservatore, finestraOsservata.map({ !CFEqual($0, finestra) }) ?? true {
            if let vecchia = finestraOsservata {
                AXObserverRemoveNotification(o, vecchia, kAXTitleChangedNotification as CFString)
            }
            AXObserverAddNotification(o, finestra, kAXTitleChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            finestraOsservata = finestra
        }
        dip.contesto.modifica { $0.finestraAX = finestra }
        let titolo = AX.stringa(finestra, kAXTitleAttribute)
        var attributi: [String: String] = [:]
        for nome in [kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute] {
            if let v = AX.stringa(finestra, nome) { attributi[nome] = v }
        }
        var documento: InfoFile?
        if let d = AX.stringa(finestra, kAXDocumentAttribute), let path = SensoreAX.pathDaDocumento(d) {
            documento = InfoFile.leggi(path)
        }
        var url: String?
        if SensoreAX.browser.contains(bundle) {
            if SensoreAX.alberoSuRichiesta.contains(bundle) { accendiAlbero(bundle) }
            let letto = leggiURL(finestra)
            url = letto.url
            if letto.privata { attributi["privata"] = "1" }
            if url == nil {
                segnalaURLAssente(bundle, ts)
                // Pagina in caricamento o albero AX ancora povero: si riprova, poche volte per titolo.
                if titoloSenzaURL != titolo { titoloSenzaURL = titolo; tentativiURL = 0 }
                if tentativiURL < 3 {
                    tentativiURL += 1
                    programmaFinestra(dopo: 1.0)
                }
            } else {
                titoloSenzaURL = nil
                tentativiURL = 0
            }
        }
        dip.annotatore.cambiaFinestra(titolo: titolo, url: url, documento: documento, attributi: attributi, ts: ts)
    }

    /// Uscita dal campo aperto: valore letto solo ora, e solo se il campo non è protetto, non è la
    /// barra degli indirizzi e non chiede un segreto.
    private func chiudiCampo(_ ts: Int64) {
        guard let c = campoAperto else { return }
        campoAperto = nil
        if c.subruolo == "AXSecureTextField" || c.ruolo == "AXSecureTextField" { return }
        // Con valori_campi spento il valore non si legge proprio, non solo non si salva.
        let leggibile = dip.annotatore.valoriCampi && !c.barraIndirizzi && !RegoleFiltro.campoSensibile(c.etichetta)
        let valore = leggibile ? AX.stringa(c.elemento, kAXValueAttribute) : nil
        dip.annotatore.campoValore(ruolo: c.ruolo, subruolo: c.subruolo, etichetta: c.etichetta,
                                   valore: valore, durMs: ts - c.da, ts: ts)
    }

    private func leggiFocus() {
        guard let app = elementoApp else { return }
        let ts = oraMs()
        let el = AX.elemento(app, kAXFocusedUIElementAttribute)
        if let el = el, let aperto = campoAperto, CFEqual(el, aperto.elemento) { return }
        // Uscita dal campo precedente.
        chiudiCampo(ts)
        guard let e = el else {
            dip.annotatore.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: ts)
            return
        }
        let ruolo = AX.stringa(e, kAXRoleAttribute)
        let subruolo = AX.stringa(e, kAXSubroleAttribute)
        let etichetta = SensoreAX.etichetta(e)
        dip.annotatore.cambiaFocus(ruolo: ruolo, subruolo: subruolo, etichetta: etichetta, ts: ts)
        // Un campo in una finestra esclusa, privata o protetta non si apre: il suo valore non si legge.
        if let r = ruolo, Annotatore.ruoliTesto.contains(r), dip.annotatore.esitoAttuale() == .pieno {
            campoAperto = CampoAperto(elemento: e, finestra: AX.elemento(app, kAXFocusedWindowAttribute), ruolo: r,
                                      subruolo: subruolo, etichetta: etichetta,
                                      barraIndirizzi: SensoreAX.barraIndirizzi(e), da: ts)
        }
    }

    /// Il campo è la barra degli indirizzi di un browser (dagli identificatori noti).
    static func barraIndirizzi(_ el: AXUIElement) -> Bool {
        let segni = [AX.stringa(el, kAXIdentifierAttribute), AX.stringa(el, kAXDescriptionAttribute),
                     AX.stringa(el, kAXTitleAttribute)].compactMap { $0?.lowercased() }
        return segni.contains(where: { s in SensoreAX.segniBarraIndirizzi.contains { s.contains($0) } })
    }

    /// Etichetta di un elemento: AXTitle, AXDescription, AXPlaceholderValue o il titolo dell'AXTitleUIElement.
    static func etichetta(_ e: AXUIElement) -> String? {
        for nome in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
            if let v = AX.stringa(e, nome), !v.isEmpty { return String(v.prefix(100)) }
        }
        if let t = AX.elemento(e, kAXTitleUIElementAttribute) {
            if let v = AX.stringa(t, kAXValueAttribute) ?? AX.stringa(t, kAXTitleAttribute), !v.isEmpty {
                return String(v.prefix(100))
            }
        }
        return nil
    }

    /// Ultima AXWebArea trovata, con la sua finestra. Si riusa solo se la descrizione della pagina
    /// apre ancora il titolo della finestra: una scheda cambiata non eredita l'URL di quella vecchia.
    private var ultimaPagina: (finestra: AXUIElement, area: AXUIElement, privata: Bool)?

    /// Puro, testato dal selftest: la pagina ricordata vale ancora per questo titolo di finestra.
    static func paginaValida(descrizione: String?, titolo: String?) -> Bool {
        guard let d = descrizione?.trimmingCharacters(in: .whitespaces), d.count >= 3,
              let t = titolo else { return false }
        return t.hasPrefix(d)
    }

    /// URL della scheda attiva: prima AXURL o AXDocument della AXWebArea, poi la barra indirizzi.
    /// privata: un elemento fuori dalla pagina (barra, pulsanti) porta un segno di navigazione privata.
    /// Firefox risponde lento: 65 nodi chiedono 90-130 ms (sonda del 25/10/2026), quindi il tetto è 300 ms.
    private func leggiURL(_ finestra: AXUIElement) -> (url: String?, privata: Bool) {
        if let p = ultimaPagina, CFEqual(p.finestra, finestra),
           SensoreAX.paginaValida(descrizione: AX.stringa(p.area, kAXDescriptionAttribute),
                                  titolo: AX.stringa(finestra, kAXTitleAttribute)),
           let u = AX.url(p.area, "AXURL") {
            return (u, p.privata)   // una finestra non cambia da normale a privata
        }
        ultimaPagina = nil
        let scadenza = DispatchTime.now().uptimeNanoseconds + 300_000_000
        var webArea: AXUIElement?
        var barra: AXUIElement?
        var privata = false
        var coda: [(AXUIElement, Int)] = [(finestra, 0)]
        var visitati = 0
        while !coda.isEmpty && visitati < 400 && DispatchTime.now().uptimeNanoseconds < scadenza {
            let (el, profondita) = coda.removeFirst()
            visitati += 1
            let ruolo = AX.stringa(el, kAXRoleAttribute) ?? ""
            if ruolo == "AXWebArea" {
                if webArea == nil { webArea = el }
                continue   // dentro la pagina non serve scendere
            }
            if barra == nil && (ruolo == "AXTextField" || ruolo == "AXComboBox") {
                if SensoreAX.barraIndirizzi(el) { barra = el }
            }
            if !privata {
                let segni = [AX.stringa(el, kAXIdentifierAttribute), AX.stringa(el, kAXDescriptionAttribute),
                             AX.stringa(el, kAXPlaceholderValueAttribute)].compactMap { $0?.lowercased() }
                if segni.contains(where: { s in Esclusioni.segniPrivata.contains { s.contains($0) } }) { privata = true }
            }
            if webArea != nil && barra != nil { break }
            if profondita < 20, let figli = AX.figli(el) {
                for f in figli { coda.append((f, profondita + 1)) }
            }
        }
        if let w = webArea {
            if let u = AX.url(w, "AXURL") { ultimaPagina = (finestra, w, privata); return (u, privata) }
            if let d = AX.stringa(w, kAXDocumentAttribute), !d.isEmpty { return (d, privata) }
        }
        if let b = barra, let v = AX.stringa(b, kAXValueAttribute), !v.isEmpty { return (v, privata) }
        return (nil, privata)
    }

    /// Una volta per pid: Firefox costruisce l'albero AX solo con AXEnhancedUserInterface acceso.
    /// L'esito del set non conta (Firefox risponde -25208 e accende lo stesso): conta il valore riletto.
    private func accendiAlbero(_ bundle: String) {
        guard pid > 0, let app = elementoApp, !alberiAccesi.contains(pid) else { return }
        if alberiAccesi.count > 200 { alberiAccesi.removeAll() }
        alberiAccesi.insert(pid)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var v: CFTypeRef?
        let acceso = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &v) == .success
            && (v as? Bool) == true
        dip.registro.salute(sensore: "ax", stato: acceso ? "ok" : "degradato",
                            dettaglio: "AXEnhancedUserInterface " + (acceso ? "acceso" : "rifiutato") + " per " + bundle)
    }

    private func segnalaURLAssente(_ bundle: String, _ ts: Int64) {
        if let ultimo = urlAssenteSegnalato[bundle], ts - ultimo < 600_000 { return }
        urlAssenteSegnalato[bundle] = ts
        dip.registro.salute(sensore: "ax", stato: "degradato", dettaglio: "url_assente " + bundle)
    }

    static func pathDaDocumento(_ d: String) -> String? {
        if d.hasPrefix("/") { return d }
        guard let u = URL(string: d), u.isFileURL else { return nil }
        return u.path
    }
}

/// Lettura degli attributi AX con controllo del tipo.
enum AX {
    static func valore(_ el: AXUIElement, _ nome: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, nome as CFString, &v) == .success else { return nil }
        return v
    }

    static func stringa(_ el: AXUIElement, _ nome: String) -> String? {
        guard let v = valore(el, nome), CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
        return (v as! CFString) as String
    }

    static func elemento(_ el: AXUIElement, _ nome: String) -> AXUIElement? {
        guard let v = valore(el, nome), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func url(_ el: AXUIElement, _ nome: String) -> String? {
        guard let v = valore(el, nome) else { return nil }
        if CFGetTypeID(v) == CFURLGetTypeID() { return ((v as! CFURL) as URL).absoluteString }
        if CFGetTypeID(v) == CFStringGetTypeID() { return (v as! CFString) as String }
        return nil
    }

    static func figli(_ el: AXUIElement) -> [AXUIElement]? {
        guard let v = valore(el, kAXChildrenAttribute), CFGetTypeID(v) == CFArrayGetTypeID() else { return nil }
        let lista = (v as! CFArray) as [AnyObject]
        return lista.compactMap { o in
            CFGetTypeID(o) == AXUIElementGetTypeID() ? (o as! AXUIElement) : nil
        }
    }
}
