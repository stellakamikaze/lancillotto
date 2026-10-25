// Registro.swift: il registro SQLite (C API), con coda di scrittura a lotti.
//
// Flusso:
//   sensore -> Annotatore (filtri) -> Registro.evento/campo/righe/impronte
//        -> coda seriale `coda` -> buffer in RAM -> lotto in transazione ogni 10 s o a 200 eventi
//   ombra: errore di scrittura (SQLITE_FULL o altro) -> il buffer resta, massimo 1000 operazioni;
//          oltre scarta le più vecchie, conta in meta.persi e segnala in salute.
//   ombra: vincolo violato (un oggetto cancellato da fuori) -> svuota le cache e riprova una volta.
//
// Gli id degli eventi li assegna il registratore (contatore da MAX(id)+1, e mai sotto
// meta.prossimo_id), così un sensore riceve subito l'id e può legarci campo, schermo e impronte
// prima che il lotto vada su disco. Gli id non tornano mai indietro, nemmeno dopo un "dimentica"
// e un riavvio: l'analisi non scambia un evento nuovo per uno già visto.
// Ogni cancellazione (dimentica, esclusione, conservazione) fa salire meta.cancellazioni:
// l'analisi lo vede e riparte da zero (docs/CONTRATTO.md, "meta").
// Le letture del menu (consensi, peso di oggi) usano una connessione a parte in sola lettura:
// il main thread non aspetta mai la coda di scrittura, che può attendere il lock della CLI.
// App e oggetti si risolvono (interning) solo dentro il lotto, con cache in memoria.
// Ogni testo passa dal Redattore anche qui, oltre che nell'Annotatore: è l'ultimo varco.

import Foundation
import SQLite3

let versioneBinario = "0.2.0"
let versioneSchema = 1

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func oraMs() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1000).rounded())
}

// MARK: - Accesso a SQLite

struct ErroreDb: Error, CustomStringConvertible {
    let codice: Int32
    let messaggio: String
    var description: String { "sqlite \(codice): \(messaggio)" }
    var vincolo: Bool { (codice & 0xff) == SQLITE_CONSTRAINT }
    var pieno: Bool { (codice & 0xff) == SQLITE_FULL }
}

final class Istruzione {
    let p: OpaquePointer
    private let db: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s = s else {
            throw ErroreDb(codice: rc, messaggio: String(cString: sqlite3_errmsg(db)) + " in: " + sql)
        }
        self.p = s
        self.db = db
    }

    deinit { sqlite3_finalize(p) }

    func azzera() {
        sqlite3_reset(p)
        sqlite3_clear_bindings(p)
    }

    func lega(_ i: Int32, _ v: Int64?) {
        if let v = v { sqlite3_bind_int64(p, i, v) } else { sqlite3_bind_null(p, i) }
    }

    func lega(_ i: Int32, _ v: String?) {
        if let v = v { sqlite3_bind_text(p, i, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(p, i) }
    }

    func lega(_ i: Int32, _ v: Data?) {
        guard let v = v else { sqlite3_bind_null(p, i); return }
        if v.isEmpty { sqlite3_bind_zeroblob(p, i, 0); return }
        v.withUnsafeBytes { b in
            _ = sqlite3_bind_blob(p, i, b.baseAddress, Int32(b.count), SQLITE_TRANSIENT)
        }
    }

    /// true se c'è una riga, false a fine risultati.
    func passo() throws -> Bool {
        let rc = sqlite3_step(p)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        let e = ErroreDb(codice: sqlite3_extended_errcode(db), messaggio: String(cString: sqlite3_errmsg(db)))
        sqlite3_reset(p)
        throw e
    }

    func intero(_ c: Int32) -> Int64 { sqlite3_column_int64(p, c) }
    func nullo(_ c: Int32) -> Bool { sqlite3_column_type(p, c) == SQLITE_NULL }

    func testo(_ c: Int32) -> String? {
        guard let t = sqlite3_column_text(p, c) else { return nil }
        return String(cString: t)
    }

    func blob(_ c: Int32) -> Data? {
        guard let b = sqlite3_column_blob(p, c) else { return nil }
        return Data(bytes: b, count: Int(sqlite3_column_bytes(p, c)))
    }
}

final class Db {
    let h: OpaquePointer
    private var cache: [String: Istruzione] = [:]

    init(percorso: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(percorso, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db = db else {
            let m = db.map { String(cString: sqlite3_errmsg($0)) } ?? "apertura"
            if let db = db { sqlite3_close(db) }
            throw ErroreDb(codice: rc, messaggio: m)
        }
        self.h = db
        sqlite3_extended_result_codes(db, 1)
    }

    func chiudi() {
        cache.removeAll()
        sqlite3_close_v2(h)
    }

    func esegui(_ sql: String) throws {
        var errore: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &errore)
        if rc != SQLITE_OK {
            let m = errore.map { String(cString: $0) } ?? "errore"
            sqlite3_free(errore)
            throw ErroreDb(codice: sqlite3_extended_errcode(h), messaggio: m)
        }
    }

    /// Istruzione preparata e tenuta in cache, già azzerata.
    func istruzione(_ sql: String) throws -> Istruzione {
        if let s = cache[sql] {
            s.azzera()
            return s
        }
        let s = try Istruzione(db: h, sql: sql)
        cache[sql] = s
        return s
    }

    func intero(_ sql: String, _ argomenti: [Any?] = []) throws -> Int64? {
        let s = try istruzione(sql)
        lega(s, argomenti)
        defer { s.azzera() }
        guard try s.passo(), !s.nullo(0) else { return nil }
        return s.intero(0)
    }

    func testo(_ sql: String, _ argomenti: [Any?] = []) throws -> String? {
        let s = try istruzione(sql)
        lega(s, argomenti)
        defer { s.azzera() }
        guard try s.passo() else { return nil }
        return s.testo(0)
    }

    func scrivi(_ sql: String, _ argomenti: [Any?] = []) throws {
        let s = try istruzione(sql)
        lega(s, argomenti)
        defer { s.azzera() }
        _ = try s.passo()
    }

    var modificate: Int { Int(sqlite3_changes(h)) }
    var ultimoId: Int64 { sqlite3_last_insert_rowid(h) }

    func lega(_ s: Istruzione, _ argomenti: [Any?]) {
        for (i, a) in argomenti.enumerated() {
            let pos = Int32(i + 1)
            switch a {
            case let v as Int64: s.lega(pos, v)
            case let v as Int: s.lega(pos, Int64(v))
            case let v as Int32: s.lega(pos, Int64(v))
            case let v as String: s.lega(pos, v)
            case let v as Data: s.lega(pos, v)
            default: s.lega(pos, Optional<Int64>.none)
            }
        }
    }
}

// MARK: - Riferimenti che i sensori passano al registro

struct AppRif: Equatable {
    let bundle: String
    let nome: String?
}

struct OggettoRif: Equatable {
    let tipo: String          // finestra | file | url
    let valore: String        // identità: path completo, URL senza query, bundle\0titolo
    var etichetta: String?
    var dominio: String? = nil
    var ext: String? = nil
    var inode: Int64? = nil
    var cartella: String? = nil
    var provenienza: String? = nil
}

struct StatoRegistro {
    var aperto = false
    var errore: String?
    var inCoda = 0
    var persi: Int64 = 0
}

struct RichiestaConsenso: Equatable {
    let id: String
    let t0: Int64
    let t1: Int64
    let descrizione: String
}

// MARK: - Registro

final class Registro {
    let cartella: URL
    let percorso: String
    let hmac: Hmac
    let redattore: Redattore

    private let coda = DispatchQueue(label: "org.stellakamikaze.lancillotto.registro")
    private var db: Db?
    /// Connessione in sola lettura per il main thread (menu, consenso). Protetta da lockLettore.
    private var lettore: Db?
    private let lockLettore = NSLock()
    private var prossimoIdScritto: Int64 = 0

    // Solo su `coda`.
    private enum Operazione {
        case evento(EventoNuovo)
        case campo(eventoId: Int64, ruolo: String?, etichetta: String?, valoreZ: Data?, lunghezza: Int64?, redazioni: Int64)
        case schermo(SchermoNuovo)
        case impronte(eventoId: Int64, voci: [Impronta], fonte: String)
        case salute(ts: Int64, sensore: String, stato: String, dettaglio: String?)
        case meta(String, String)
        case oggetto(eventoId: Int64, OggettoRif)
    }

    private struct EventoNuovo {
        let id: Int64
        let ts: Int64
        let dur: Int64
        let tipo: String
        let app: AppRif?
        let oggetto: OggettoRif?
        let dettaglio: String?
        let cc: Int64?
        let tasti: Int64?
        let click: Int64?
    }

    private struct RigaNuova {
        let h: String
        let testoZ: Data
        let lunghezza: Int64
    }

    private struct SchermoNuovo {
        let eventoId: Int64
        let ts: Int64
        let fonte: String
        let finestra: OggettoRif?
        let righe: [RigaNuova]
        let aggiunteH: [String]
        let tolteH: [String]
        let nRighe: Int64
        let troncato: Bool
    }

    private struct Durata {
        let ts: Int64
        let dur: Int64
        let tasti: Int64?
        let click: Int64?
    }

    private var inAttesa: [Operazione] = []
    private var eventiInAttesa = 0
    private var durate: [Int64: Durata] = [:]
    private var cacheApp: [String: Int64] = [:]
    private var cacheOggetto: [String: Int64] = [:]
    private var cacheRiga: [String: Int64] = [:]
    private var schermoPrecedente: [String: Set<String>] = [:]
    private var persi: Int64 = 0
    private var persiScritti: Int64 = 0
    private var ultimoErrore: String?
    private var timer: DispatchSourceTimer?
    private var battiti = 0
    private var permessiWalFatti = false

    // Protetti da `lockId`.
    private let lockId = NSLock()
    private var prossimoId: Int64 = 1
    private var stato = StatoRegistro()

    static let massimoInCoda = 1000
    static let eventiPerLotto = 200

    init(cartella: URL, hmac: Hmac) {
        self.cartella = cartella
        self.percorso = cartella.appendingPathComponent("registro.sqlite").path
        self.hmac = hmac
        self.redattore = Redattore(hmac: hmac)
    }

    /// Cartella dati: LANCILLOTTO_DIR se c'è, altrimenti ~/Library/Application Support/Lancillotto.
    static func cartellaDati() -> URL {
        if let d = ProcessInfo.processInfo.environment["LANCILLOTTO_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return cartellaReale()
    }

    static func cartellaReale() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Lancillotto", isDirectory: true)
    }

    /// Crea la cartella con permessi 700 (o li corregge se esiste).
    static func preparaCartella(_ c: URL) throws {
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(c.path, 0o700)
    }

    // MARK: Apertura e chiusura

    func apri() throws {
        try coda.sync {
            try Registro.preparaCartella(cartella)
            if !FileManager.default.fileExists(atPath: percorso) {
                let fd = open(percorso, O_WRONLY | O_CREAT, 0o600)
                if fd >= 0 { close(fd) }
            }
            chmod(percorso, 0o600)
            let d = try Db(percorso: percorso)
            do {
                sqlite3_busy_timeout(d.h, 5000)
                try d.esegui(schemaSQL)
                try d.esegui("PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
                let modo = try d.testo("PRAGMA journal_mode")
                if modo?.lowercased() != "wal" {
                    throw ErroreDb(codice: SQLITE_ERROR, messaggio: "journal_mode è \(modo ?? "?") invece di wal")
                }
                if let v = try d.testo("SELECT valore FROM meta WHERE chiave='schema_versione'") {
                    if (Int(v) ?? 0) > versioneSchema {
                        throw ErroreDb(codice: SQLITE_ERROR, messaggio: "schema \(v) più nuovo del registratore (\(versioneSchema)): aggiorna Lancillotto")
                    }
                } else {
                    try d.scrivi("INSERT INTO meta(chiave, valore) VALUES('schema_versione', ?)", [String(versioneSchema)])
                }
                try d.scrivi("INSERT OR REPLACE INTO meta(chiave, valore) VALUES('versione_binario', ?)", [versioneBinario])
                try d.scrivi("INSERT OR IGNORE INTO meta(chiave, valore) VALUES('persi', '0')")
                persi = Int64(try d.testo("SELECT valore FROM meta WHERE chiave='persi'") ?? "0") ?? 0
                persiScritti = persi
                let massimo = try d.intero("SELECT MAX(id) FROM evento") ?? 0
                let salvato = Int64(try d.testo("SELECT valore FROM meta WHERE chiave='prossimo_id'") ?? "0") ?? 0
                prossimoIdScritto = salvato
                lockId.lock()
                prossimoId = max(massimo + 1, salvato)
                stato.aperto = true
                stato.persi = persi
                lockId.unlock()
            } catch {
                d.chiudi()
                throw error
            }
            db = d
            correggiPermessiFile()
        }
    }

    /// Timer di coda: lotto ogni 10 s, battito in meta ogni 30 s.
    func avviaTemporizzatori() {
        let t = DispatchSource.makeTimerSource(queue: coda)
        t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.battiti += 1
            if self.battiti % 3 == 1 {
                self.accoda(.meta("ultimo_battito", String(oraMs())))
            }
            self.svuotaInCoda()
        }
        t.resume()
        timer = t
        coda.async { self.accoda(.meta("ultimo_battito", String(oraMs()))) }
    }

    /// Scrive tutto quello che è in coda. Restituisce false se il lotto non è andato su disco.
    @discardableResult
    func svuota() -> Bool {
        coda.sync { svuotaInCoda() }
    }

    func chiudi() {
        let conBattito = timer != nil
        timer?.cancel()
        timer = nil
        coda.sync {
            // Il battito è dell'app viva: lo scenario e i test (senza temporizzatori) non lo scrivono.
            if conBattito { accoda(.meta("ultimo_battito", String(oraMs()))) }
            svuotaInCoda()
            db?.chiudi()
            db = nil
            lockId.lock()
            stato.aperto = false
            lockId.unlock()
        }
        lockLettore.lock()
        lettore?.chiudi()
        lettore = nil
        lockLettore.unlock()
    }

    /// PRAGMA wal_checkpoint(TRUNCATE): porta tutto nel file principale.
    func checkpoint() throws {
        try coda.sync {
            svuotaInCoda()
            try db?.esegui("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func statoAttuale() -> StatoRegistro {
        lockId.lock()
        defer { lockId.unlock() }
        return stato
    }

    // MARK: API per i sensori

    private func nuovoId() -> Int64 {
        lockId.lock()
        defer { lockId.unlock() }
        let id = prossimoId
        prossimoId += 1
        return id
    }

    /// Chiave HMAC di un oggetto, come in `oggetto.chiave_h`.
    func chiaveOggetto(tipo: String, valore: String) -> String {
        hmac.hex(tipo + "\u{0}" + valore)
    }

    /// Accoda un evento e ne restituisce subito l'id.
    @discardableResult
    func evento(tipo: String, ts: Int64, dur: Int64 = 0, app: AppRif? = nil, oggetto: OggettoRif? = nil,
                dettaglio: [String: Any]? = nil, cc: Int? = nil, tasti: Int? = nil, click: Int? = nil) -> Int64 {
        let id = nuovoId()
        let json = dettaglio.map { Registro.jsonCompatto(redigiDettaglio($0)) }
        let e = EventoNuovo(id: id, ts: ts, dur: dur, tipo: tipo, app: app, oggetto: oggetto, dettaglio: json,
                            cc: cc.map(Int64.init), tasti: tasti.map(Int64.init), click: click.map(Int64.init))
        coda.async { self.accoda(.evento(e)) }
        return id
    }

    /// Allunga (o accorcia) un evento già accodato o già scritto. L'ultima richiesta vince.
    func durata(id: Int64, ts: Int64, dur: Int64, tasti: Int? = nil, click: Int? = nil) {
        let d = Durata(ts: ts, dur: max(0, dur), tasti: tasti.map(Int64.init), click: click.map(Int64.init))
        coda.async { self.durate[id] = d }
    }

    /// Assegna l'oggetto a un evento già accodato o scritto (tratto aperto prima che arrivasse il titolo).
    func riassegna(id: Int64, oggetto: OggettoRif) {
        coda.async { self.accoda(.oggetto(eventoId: id, oggetto)) }
    }

    /// Evento campo_valore con la riga in `campo`: valore redatto, troncato a 500, compresso.
    /// valore nil: si salvano solo ruolo ed etichetta (impostazione valori_campi spenta).
    @discardableResult
    func campo(ts: Int64, dur: Int64, app: AppRif?, finestra: OggettoRif?, ruolo: String?, etichetta: String?,
               valore: String?) -> Int64 {
        var dettaglio: [String: Any] = [:]
        if let r = ruolo { dettaglio["ruolo"] = r }
        if let e = etichetta { dettaglio["etichetta"] = e }
        let id = evento(tipo: "campo_valore", ts: ts, dur: dur, app: app, oggetto: finestra, dettaglio: dettaglio)
        let etichettaPulita = etichetta.map { String(redattore.redigi($0).testo.prefix(200)) }
        var z: Data?
        var lunghezza: Int64?
        var n: Int64 = 0
        if let v = valore {
            let r = redattore.redigi(v)
            z = Compressione.comprimi(String(r.testo.prefix(500)))
            lunghezza = Int64(v.count)
            n = Int64(r.n)
            let imp = redattore.impronte(v)
            if !imp.isEmpty { coda.async { self.accoda(.impronte(eventoId: id, voci: imp, fonte: "campo")) } }
        }
        let op = Operazione.campo(eventoId: id, ruolo: ruolo, etichetta: etichettaPulita, valoreZ: z, lunghezza: lunghezza, redazioni: n)
        coda.async { self.accoda(op) }
        return id
    }

    /// Istantanea del testo di una finestra: evento schermo, righe uniche, aggiunte e tolte.
    @discardableResult
    func righe(ts: Int64, app: AppRif?, finestra: OggettoRif?, fonte: String, ms: Int, righe grezze: [String],
               troncato: Bool) -> Int64 {
        let id = evento(tipo: "schermo", ts: ts, app: app, oggetto: finestra, dettaglio: ["fonte": fonte, "ms": ms])
        var viste = Set<String>()
        var nuove: [RigaNuova] = []
        var grezzePerH: [String: String] = [:]
        for g in grezze {
            guard let norm = Redattore.normalizzaRiga(String(g.prefix(2000))) else { continue }
            let redatta = String(redattore.redigi(norm).testo.prefix(1000))
            let h = sha256Breve(redatta)
            if viste.contains(h) { continue }
            viste.insert(h)
            grezzePerH[h] = norm
            nuove.append(RigaNuova(h: h, testoZ: Compressione.comprimi(redatta), lunghezza: Int64(redatta.count)))
        }
        let chiaveFinestra = finestra?.valore ?? (app?.bundle ?? "")
        let redattore = self.redattore
        coda.async {
            let prima = self.schermoPrecedente[chiaveFinestra] ?? []
            let aggiunte = nuove.map { $0.h }.filter { !prima.contains($0) }
            let tolte = prima.subtracting(viste).sorted()
            self.schermoPrecedente[chiaveFinestra] = viste
            if self.schermoPrecedente.count > 200 { self.schermoPrecedente.removeAll() }
            let s = SchermoNuovo(eventoId: id, ts: ts, fonte: fonte, finestra: finestra, righe: nuove,
                                 aggiunteH: aggiunte, tolteH: tolte, nRighe: Int64(nuove.count), troncato: troncato)
            self.accoda(.schermo(s))
            // Impronte solo dalle righe comparse ora: le altre le ha già date l'istantanea prima.
            let testoNuovo = aggiunte.compactMap { grezzePerH[$0] }.joined(separator: "\n")
            let imp = redattore.impronte(testoNuovo, massimo: 100)
            if !imp.isEmpty { self.accoda(.impronte(eventoId: id, voci: imp, fonte: "schermo")) }
        }
        return id
    }

    /// Impronte HMAC del testo grezzo, legate a un evento. Fonti: titolo | file | selezione | campo | schermo.
    func impronte(eventoId: Int64, testo: String, fonte: String) {
        let imp = redattore.impronte(testo)
        if imp.isEmpty { return }
        coda.async { self.accoda(.impronte(eventoId: eventoId, voci: imp, fonte: fonte)) }
    }

    /// Riga in `salute`. stato: ok | degradato | spento | guasto.
    func salute(sensore: String, stato: String, dettaglio: String? = nil, ts: Int64 = oraMs()) {
        coda.async { self.accoda(.salute(ts: ts, sensore: sensore, stato: stato, dettaglio: dettaglio)) }
    }

    func meta(_ chiave: String, _ valore: String) {
        coda.async { self.accoda(.meta(chiave, valore)) }
    }

    // MARK: Manutenzione (cancellazioni)

    /// Escludi l'app: marca app.esclusa e cancella i suoi eventi già registrati, compresi quelli
    /// ancora in coda. voce: bundle (uguale o prefisso) oppure nome dell'app, come in impostazioni.
    func cancellaApp(bundle voce: String, completamento: ((Int) -> Void)? = nil) {
        coda.async {
            let n = self.cancellaAppInCoda(voce)
            completamento?(n)
        }
    }

    /// Variante sincrona, per i test.
    @discardableResult
    func cancellaAppSubito(_ voce: String) -> Int {
        coda.sync { cancellaAppInCoda(voce) }
    }

    private func cancellaAppInCoda(_ voce: String) -> Int {
        svuotaInCoda()
        guard let d = db else { return -1 }
        let v = voce.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return 0 }
        let quali = "SELECT id FROM app WHERE lower(bundle) = lower(?1) OR lower(bundle) LIKE lower(?1) || '.%' OR lower(COALESCE(nome, '')) = lower(?1)"
        var n = 0
        do {
            try d.esegui("BEGIN IMMEDIATE")
            do {
                try d.scrivi("UPDATE app SET esclusa = 1 WHERE id IN (\(quali))", [v])
                try d.scrivi("DELETE FROM evento WHERE app_id IN (\(quali))", [v])
                n = d.modificate
                try pulisciOrfani(d)
                if n > 0 { try contaCancellazione(d) }
                try d.esegui("COMMIT")
            } catch {
                try? d.esegui("ROLLBACK")
                throw error
            }
            dopoCancellazione()
        } catch {
            segnalaErrore("cancella app: \(error)")
            return -1
        }
        return n
    }

    /// Dopo una rilettura delle impostazioni con esclusioni nuove: scrive su disco ciò che è in coda
    /// (gli eventi presi prima della regola nuova), cancella le app appena escluse e segna in
    /// meta.esclusioni_applicate l'ora. La CLI aspetta questo segno prima di cancellare all'indietro.
    func applicaEsclusioni(app nuove: [String], ts: Int64, completamento: (() -> Void)? = nil) {
        coda.async {
            self.svuotaInCoda()
            for voce in nuove { _ = self.cancellaAppInCoda(voce) }
            if let d = self.db {
                do {
                    try d.scrivi("INSERT OR REPLACE INTO meta(chiave, valore) VALUES('esclusioni_applicate', ?)", [String(ts)])
                } catch {
                    self.segnalaErrore("esclusioni: \(error)")
                }
            }
            completamento?()
        }
    }

    /// Variante sincrona, per i test.
    func applicaEsclusioniSubito(app nuove: [String], ts: Int64) {
        let fatto = DispatchSemaphore(value: 0)
        applicaEsclusioni(app: nuove, ts: ts) { fatto.signal() }
        fatto.wait()
    }

    /// meta.cancellazioni + 1, dentro la transazione della cancellazione.
    private func contaCancellazione(_ d: Db) throws {
        try d.scrivi("""
            INSERT INTO meta(chiave, valore) VALUES('cancellazioni', '1')
            ON CONFLICT(chiave) DO UPDATE SET valore = CAST(CAST(valore AS INTEGER) + 1 AS TEXT)
            """)
    }

    /// Cancella eventi, campi, schermi, impronte e righe orfane nell'intervallo [da, a].
    func dimentica(da: Int64, a: Int64, completamento: ((Int) -> Void)? = nil) {
        coda.async {
            let n = self.dimenticaInCoda(da: da, a: a)
            completamento?(n)
        }
    }

    /// Variante sincrona, per i test e lo scenario.
    func dimenticaSubito(da: Int64, a: Int64) -> Int {
        coda.sync { dimenticaInCoda(da: da, a: a) }
    }

    private func dimenticaInCoda(da: Int64, a: Int64) -> Int {
        svuotaInCoda()
        guard let d = db else { return -1 }
        var n = 0
        do {
            try d.esegui("BEGIN IMMEDIATE")
            do {
                try d.scrivi("DELETE FROM evento WHERE ts >= ? AND ts <= ?", [da, a])
                n = d.modificate
                try d.scrivi("UPDATE evento SET dur_ms = ? - ts WHERE ts < ? AND ts + dur_ms > ?", [da, da, da])
                try d.scrivi("DELETE FROM schermo WHERE ts >= ? AND ts <= ?", [da, a])
                try d.scrivi("DELETE FROM salute WHERE ts >= ? AND ts <= ?", [da, a])
                try pulisciOrfani(d)
                try contaCancellazione(d)
                try d.esegui("COMMIT")
            } catch {
                try? d.esegui("ROLLBACK")
                throw error
            }
            dopoCancellazione()
        } catch {
            segnalaErrore("dimentica: \(error)")
            return -1
        }
        return n
    }

    /// Conservazione: via il grezzo più vecchio di `giorni`, gli orfani, poi incremental_vacuum.
    @discardableResult
    func conserva(giorni: Int, ora: Int64 = oraMs()) -> Int {
        coda.sync { conservaInCoda(giorni: giorni, ora: ora) }
    }

    /// Variante asincrona per l'app: il main thread non aspetta la coda.
    func conserva(giorni: Int, ora: Int64, completamento: @escaping (Int) -> Void) {
        coda.async {
            let n = self.conservaInCoda(giorni: giorni, ora: ora)
            completamento(n)
        }
    }

    private func conservaInCoda(giorni: Int, ora: Int64) -> Int {
        svuotaInCoda()
        guard let d = db else { return -1 }
        let soglia = ora - Int64(max(1, giorni)) * 86_400_000
        var n = 0
        do {
            try d.esegui("BEGIN IMMEDIATE")
            do {
                let prima = sqlite3_total_changes(d.h)
                try d.scrivi("DELETE FROM evento WHERE ts < ?", [soglia])
                n = d.modificate
                try d.scrivi("DELETE FROM schermo WHERE ts < ?", [soglia])
                try d.scrivi("DELETE FROM salute WHERE ts < ?", [soglia])
                try d.scrivi("DELETE FROM riga WHERE ultima_ts < ?", [soglia])
                try pulisciOrfani(d)
                if sqlite3_total_changes(d.h) != prima { try contaCancellazione(d) }
                try d.esegui("COMMIT")
            } catch {
                try? d.esegui("ROLLBACK")
                throw error
            }
            try d.esegui("PRAGMA incremental_vacuum")
            dopoCancellazione()
        } catch {
            segnalaErrore("conservazione: \(error)")
            return -1
        }
        return n
    }

    private func pulisciOrfani(_ d: Db) throws {
        try d.esegui("""
            DELETE FROM impronta WHERE evento_id NOT IN (SELECT id FROM evento);
            DELETE FROM campo WHERE evento_id NOT IN (SELECT id FROM evento);
            DELETE FROM schermo WHERE evento_id IS NOT NULL AND evento_id NOT IN (SELECT id FROM evento);
            DELETE FROM oggetto WHERE id NOT IN (SELECT ogg_id FROM evento WHERE ogg_id IS NOT NULL)
              AND id NOT IN (SELECT finestra_id FROM schermo WHERE finestra_id IS NOT NULL);
            DELETE FROM riga WHERE id NOT IN (SELECT CAST(j.value AS INTEGER) FROM schermo, json_each(schermo.aggiunte) AS j);
            """)
    }

    /// Dopo una cancellazione gli id in cache possono non esistere più.
    private func dopoCancellazione() {
        cacheApp.removeAll()
        cacheOggetto.removeAll()
        cacheRiga.removeAll()
        schermoPrecedente.removeAll()
    }

    // MARK: Consenso L2 (docs/CONTRATTO.md, "Consenso L2")

    /// Le richieste in attesa, dalla connessione di sola lettura: non passa dalla coda di scrittura.
    func consensiInAttesa() -> [RichiestaConsenso] {
        let letto = senzaCoda { d -> [RichiestaConsenso] in
            var out: [RichiestaConsenso] = []
            let s = try d.istruzione("SELECT id, t0, t1, descrizione FROM consenso WHERE deciso IS NULL ORDER BY richiesto_ts LIMIT 5")
            defer { s.azzera() }
            while try s.passo() {
                out.append(RichiestaConsenso(id: s.testo(0) ?? "", t0: s.intero(1), t1: s.intero(2), descrizione: s.testo(3) ?? ""))
            }
            return out
        }
        return letto ?? []
    }

    /// Eventi del giorno (tabella giorno), per il menu, dalla connessione di sola lettura.
    func eventiDelGiorno(_ data: String) -> Int64? {
        senzaCoda { d in try d.intero("SELECT eventi FROM giorno WHERE data = ?", [data]) } ?? nil
    }

    /// Una lettura sulla connessione di sola lettura (PRAGMA query_only), aperta alla prima volta.
    /// Con WAL un lettore non aspetta lo scrittore; busy_timeout corto per i rari lock di checkpoint.
    func senzaCoda<T>(_ blocco: (Db) throws -> T) -> T? {
        lockLettore.lock()
        defer { lockLettore.unlock() }
        if lettore == nil {
            guard FileManager.default.fileExists(atPath: percorso), let l = try? Db(percorso: percorso) else { return nil }
            sqlite3_busy_timeout(l.h, 250)
            do {
                try l.esegui("PRAGMA query_only = 1")
            } catch {
                l.chiudi()
                return nil
            }
            lettore = l
        }
        guard let l = lettore else { return nil }
        return try? blocco(l)
    }

    /// Scrive la decisione della persona: deciso 1 o 0, deciso_ts, scade_ts = deciso_ts + 10 minuti.
    @discardableResult
    func decidiConsenso(id: String, si: Bool, ora: Int64 = oraMs()) -> Bool {
        coda.sync {
            guard let d = db else { return false }
            do {
                try d.scrivi("UPDATE consenso SET deciso = ?, deciso_ts = ?, scade_ts = ? WHERE id = ? AND deciso IS NULL",
                             [si ? 1 : 0, ora, ora + 600_000, id])
                return d.modificate == 1
            } catch {
                segnalaErrore("consenso: \(error)")
                return false
            }
        }
    }

    // MARK: Letture per menu, selftest e scenario

    /// Esegue un blocco sul database dentro la coda, dopo aver scritto il lotto in attesa.
    func leggi<T>(_ blocco: (Db) throws -> T) throws -> T? {
        try coda.sync {
            svuotaInCoda()
            guard let d = db else { return nil }
            return try blocco(d)
        }
    }

    /// Byte di registro.sqlite più il file -wal.
    func byteSuDisco() -> Int64 {
        var totale: Int64 = 0
        for p in [percorso, percorso + "-wal"] {
            if let a = try? FileManager.default.attributesOfItem(atPath: p), let n = a[.size] as? NSNumber {
                totale += n.int64Value
            }
        }
        return totale
    }

    // MARK: Interno (solo su `coda`)

    private func accoda(_ op: Operazione) {
        inAttesa.append(op)
        if case .evento = op { eventiInAttesa += 1 }
        if inAttesa.count > Registro.massimoInCoda {
            // Disco pieno o errore persistente: si scarta il più vecchio e si conta.
            let tolta = inAttesa.removeFirst()
            if case .evento = tolta {
                eventiInAttesa -= 1
                persi += 1
            }
        }
        aggiornaStato()
        if eventiInAttesa >= Registro.eventiPerLotto && ultimoErrore == nil {
            svuotaInCoda()
        }
    }

    private func aggiornaStato() {
        lockId.lock()
        stato.inCoda = inAttesa.count
        stato.persi = persi
        stato.errore = ultimoErrore
        lockId.unlock()
    }

    private func segnalaErrore(_ m: String) {
        ultimoErrore = m
        aggiornaStato()
    }

    @discardableResult
    private func svuotaInCoda() -> Bool {
        guard let d = db else { return false }
        if inAttesa.isEmpty && durate.isEmpty && persi == persiScritti { return true }
        do {
            try scriviLotto(d)
        } catch let e as ErroreDb where e.vincolo {
            // Un oggetto o un'app in cache è stato cancellato da fuori: si riprova senza cache.
            dopoCancellazione()
            do {
                try scriviLotto(d)
            } catch {
                registraFallimento(error)
                return false
            }
        } catch {
            registraFallimento(error)
            return false
        }
        inAttesa.removeAll(keepingCapacity: true)
        eventiInAttesa = 0
        durate.removeAll()
        persiScritti = persi
        if let errore = ultimoErrore {
            ultimoErrore = nil
            // Il guasto è passato: lo si dice in salute, nel prossimo lotto.
            inAttesa.append(.salute(ts: oraMs(), sensore: "registro", stato: "ok", dettaglio: "ripreso dopo: " + errore))
        }
        aggiornaStato()
        if !permessiWalFatti { correggiPermessiFile() }
        return true
    }

    private func registraFallimento(_ e: Error) {
        ultimoErrore = "\(e)"
        aggiornaStato()
    }

    private func correggiPermessiFile() {
        var tutti = true
        for suff in ["", "-wal", "-shm"] {
            let p = percorso + suff
            if FileManager.default.fileExists(atPath: p) { chmod(p, 0o600) } else { tutti = false }
        }
        permessiWalFatti = tutti
    }

    private func scriviLotto(_ d: Db) throws {
        try d.esegui("BEGIN IMMEDIATE")
        var nuoveApp: [String: Int64] = [:]
        var nuoviOggetti: [String: Int64] = [:]
        var nuoveRighe: [String: Int64] = [:]
        var giorni = Set<String>()
        do {
            for op in inAttesa {
                switch op {
                case .evento(let e):
                    let appId = try e.app.map { try idApp(d, $0, &nuoveApp) }
                    let oggId = try e.oggetto.map { try idOggetto(d, $0, &nuoviOggetti) }
                    try d.scrivi("INSERT INTO evento(id, ts, dur_ms, tipo, app_id, ogg_id, dettaglio, cc, tasti, click) VALUES(?,?,?,?,?,?,?,?,?,?)",
                                 [e.id, e.ts, e.dur, e.tipo, appId, oggId, e.dettaglio, e.cc, e.tasti, e.click])
                    giorni.insert(Registro.giornoDi(e.ts).data)
                case .campo(let id, let ruolo, let etichetta, let z, let lunghezza, let n):
                    try d.scrivi("INSERT INTO campo(evento_id, ruolo, etichetta, valore_z, lunghezza, redazioni) SELECT ?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM evento WHERE id = ?)",
                                 [id, ruolo, etichetta, z, lunghezza, n, id])
                case .schermo(let s):
                    try scriviSchermo(d, s, &nuoviOggetti, &nuoveRighe)
                case .impronte(let id, let voci, let fonte):
                    for v in voci {
                        try d.scrivi("INSERT INTO impronta(h, tipo, evento_id, fonte) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM evento WHERE id = ?)",
                                     [v.h, v.tipo, id, fonte, id])
                    }
                case .salute(let ts, let sensore, let st, let dettaglio):
                    try d.scrivi("INSERT INTO salute(ts, sensore, stato, dettaglio) VALUES(?,?,?,?)", [ts, sensore, st, dettaglio])
                case .meta(let k, let v):
                    try d.scrivi("INSERT OR REPLACE INTO meta(chiave, valore) VALUES(?,?)", [k, v])
                case .oggetto(let id, let o):
                    let oggId = try idOggetto(d, o, &nuoviOggetti)
                    try d.scrivi("UPDATE evento SET ogg_id = ? WHERE id = ?", [oggId, id])
                }
            }
            for (id, du) in durate {
                try d.scrivi("UPDATE evento SET dur_ms = ?, tasti = COALESCE(?, tasti), click = COALESCE(?, click) WHERE id = ?",
                             [du.dur, du.tasti, du.click, id])
                giorni.insert(Registro.giornoDi(du.ts).data)
            }
            lockId.lock()
            let prossimo = prossimoId
            lockId.unlock()
            if prossimo != prossimoIdScritto {
                try d.scrivi("INSERT OR REPLACE INTO meta(chiave, valore) VALUES('prossimo_id', ?)", [String(prossimo)])
            }
            if persi != persiScritti {
                try d.scrivi("INSERT OR REPLACE INTO meta(chiave, valore) VALUES('persi', ?)", [String(persi)])
                try d.scrivi("INSERT INTO salute(ts, sensore, stato, dettaglio) VALUES(?, 'registro', 'degradato', ?)",
                             [oraMs(), "eventi persi per coda piena: \(persi)"])
            }
            let byte = byteSuDisco()
            for g in giorni {
                try aggiornaGiorno(d, g, byte: byte)
            }
            try d.esegui("COMMIT")
            prossimoIdScritto = prossimo
        } catch {
            try? d.esegui("ROLLBACK")
            throw error
        }
        cacheApp.merge(nuoveApp) { _, n in n }
        cacheOggetto.merge(nuoviOggetti) { _, n in n }
        if cacheRiga.count > 20_000 { cacheRiga.removeAll() }
        cacheRiga.merge(nuoveRighe) { _, n in n }
    }

    private func idApp(_ d: Db, _ a: AppRif, _ nuove: inout [String: Int64]) throws -> Int64 {
        if let id = cacheApp[a.bundle] ?? nuove[a.bundle] { return id }
        if let id = try d.intero("SELECT id FROM app WHERE bundle = ?", [a.bundle]) {
            nuove[a.bundle] = id
            return id
        }
        try d.scrivi("INSERT INTO app(bundle, nome) VALUES(?, ?)", [a.bundle, a.nome.map { String($0.prefix(200)) }])
        let id = d.ultimoId
        nuove[a.bundle] = id
        return id
    }

    private func idOggetto(_ d: Db, _ o: OggettoRif, _ nuovi: inout [String: Int64]) throws -> Int64 {
        let chiave = chiaveOggetto(tipo: o.tipo, valore: o.valore)
        if let id = cacheOggetto[chiave] ?? nuovi[chiave] { return id }
        if let id = try d.intero("SELECT id FROM oggetto WHERE chiave_h = ?", [chiave]) {
            nuovi[chiave] = id
            return id
        }
        let etichetta = o.etichetta.map { String(redattore.redigi($0).testo.prefix(200)) }
        try d.scrivi("INSERT INTO oggetto(tipo, chiave_h, etichetta, dominio, ext, inode, cartella, provenienza) VALUES(?,?,?,?,?,?,?,?)",
                     [o.tipo, chiave, etichetta, o.dominio, o.ext, o.inode, o.cartella, o.provenienza])
        let id = d.ultimoId
        nuovi[chiave] = id
        return id
    }

    /// L'id della riga con hash h. Un id in cache si controlla: la CLI può aver cancellato la riga
    /// e SQLite riassegnato quell'id a un'altra (riga.id non ha AUTOINCREMENT).
    private func idRiga(_ d: Db, _ h: String, _ nuove: [String: Int64]) throws -> Int64? {
        if let id = nuove[h] { return id }
        if let id = cacheRiga[h] {
            if try d.intero("SELECT id FROM riga WHERE id = ? AND h = ?", [id, h]) != nil { return id }
            cacheRiga.removeValue(forKey: h)
        }
        return try d.intero("SELECT id FROM riga WHERE h = ?", [h])
    }

    private func scriviSchermo(_ d: Db, _ s: SchermoNuovo, _ nuoviOggetti: inout [String: Int64],
                               _ nuoveRighe: inout [String: Int64]) throws {
        guard try d.intero("SELECT 1 FROM evento WHERE id = ?", [s.eventoId]) != nil else { return }
        let aggiunte = Set(s.aggiunteH)
        for r in s.righe {
            if let id = try idRiga(d, r.h, nuoveRighe) {
                try d.scrivi("UPDATE riga SET ultima_ts = MAX(ultima_ts, ?), volte = volte + ? WHERE id = ? AND h = ?",
                             [s.ts, aggiunte.contains(r.h) ? 1 : 0, id, r.h])
                if d.modificate == 1 {
                    nuoveRighe[r.h] = id
                    continue
                }
            }
            try d.scrivi("INSERT INTO riga(h, testo_z, lunghezza, prima_ts, ultima_ts, volte) VALUES(?,?,?,?,?,1)",
                         [r.h, r.testoZ, r.lunghezza, s.ts, s.ts])
            nuoveRighe[r.h] = d.ultimoId
        }
        let idAggiunte = try s.aggiunteH.compactMap { try idRiga(d, $0, nuoveRighe) }
        let idTolte = try s.tolteH.compactMap { try idRiga(d, $0, nuoveRighe) }
        let finestraId = try s.finestra.map { try idOggetto(d, $0, &nuoviOggetti) }
        try d.scrivi("INSERT INTO schermo(evento_id, ts, fonte, finestra_id, aggiunte, tolte, n_righe, troncato) VALUES(?,?,?,?,?,?,?,?)",
                     [s.eventoId, s.ts, s.fonte, finestraId, Registro.jsonCompatto(idAggiunte), Registro.jsonCompatto(idTolte),
                      s.nRighe, s.troncato ? 1 : 0])
    }

    private func aggiornaGiorno(_ d: Db, _ data: String, byte: Int64) throws {
        guard let (inizio, fine) = Registro.limitiGiorno(data) else { return }
        try d.scrivi("""
            INSERT INTO giorno(data, eventi, byte, min_attivi, min_pausa) VALUES(?,
              (SELECT COUNT(*) FROM evento WHERE ts >= ? AND ts < ?),
              ?,
              (SELECT COALESCE(SUM(dur_ms), 0) / 60000 FROM evento WHERE tipo IN ('finestra', 'escluso', 'protetto') AND ts >= ? AND ts < ?),
              (SELECT COALESCE(SUM(dur_ms), 0) / 60000 FROM evento WHERE tipo = 'pausa' AND ts >= ? AND ts < ?))
            ON CONFLICT(data) DO UPDATE SET eventi = excluded.eventi, byte = excluded.byte,
              min_attivi = excluded.min_attivi, min_pausa = excluded.min_pausa
            """, [data, inizio, fine, byte, inizio, fine, inizio, fine])
    }

    // MARK: Utilità

    /// Redige le stringhe del dettaglio che portano testo dell'interfaccia.
    private func redigiDettaglio(_ d: [String: Any]) -> [String: Any] {
        var out = d
        for chiave in ["etichetta", "percorso"] {
            if let s = d[chiave] as? String {
                out[chiave] = String(redattore.redigi(s).testo.prefix(200))
            }
        }
        return out
    }

    static func jsonCompatto(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: d, as: UTF8.self)
    }

    private static let formatoGiorno: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let lockFormato = NSLock()

    /// Data locale AAAA-MM-GG di un istante in ms.
    static func giornoDi(_ ts: Int64) -> (data: String, inizio: Int64) {
        let data = Date(timeIntervalSince1970: Double(ts) / 1000)
        lockFormato.lock()
        let s = formatoGiorno.string(from: data)
        lockFormato.unlock()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let inizio = Int64(cal.startOfDay(for: data).timeIntervalSince1970 * 1000)
        return (s, inizio)
    }

    /// Inizio e fine (esclusa) in ms di una data locale.
    static func limitiGiorno(_ data: String) -> (Int64, Int64)? {
        lockFormato.lock()
        let d = formatoGiorno.date(from: data)
        lockFormato.unlock()
        guard let inizioData = d else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let inizio = cal.startOfDay(for: inizioData)
        guard let fine = cal.date(byAdding: .day, value: 1, to: inizio) else { return nil }
        return (Int64(inizio.timeIntervalSince1970 * 1000), Int64(fine.timeIntervalSince1970 * 1000))
    }
}
