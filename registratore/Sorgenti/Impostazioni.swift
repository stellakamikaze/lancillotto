// Impostazioni.swift: lettura, sorveglianza e scrittura atomica di impostazioni.json.
//
// Forma del file in docs/CONTRATTO.md, "Impostazioni". Regole:
//   - se manca, si crea quello di default (file 600);
//   - si sorveglia la CARTELLA (DispatchSource su un fd O_EVTONLY), perché la CLI scrive
//     con .tmp + rename e il file sorvegliato cambierebbe inode; più un controllo ogni 2 s;
//   - si scrive sempre con .tmp nella stessa cartella e rename(2);
//   - le chiavi che il registratore non conosce si conservano così come sono;
//   - un JSON rotto non spegne niente: restano le ultime impostazioni buone e una riga in salute;
//   - `attuali` si legge da qualunque coda (SensoreFile, SensoreSchermo): lettura e scrittura
//     passano da un lock, perché la struct contiene array e una copia a metà è un crash.

import Foundation

struct RichiestaDimentica: Equatable {
    let da: Int64
    let a: Int64
}

struct ImpostazioniDati: Equatable {
    var versione = 1
    var pausaFino: Int64 = 0
    var conservazioneGiorni = 14
    var ocr = true
    /// "testo_schermo": legge il testo delle finestre (AX e OCR). Spento di default (25/10/2026): per
    /// trovare flussi e compiti bastano app, titoli, siti, file e legami; il testo porta dentro email e
    /// documenti di altre persone. "valori_campi" segue la stessa scelta.
    var testoSchermo = false
    var valoriCampi = false
    /// "ax_electron": accende AXManualAccessibility nelle app Electron (SensoreSchermo). Default no.
    var axElectron = false
    var cartelle: [String] = ["~/Downloads", "~/Documents", "~/Desktop"]
    var escludiApp: [String] = []
    var escludiDomini: [String] = []
    var dimenticaRichieste: [RichiestaDimentica] = []

    var regole: Regole {
        Regole(escludiApp: escludiApp, escludiDomini: escludiDomini, pausaFino: pausaFino)
    }

    static func daDizionario(_ d: [String: Any]) -> ImpostazioniDati {
        var s = ImpostazioniDati()
        if let v = intero(d["versione"]) { s.versione = Int(v) }
        if let v = intero(d["pausa_fino"]) { s.pausaFino = v }
        if let v = intero(d["conservazione_giorni"]), v >= 1 { s.conservazioneGiorni = Int(min(v, 3650)) }
        if let v = d["ocr"] as? Bool { s.ocr = v }
        if let v = d["valori_campi"] as? Bool { s.valoriCampi = v }
        if let v = d["testo_schermo"] as? Bool { s.testoSchermo = v }
        if let v = d["ax_electron"] as? Bool { s.axElectron = v }
        if let v = d["cartelle"] as? [String] { s.cartelle = v }
        if let v = d["escludi_app"] as? [String] { s.escludiApp = v }
        if let v = d["escludi_domini"] as? [String] { s.escludiDomini = v }
        if let v = d["dimentica_richieste"] as? [[String: Any]] {
            s.dimenticaRichieste = v.compactMap { r in
                guard let da = intero(r["da"]), let a = intero(r["a"]), a >= da else { return nil }
                return RichiestaDimentica(da: da, a: a)
            }
        }
        return s
    }

    static let dizionarioDefault: [String: Any] = [
        "versione": 1,
        "pausa_fino": 0,
        "conservazione_giorni": 14,
        "ocr": true,
        "testo_schermo": false,
        "valori_campi": false,
        "telemetria": true,
        "cartelle": ["~/Downloads", "~/Documents", "~/Desktop"],
        "escludi_app": [String](),
        "escludi_domini": [String](),
        "dimentica_richieste": [[String: Any]](),
    ]

    private static func intero(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber, !(v is Bool) { return n.int64Value }
        return nil
    }
}

final class Impostazioni: NSObject {
    let cartella: URL
    let percorso: String

    /// Chiamata sul main thread dopo ogni rilettura con un cambiamento: (nuove, vecchie).
    var alCambio: ((ImpostazioniDati, ImpostazioniDati) -> Void)?
    /// Chiamata quando il file non si legge (JSON rotto o permessi).
    var alGuasto: ((String) -> Void)?

    private let lockAttuali = NSLock()
    private var _attuali = ImpostazioniDati()
    /// Le impostazioni correnti. Thread-safe.
    private(set) var attuali: ImpostazioniDati {
        get {
            lockAttuali.lock()
            defer { lockAttuali.unlock() }
            return _attuali
        }
        set {
            lockAttuali.lock()
            _attuali = newValue
            lockAttuali.unlock()
        }
    }
    private var firma: String = ""
    private var sorgente: DispatchSourceFileSystemObject?
    private var controllo: Timer?
    private var rileggiProgrammato = false

    init(cartella: URL) {
        self.cartella = cartella
        self.percorso = cartella.appendingPathComponent("impostazioni.json").path
        super.init()
    }

    /// Prima lettura: crea il file di default se manca.
    @discardableResult
    func carica() -> ImpostazioniDati {
        if !FileManager.default.fileExists(atPath: percorso) {
            do {
                try scriviAtomico(ImpostazioniDati.dizionarioDefault)
            } catch {
                alGuasto?("creazione impostazioni: \(error)")
            }
        }
        chmod(percorso, 0o600)
        if let d = leggiDizionario() {
            attuali = ImpostazioniDati.daDizionario(d)
        }
        firma = firmaFile()
        return attuali
    }

    // MARK: Sorveglianza

    func sorveglia() {
        let fd = open(cartella.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .extend],
                                                              queue: .main)
            s.setEventHandler { [weak self] in self?.programmaRilettura() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sorgente = s
        } else {
            alGuasto?("sorveglianza cartella: \(String(cString: strerror(errno)))")
        }
        // Riserva: un controllo leggero (stat) ogni 2 s, se un evento della cartella sfugge.
        let t = Timer(timeInterval: 2, target: self, selector: #selector(controllaFile), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        controllo = t
    }

    func fermaSorveglianza() {
        sorgente?.cancel()
        sorgente = nil
        controllo?.invalidate()
        controllo = nil
    }

    private func programmaRilettura() {
        if rileggiProgrammato { return }
        rileggiProgrammato = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rileggiProgrammato = false
            self?.rileggiSeCambiato()
        }
    }

    @objc private func controllaFile() {
        rileggiSeCambiato()
    }

    /// Rilegge se inode, dimensione o data di modifica sono cambiati.
    func rileggiSeCambiato() {
        let f = firmaFile()
        if f == firma { return }
        firma = f
        guard let d = leggiDizionario() else { return }
        let nuove = ImpostazioniDati.daDizionario(d)
        let vecchie = attuali
        attuali = nuove
        if nuove != vecchie { alCambio?(nuove, vecchie) }
    }

    // MARK: Scrittura

    /// Rilegge il file, applica la modifica sul dizionario intero (chiavi ignote comprese)
    /// e lo riscrive in modo atomico. Poi applica subito le nuove impostazioni.
    func modifica(_ cambia: (inout [String: Any]) -> Void) {
        var d = leggiDizionario() ?? ImpostazioniDati.dizionarioDefault
        cambia(&d)
        do {
            try scriviAtomico(d)
        } catch {
            alGuasto?("scrittura impostazioni: \(error)")
            return
        }
        rileggiSeCambiato()
    }

    private func scriviAtomico(_ d: [String: Any]) throws {
        try Registro.preparaCartella(cartella)
        let dati = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let tmp = percorso + ".tmp"
        unlink(tmp)
        guard FileManager.default.createFile(atPath: tmp, contents: dati, attributes: [.posixPermissions: 0o600]) else {
            throw ErroreDb(codice: 0, messaggio: "creazione di \(tmp) non riuscita")
        }
        guard rename(tmp, percorso) == 0 else {
            let m = String(cString: strerror(errno))
            unlink(tmp)
            throw ErroreDb(codice: 0, messaggio: "rename: \(m)")
        }
    }

    private func leggiDizionario() -> [String: Any]? {
        guard let dati = FileManager.default.contents(atPath: percorso) else {
            if FileManager.default.fileExists(atPath: percorso) { alGuasto?("impostazioni.json non leggibile") }
            return nil
        }
        guard let o = try? JSONSerialization.jsonObject(with: dati), let d = o as? [String: Any] else {
            alGuasto?("impostazioni.json non è un oggetto JSON valido: restano le impostazioni precedenti")
            return nil
        }
        return d
    }

    private func firmaFile() -> String {
        var st = stat()
        guard stat(percorso, &st) == 0 else { return "assente" }
        return "\(st.st_ino)-\(st.st_size)-\(st.st_mtimespec.tv_sec)-\(st.st_mtimespec.tv_nsec)"
    }

    // MARK: Confronto delle esclusioni

    /// Esclusioni presenti prima e sparite ora: ognuna diventa un evento servizio esclusione_tolta.
    static func esclusioniTolte(da vecchie: ImpostazioniDati, a nuove: ImpostazioniDati) -> [String] {
        let app = vecchie.escludiApp.filter { !nuove.escludiApp.contains($0) }.map { "app:" + $0 }
        let domini = vecchie.escludiDomini.filter { !nuove.escludiDomini.contains($0) }.map { "dominio:" + $0 }
        return app + domini
    }
}
