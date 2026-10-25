// Annotatore.swift: il passaggio unico fra ciò che un sensore osserva e ciò che va nel registro.
//
//   sensore ──osservazione──> Annotatore ──Osservazione──> Filtri.decidi
//                                  │                           │
//                                  │  pieno    -> evento completo (titolo, URL, documento, campi...)
//                                  │  escluso  -> solo tratto "escluso" (app e durata)
//                                  │  protetto -> solo tratto "protetto"
//                                  │  scarta   -> niente (pausa)
//                                  v
//                              Registro (che ripassa ogni testo dal Redattore)
//
// Tratti: il tempo in primo piano è un evento `finestra` (o `escluso`, `protetto`) che si
// allunga col battito. Se app, finestra e tipo sono uguali entro 30 s dalla fine del tratto
// precedente, il tratto si riapre invece di crearne uno nuovo (fusione del contratto).
// Inattività, sonno e blocco chiudono il tratto; la pausa lo chiude e scarta tutto.
//
// Lo usano i sensori veri e lo scenario sintetico: così lo scenario passa dagli stessi
// filtri e dallo stesso redattore del registratore in uso.

import Foundation

/// Informazioni di un file, lette dal sensore (o scritte dallo scenario).
struct InfoFile: Equatable {
    var path: String
    var inode: Int64? = nil
    var provenienza: String? = nil

    /// Legge inode e provenienza (kMDItemWhereFroms) senza aprire il file.
    /// I container di altre app non si toccano: macOS chiederebbe un permesso.
    static func leggi(_ path: String, home: String = NSHomeDirectory()) -> InfoFile {
        var info = InfoFile(path: path)
        if path.hasPrefix(home + "/Library/") { return info }
        var st = stat()
        if lstat(path, &st) == 0 { info.inode = Int64(bitPattern: UInt64(st.st_ino)) }
        info.provenienza = provenienzaDa(path)
        return info
    }

    /// Dominio del primo URL in com.apple.metadata:kMDItemWhereFroms, senza "www.".
    static func provenienzaDa(_ path: String) -> String? {
        let nome = "com.apple.metadata:kMDItemWhereFroms"
        let n = getxattr(path, nome, nil, 0, 0, 0)
        guard n > 0, n < 64 * 1024 else { return nil }
        var dati = Data(count: n)
        let letti = dati.withUnsafeMutableBytes { getxattr(path, nome, $0.baseAddress, n, 0, 0) }
        guard letti == n,
              let lista = try? PropertyListSerialization.propertyList(from: dati, options: [], format: nil) as? [String] else {
            return nil
        }
        for voce in lista {
            if let h = URLComponents(string: voce)?.host?.lowercased(), !h.isEmpty {
                return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
            }
        }
        return nil
    }
}

final class Annotatore {
    let registro: Registro
    let filtri: Filtri
    let redattore: Redattore
    let contesto: Contesto
    let home: String
    /// IsSecureEventInputEnabled() nell'app vera; un valore fisso nello scenario.
    var secureInput: () -> Bool
    var valoriCampi = true
    /// Dalle impostazioni (testo_schermo). Seconda guardia: un OCR partito prima del cambio non scrive.
    var testoSchermo = true
    /// Motivo della prossima pausa che parte: "menu" | "fino_a_domani" | "cli" (default).
    var motivoPausa = "cli"

    static let ruoliTesto: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    static let ruoliClic: Set<String> = ["AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXLink"]
    static let finestraFusione: Int64 = 30_000
    static let attesaTitolo: Int64 = 2_000

    private struct Tratto {
        let id: Int64
        var chiave: String
        let prefisso: String      // tipo + bundle: per riconoscere il tratto ancora senza titolo
        var senzaOggetto: Bool
        let ts: Int64
        var fine: Int64
        var aperto: Bool
        var tasti: Int
        var click: Int
    }

    private let lock = NSRecursiveLock()
    private var app: AppRif?
    private var pid: Int32 = 0
    private var titolo: String?
    private var url: String?
    private var attributi: [String: String] = [:]
    private var focusRuolo: String?
    private var focusSubruolo: String?
    private var ultimoDocumento: String?
    private var ultimoURL: String?
    private var documento: String?
    private var finestraLetta = false
    private var tratto: Tratto?
    private var sospeso = false
    private var esito: Esito = .scarta
    private var pausaDa: Int64?
    /// Il campo di testo in cui è entrato il fuoco: esito, titolo e URL di quel momento.
    /// Il valore all'uscita si salva solo se allora era .pieno e la finestra è la stessa.
    private var campoIngresso: (esito: Esito, titolo: String?, url: String?, documento: String?)?
    /// Fine dell'ultimo intervallo dimenticato: un segnale con ts fino a qui arriva in ritardo
    /// (un OCR in volo, un campo lasciato dopo) e non si scrive.
    private var dimenticatoFino: Int64 = Int64.min

    init(registro: Registro, filtri: Filtri, contesto: Contesto, home: String = NSHomeDirectory(),
         secureInput: @escaping () -> Bool) {
        self.registro = registro
        self.filtri = filtri
        self.redattore = registro.redattore
        self.contesto = contesto
        self.home = home
        self.secureInput = secureInput
    }

    // MARK: Primo piano

    func cambiaApp(_ nuova: AppRif, pid: Int32, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        app = nuova
        self.pid = pid
        titolo = nil
        url = nil
        attributi = [:]
        focusRuolo = nil
        focusSubruolo = nil
        ultimoDocumento = nil
        ultimoURL = nil
        documento = nil
        finestraLetta = false
        campoIngresso = nil
        contesto.modifica {
            $0.app = nuova
            $0.pid = pid
            $0.finestra = nil
            $0.finestraAX = nil
        }
        rivaluta(ts)
    }

    /// La finestra a fuoco è cambiata, o il suo titolo, URL o documento.
    func cambiaFinestra(titolo: String?, url: String?, documento: InfoFile?, attributi: [String: String] = [:], ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        self.titolo = titolo
        self.url = url
        self.attributi = attributi
        self.documento = documento?.path
        finestraLetta = true
        rivaluta(ts)
        guard esito == .pieno, let app = app else {
            ultimoDocumento = nil
            ultimoURL = nil
            return
        }
        if let doc = documento {
            if doc.path != ultimoDocumento {
                ultimoDocumento = doc.path
                let ogg = oggettoFile(doc)
                let id = registro.evento(tipo: "documento", ts: ts, app: app, oggetto: ogg, dettaglio: ["fonte": "axdocument"])
                registro.impronte(eventoId: id, testo: (doc.path as NSString).lastPathComponent, fonte: "file")
            }
        } else {
            ultimoDocumento = nil
        }
        if let u = url, let pulito = redattore.pulisciURL(u) {
            if pulito.completo != ultimoURL {
                ultimoURL = pulito.completo
                let ogg = OggettoRif(tipo: "url", valore: pulito.completo, etichetta: pulito.etichetta, dominio: pulito.dominio)
                registro.evento(tipo: "url", ts: ts, app: app, oggetto: ogg, dettaglio: ["fonte": "ax"])
            }
        } else {
            ultimoURL = nil
        }
    }

    /// Il fuoco è passato a un altro elemento. Per i campi di testo scrive campo_focus (mai il valore).
    func cambiaFocus(ruolo: String?, subruolo: String?, etichetta: String?, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        focusRuolo = ruolo
        focusSubruolo = subruolo
        rivaluta(ts)
        if let r = ruolo, Annotatore.ruoliTesto.contains(r) {
            campoIngresso = (esito, titolo, url, documento)
        } else {
            campoIngresso = nil
        }
        guard esito == .pieno, let r = ruolo, Annotatore.ruoliTesto.contains(r) else { return }
        var d: [String: Any] = ["ruolo": r]
        if let e = etichetta, !e.isEmpty { d["etichetta"] = String(e.prefix(100)) }
        registro.evento(tipo: "campo_focus", ts: ts, app: app, oggetto: oggettoFinestra(), dettaglio: d)
    }

    /// Valore di un campo all'uscita. Il filtro guarda il ruolo del campo lasciato, non quello nuovo,
    /// e la finestra in cui il campo era quando il fuoco ci è entrato: se allora l'esito non era
    /// .pieno, o se titolo, URL o documento sono cambiati (cambio di finestra o di scheda), niente.
    /// Un campo con l'etichetta di un segreto (password, PIN, CVV, OTP) non salva il valore.
    func campoValore(ruolo: String?, subruolo: String?, etichetta: String?, valore: String?, durMs: Int64, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        let ingresso = campoIngresso
        campoIngresso = nil
        guard esitoPer(ruolo: ruolo, subruolo: subruolo, ts: ts) == .pieno, !sospeso else { return }
        guard ts - max(0, durMs) > dimenticatoFino else { return }
        #if VELENO
        _ = ingresso
        #else
        guard let ing = ingresso, ing.esito == .pieno, ing.titolo == titolo, ing.url == url,
              ing.documento == documento else { return }
        #endif
        let segreto = RegoleFiltro.campoSensibile(etichetta)
        registro.campo(ts: ts, dur: durMs, app: app, finestra: oggettoFinestra(), ruolo: ruolo,
                       etichetta: etichetta.map { String($0.prefix(100)) },
                       valore: valoriCampi && !segreto ? valore : nil)
    }

    // MARK: Segnali dentro la finestra (li usano anche i sensori di input e schermo)

    /// Clic su un bersaglio dell'app attiva. Nei browser l'etichetta fuori dalla pagina non si
    /// salva: schede, preferiti e cronologia portano il titolo di pagine anche escluse o private.
    /// Lo stesso per una scheda (AXTabButton) in qualunque app.
    func clic(ruolo: String, subruolo: String? = nil, etichetta: String?, web: Bool, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard Annotatore.ruoliClic.contains(ruolo), ts > dimenticatoFino, esitoOra(ts) == .pieno else { return }
        var d: [String: Any] = ["ruolo": ruolo]
        if web {
            d["web"] = 1
        } else if Annotatore.etichettaClicAmmessa(bundle: app?.bundle, subruolo: subruolo), let e = etichetta, !e.isEmpty {
            d["etichetta"] = String(e.prefix(100))
        }
        registro.evento(tipo: "clic", ts: ts, app: app, oggetto: oggettoFinestra(), dettaglio: d)
    }

    /// Voce di menu scelta. cc != nil per un Incolla, così l'incolla si lega alla copia come il cmd+v.
    /// Nei menu che elencano titoli di finestre e pagine (Finestra, Cronologia, Preferiti) resta
    /// solo il primo livello: una voce può nominare una pagina esclusa o una finestra privata.
    func menu(percorso: String, cc: Int? = nil, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard ts > dimenticatoFino, esitoOra(ts) == .pieno else { return }
        registro.evento(tipo: "menu", ts: ts, app: app, oggetto: oggettoFinestra(),
                        dettaglio: ["percorso": Annotatore.percorsoMenuSicuro(percorso)], cc: cc)
    }

    /// Scorciatoia con cmd o ctrl, nome canonico (es. "cmd+c"). cc = changeCount se noto.
    func comando(tasti: String, cc: Int?, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard ts > dimenticatoFino, esitoOra(ts) == .pieno else { return }
        registro.evento(tipo: "comando", ts: ts, app: app, oggetto: oggettoFinestra(), dettaglio: ["tasti": tasti], cc: cc)
    }

    /// Cambio degli appunti. selezione = AXSelectedText della sorgente (solo per le impronte).
    func appunti(cc: Int, tipi: [String], riservato: Bool, lunghezza: Int?, selezione: String?, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        contesto.modifica { $0.ultimoChangeCount = cc }
        guard ts > dimenticatoFino, esitoOra(ts) == .pieno else { return }
        var d: [String: Any] = ["tipi": tipi, "riservato": riservato ? 1 : 0]
        if let n = lunghezza, !riservato { d["len"] = n }
        let id = registro.evento(tipo: "appunti", ts: ts, app: app, oggetto: oggettoFinestra(), dettaglio: d, cc: cc)
        if !riservato, let s = selezione, !s.isEmpty {
            registro.impronte(eventoId: id, testo: s, fonte: "selezione")
        }
    }

    /// Evento di file (file_crea, file_mod, file_sposta, file_elimina). Non dipende dall'app.
    /// Un download da un dominio escluso resta solo come estensione e inode: niente nome del file,
    /// niente impronte, niente provenienza.
    func file(tipo: String, info: InfoFile, daPath: String? = nil, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !filtri.inPausa(ts), ts > dimenticatoFino, !RegoleFiltro.cartellaEsclusa(info.path) else { return }
        if let da = daPath, RegoleFiltro.cartellaEsclusa(da) { return }
        var d: [String: Any] = [:]
        if let da = daPath { d["da"] = registro.chiaveOggetto(tipo: "file", valore: da) }
        if RegoleFiltro.provenienzaEsclusa(info.provenienza, extra: filtri.attuali().escludiDomini) {
            var ogg = oggettoFile(info)
            ogg.etichetta = nil
            ogg.provenienza = nil
            registro.evento(tipo: tipo, ts: ts, oggetto: ogg, dettaglio: d)
            return
        }
        let id = registro.evento(tipo: tipo, ts: ts, oggetto: oggettoFile(info), dettaglio: d)
        registro.impronte(eventoId: id, testo: (info.path as NSString).lastPathComponent, fonte: "file")
    }

    /// Istantanea del testo della finestra attiva (fonte "ax" o "ocr").
    func schermo(fonte: String, ms: Int, righe: [String], troncato: Bool, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard testoSchermo, ts > dimenticatoFino, esitoOra(ts) == .pieno, let app = app else { return }
        registro.righe(ts: ts, app: app, finestra: oggettoFinestra(), fonte: fonte, ms: ms, righe: righe, troncato: troncato)
    }

    /// Conteggi di tasti e clic, sommati al tratto aperto (mai i caratteri).
    func input(tasti: Int, click: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var t = tratto, t.aperto, !sospeso else { return }
        t.tasti += tasti
        t.click += click
        tratto = t
    }

    // MARK: Battito, inattività, sonno, blocco, pausa

    /// Ogni 5 s: controlla la pausa, rivaluta (secure input può cambiare) e allunga il tratto.
    func battito(_ ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        controllaPausa(ts)
        if !sospeso { rivaluta(ts) }
    }

    func inizioInattivita(da: Int64) {
        lock.lock(); defer { lock.unlock() }
        chiudiTratto(da, tronca: true)
        sospeso = true
        contesto.modifica { $0.inattivo = true }
    }

    func fineInattivita(da: Int64, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !filtri.inPausa(ts) {
            registro.evento(tipo: "inattivo", ts: da, dur: ts - da, dettaglio: [:])
        }
        sospeso = false
        contesto.modifica { $0.inattivo = false }
        rivaluta(ts)
    }

    /// sonno | blocco: chiude il tratto e sospende.
    func sospendi(_ tipo: String, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        chiudiTratto(ts, tronca: false)
        sospeso = true
        if !filtri.inPausa(ts) { registro.evento(tipo: tipo, ts: ts, dettaglio: [:]) }
    }

    /// risveglio | sblocco: riprende.
    func riprendi(_ tipo: String, ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        if !filtri.inPausa(ts) { registro.evento(tipo: tipo, ts: ts, dettaglio: [:]) }
        sospeso = false
        rivaluta(ts)
    }

    /// Le impostazioni sono cambiate (esclusioni, pausa): si rivaluta subito.
    func regoleCambiate(_ ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        controllaPausa(ts)
        if !sospeso { rivaluta(ts) }
    }

    /// Dopo "dimentica": il tratto aperto potrebbe essere stato cancellato, se ne apre uno nuovo.
    /// fino: fine dell'intervallo cancellato (default ts - 1). Da qui in poi ogni segnale con un ts
    /// fino a quel punto (un OCR finito in ritardo, un campo aperto prima) si scarta.
    func dimenticato(_ ts: Int64, fino: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        dimenticatoFino = max(dimenticatoFino, fino ?? (ts - 1))
        tratto = nil
        ultimoDocumento = nil
        ultimoURL = nil
        campoIngresso = nil
        if !sospeso { rivaluta(ts) }
    }

    /// Alla chiusura: chiude il tratto e scrive la pausa in corso.
    func chiudi(_ ts: Int64) {
        lock.lock(); defer { lock.unlock() }
        chiudiTratto(ts, tronca: false)
        if let da = pausaDa {
            registro.evento(tipo: "pausa", ts: da, dur: ts - da, dettaglio: ["motivo": motivoPausa])
            pausaDa = nil
        }
    }

    func esitoAttuale() -> Esito {
        lock.lock(); defer { lock.unlock() }
        return esito
    }

    // MARK: Interno

    private func controllaPausa(_ ts: Int64) {
        let inPausa = filtri.inPausa(ts)
        if inPausa && pausaDa == nil {
            pausaDa = ts
            chiudiTratto(ts, tronca: false)
            contesto.modifica { $0.pausa = true }
        } else if !inPausa, let da = pausaDa {
            registro.evento(tipo: "pausa", ts: da, dur: ts - da, dettaglio: ["motivo": motivoPausa])
            pausaDa = nil
            motivoPausa = "cli"
            contesto.modifica { $0.pausa = false }
        }
    }

    private func osservazione(ts: Int64, ruolo: String?, subruolo: String?) -> Osservazione {
        Osservazione(ora: ts, bundle: app?.bundle, nomeApp: app?.nome, titolo: titolo, url: url,
                     attributiFinestra: attributi, ruoloFocus: ruolo, subruoloFocus: subruolo,
                     secureInput: secureInput(), browser: app.map { Esclusioni.browser.contains($0.bundle) } ?? false,
                     documento: documento, finestraNota: finestraLetta)
    }

    // MARK: Regole pure sulle etichette (testate dal selftest)

    /// Menu che elencano titoli di finestre e pagine: Finestra, Cronologia, Preferiti, Segnalibri.
    static let menuConTitoli: Set<String> = [
        "finestra", "window", "cronologia", "history", "preferiti", "bookmarks", "segnalibri", "favorites",
    ]

    /// Il percorso di un menu senza i titoli di finestre e pagine: per i menu di menuConTitoli
    /// resta solo il primo livello.
    static func percorsoMenuSicuro(_ percorso: String) -> String {
        #if VELENO
        return percorso
        #else
        let parti = percorso.components(separatedBy: " > ")
        guard parti.count > 1, let primo = parti.first,
              menuConTitoli.contains(primo.trimmingCharacters(in: .whitespaces).lowercased()) else { return percorso }
        return primo
        #endif
    }

    /// L'etichetta di un clic fuori da una pagina web si salva solo fuori dai browser e mai su una scheda.
    static func etichettaClicAmmessa(bundle: String?, subruolo: String?) -> Bool {
        #if VELENO
        return true
        #else
        if subruolo == "AXTabButton" { return false }
        if let b = bundle, Esclusioni.browser.contains(b) { return false }
        return true
        #endif
    }

    private func esitoPer(ruolo: String?, subruolo: String?, ts: Int64) -> Esito {
        if app == nil { return .scarta }
        return filtri.decidi(osservazione(ts: ts, ruolo: ruolo, subruolo: subruolo))
    }

    /// Esito valutato adesso, con secure input letto dal vivo, per i segnali dentro la finestra.
    private func esitoOra(_ ts: Int64) -> Esito {
        if sospeso { return .scarta }
        return esitoPer(ruolo: focusRuolo, subruolo: focusSubruolo, ts: ts)
    }

    private func rivaluta(_ ts: Int64) {
        let nuovo = esitoPer(ruolo: focusRuolo, subruolo: focusSubruolo, ts: ts)
        esito = nuovo
        let finestra = nuovo == .pieno ? oggettoFinestra() : nil
        contesto.modifica {
            $0.esito = nuovo
            $0.finestra = finestra
        }
        if sospeso { return }
        guard let app = app else {
            chiudiTratto(ts, tronca: false)
            return
        }
        switch nuovo {
        case .pieno:
            apriTratto(tipo: "finestra", app: app, oggetto: finestra, dettaglio: ["pid": Int(pid)], perche: "", ts: ts)
        case .escluso(let perche):
            apriTratto(tipo: "escluso", app: app, oggetto: nil, dettaglio: ["perche": perche], perche: perche, ts: ts)
        case .protetto:
            apriTratto(tipo: "protetto", app: app, oggetto: nil, dettaglio: [:], perche: "", ts: ts)
        case .scarta:
            chiudiTratto(ts, tronca: false)
        }
    }

    private func apriTratto(tipo: String, app: AppRif, oggetto: OggettoRif?, dettaglio: [String: Any], perche: String, ts: Int64) {
        let prefisso = tipo + "\u{1}" + app.bundle
        let chiave = [prefisso, oggetto?.valore ?? "", perche].joined(separator: "\u{1}")
        // Il titolo arriva dall'AX poco dopo il cambio d'app: il tratto appena aperto senza
        // oggetto lo riceve, invece di lasciare un tratto vuoto di pochi decimi di secondo.
        if var t = tratto, t.aperto, t.senzaOggetto, let ogg = oggetto, t.prefisso == prefisso,
           ts - t.ts <= Annotatore.attesaTitolo {
            registro.riassegna(id: t.id, oggetto: ogg)
            t.chiave = chiave
            t.senzaOggetto = false
            t.fine = max(t.fine, ts)
            tratto = t
            registro.durata(id: t.id, ts: t.ts, dur: t.fine - t.ts, tasti: t.tasti, click: t.click)
            if tipo == "finestra", let ti = titolo, !ti.isEmpty {
                registro.impronte(eventoId: t.id, testo: ti, fonte: "titolo")
            }
            return
        }
        if var t = tratto, t.chiave == chiave, t.aperto || ts - t.fine <= Annotatore.finestraFusione {
            t.fine = max(t.fine, ts)
            t.aperto = true
            tratto = t
            registro.durata(id: t.id, ts: t.ts, dur: t.fine - t.ts, tasti: t.tasti, click: t.click)
            return
        }
        chiudiTratto(ts, tronca: false)
        let id = registro.evento(tipo: tipo, ts: ts, app: app, oggetto: oggetto, dettaglio: dettaglio, tasti: 0, click: 0)
        if tipo == "finestra", let t = titolo, !t.isEmpty {
            registro.impronte(eventoId: id, testo: t, fonte: "titolo")
        }
        tratto = Tratto(id: id, chiave: chiave, prefisso: prefisso, senzaOggetto: oggetto == nil,
                        ts: ts, fine: ts, aperto: true, tasti: 0, click: 0)
    }

    /// Chiude il tratto aperto a `ts`. tronca: la fine può tornare indietro (inizio dell'inattività).
    private func chiudiTratto(_ ts: Int64, tronca: Bool) {
        guard var t = tratto, t.aperto else { return }
        t.fine = tronca ? max(t.ts, ts) : max(t.fine, ts)
        t.aperto = false
        tratto = t
        registro.durata(id: t.id, ts: t.ts, dur: t.fine - t.ts, tasti: t.tasti, click: t.click)
    }

    private func oggettoFinestra() -> OggettoRif? {
        guard let app = app, let t = titolo, !t.isEmpty else { return nil }
        let pulito = redattore.pulisciTitolo(t)
        if pulito.isEmpty { return nil }
        return OggettoRif(tipo: "finestra", valore: app.bundle + "\u{0}" + pulito, etichetta: pulito)
    }

    private func oggettoFile(_ f: InfoFile) -> OggettoRif {
        let nome = (f.path as NSString).lastPathComponent
        let ext = (nome as NSString).pathExtension.lowercased()
        return OggettoRif(tipo: "file", valore: f.path, etichetta: redattore.redigi(nome).testo,
                          dominio: nil, ext: ext.isEmpty ? nil : ext, inode: f.inode,
                          cartella: RegoleFiltro.classificaCartella(f.path, home: home), provenienza: f.provenienza)
    }
}
