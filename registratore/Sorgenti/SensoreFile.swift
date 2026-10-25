// SensoreFile.swift: vita dei file in Download, Documenti e Scrivania, eventi file_*.
//
//   FSEventStreamCreate(kFSEventStreamCreateFlagFileEvents) sulle cartelle di impostazioni.cartelle,
//   escluse quelle del CONTRATTO (Library, .git, node_modules, .ssh, nomi con secret/password...).
//   Per ogni file: file_crea / file_mod / file_sposta / file_elimina, con inode (stat), ext,
//   classe di cartella e provenienza del download (kMDItemWhereFroms via getxattr) ridotta al dominio.
//   Lo sposta si appaia per rinomina: la vecchia e la nuova riga arrivano insieme, o entro ~1,2 s.
//   Debounce di 1 s per lo stesso path e tipo. Se un dato non si legge per permesso: salute
//   'file' degradato e si prosegue (l'evento esce lo stesso, senza inode).
//
//   Mail Downloads (~/Library/Containers/com.apple.mail/...) NON si sorveglia (sta sotto Library,
//   quindi esclusa): la classe mail_allegati nasce solo dall'AXDocument letto dal SensoreAX.
//
// Il passaggio dai filtri (pausa, cartella esclusa) e dal redattore (nome del file, impronte) lo
// fa l'Annotatore.file. La cartella da sorvegliare si rilegge ogni 5 s, se le impostazioni cambiano.

import CoreServices
import Foundation

private let flagCreato = UInt32(kFSEventStreamEventFlagItemCreated)
private let flagRimosso = UInt32(kFSEventStreamEventFlagItemRemoved)
private let flagRinominato = UInt32(kFSEventStreamEventFlagItemRenamed)
private let flagModificato = UInt32(kFSEventStreamEventFlagItemModified)
private let flagFile = UInt32(kFSEventStreamEventFlagItemIsFile)

/// Callback C di FSEvents: con kFSEventStreamCreateFlagUseCFTypes i path sono un CFArray di CFString.
private let richiamoFSEvents: FSEventStreamCallback = { _, info, numero, eventPaths, eventFlags, _ in
    guard let info = info else { return }
    let sensore = Unmanaged<SensoreFile>.fromOpaque(info).takeUnretainedValue()
    let percorsi = unsafeBitCast(eventPaths, to: NSArray.self)
    var eventi: [(String, UInt32)] = []
    eventi.reserveCapacity(numero)
    for i in 0..<numero {
        guard i < percorsi.count, let p = percorsi[i] as? String else { continue }
        eventi.append((p, eventFlags[i]))
    }
    sensore.processa(eventi)
}

final class SensoreFile: NSObject, Sensore {
    let dip: Dipendenze
    private let coda = DispatchQueue(label: "org.stellakamikaze.lancillotto.file")
    private var stream: FSEventStreamRef?
    private var cartelleAttuali: [String] = []
    private var timer: DispatchSourceTimer?

    // Solo sulla coda.
    private var ultimo: [String: (tipo: String, ts: Int64)] = [:]
    private var rinominatiVia: [(path: String, ts: Int64)] = []
    private var degradatoTs: Int64 = 0

    static let finestraRinomina: Int64 = 1200
    static let debounce: Int64 = 1000

    init(dip: Dipendenze) {
        self.dip = dip
        super.init()
    }

    func avvia() {
        coda.async { self.costruisci() }
        let t = DispatchSource.makeTimerSource(queue: coda)
        t.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.costruisci()
            self.flushScaduti(oraMs())
        }
        t.resume()
        timer = t
    }

    func ferma() {
        timer?.cancel()
        timer = nil
        coda.sync { distruggi() }
    }

    // MARK: Stream

    /// (Ri)costruisce lo stream se le cartelle da sorvegliare sono cambiate. Solo sulla coda.
    private func costruisci() {
        let grezze = dip.impostazioni?.attuali.cartelle ?? ["~/Downloads", "~/Documents", "~/Desktop"]
        let cartelle = grezze
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !RegoleFiltro.cartellaEsclusa($0) }
        if cartelle == cartelleAttuali && stream != nil { return }
        distruggi()
        cartelleAttuali = cartelle
        guard !cartelle.isEmpty else { return }
        var contesto = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let flag = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                          | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, richiamoFSEvents, &contesto,
                                          cartelle as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flag) else {
            dip.registro.salute(sensore: "file", stato: "degradato", dettaglio: "FSEventStreamCreate non riuscito")
            return
        }
        FSEventStreamSetDispatchQueue(s, coda)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            dip.registro.salute(sensore: "file", stato: "degradato", dettaglio: "FSEventStreamStart non riuscito")
            return
        }
        stream = s
        dip.registro.salute(sensore: "file", stato: "ok")
    }

    private func distruggi() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    // MARK: Elaborazione (solo sulla coda)

    func processa(_ eventi: [(String, UInt32)]) {
        let ts = oraMs()
        flushScaduti(ts)
        var gestiti = Set<String>()
        var rinExist: [String] = []
        var rinGone: [String] = []
        for (path, flags) in eventi where rilevante(path, flags) && (flags & flagRinominato) != 0 {
            if esiste(path) { rinExist.append(path) } else { rinGone.append(path) }
        }
        // Appaia dentro lo stesso lotto: una sorgente sparita con una destinazione comparsa.
        var i = 0
        while i < rinExist.count && !rinGone.isEmpty {
            let dest = rinExist[i]
            let src = rinGone.removeFirst()
            emetti("file_sposta", dest, da: src, ts: ts)
            gestiti.insert(dest)
            gestiti.insert(src)
            i += 1
        }
        // Destinazioni rimaste: appaia con una rinomina recente, altrimenti è una creazione.
        while i < rinExist.count {
            let dest = rinExist[i]
            if let src = prelevaRinominato(ts) {
                emetti("file_sposta", dest, da: src, ts: ts)
            } else {
                emetti("file_crea", dest, da: nil, ts: ts)
            }
            gestiti.insert(dest)
            i += 1
        }
        // Sorgenti rimaste: si tengono un attimo; se nessuno le reclama diventano un'eliminazione.
        for src in rinGone {
            rinominatiVia.append((src, ts))
            gestiti.insert(src)
        }
        // Eventi non di rinomina.
        for (path, flags) in eventi where rilevante(path, flags) && !gestiti.contains(path) {
            if let tipo = SensoreFile.tipoSemplice(flags: flags, esiste: esiste(path)) {
                emetti(tipo, path, da: nil, ts: ts)
            }
        }
    }

    private func emetti(_ tipo: String, _ path: String, da: String?, ts: Int64) {
        if RegoleFiltro.cartellaEsclusa(path) { return }
        if let u = ultimo[path], u.tipo == tipo, ts - u.ts < SensoreFile.debounce { return }
        ultimo[path] = (tipo, ts)
        if ultimo.count > 4000 { ultimo.removeAll(keepingCapacity: true) }
        let info = leggiInfo(path, tipo: tipo)
        dip.annotatore.file(tipo: tipo, info: info, daPath: da, ts: ts)
    }

    /// Legge inode e provenienza senza aprire il file. Un permesso negato degrada la salute.
    private func leggiInfo(_ path: String, tipo: String) -> InfoFile {
        if tipo != "file_elimina" {
            var st = stat()
            if lstat(path, &st) != 0 && (errno == EACCES || errno == EPERM) {
                degrada("permesso negato su una cartella sorvegliata")
            }
        }
        return InfoFile.leggi(path)
    }

    private func degrada(_ dettaglio: String) {
        let ora = oraMs()
        if ora - degradatoTs < 600_000 { return }
        degradatoTs = ora
        dip.registro.salute(sensore: "file", stato: "degradato", dettaglio: dettaglio)
    }

    /// Le rinomine sparite non reclamate entro la finestra diventano eliminazioni.
    private func flushScaduti(_ ts: Int64) {
        var restano: [(path: String, ts: Int64)] = []
        for voce in rinominatiVia {
            if ts - voce.ts > SensoreFile.finestraRinomina {
                emetti("file_elimina", voce.path, da: nil, ts: ts)
            } else {
                restano.append(voce)
            }
        }
        rinominatiVia = restano
    }

    /// Preleva la rinomina sparita più recente ancora dentro la finestra (è la sorgente di uno sposta).
    private func prelevaRinominato(_ ts: Int64) -> String? {
        for indice in stride(from: rinominatiVia.count - 1, through: 0, by: -1) {
            if ts - rinominatiVia[indice].ts <= SensoreFile.finestraRinomina {
                return rinominatiVia.remove(at: indice).path
            }
        }
        return nil
    }

    private func rilevante(_ path: String, _ flags: UInt32) -> Bool {
        (flags & flagFile) != 0 && !RegoleFiltro.cartellaEsclusa(path)
    }

    private func esiste(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    // MARK: Puro (testato dal selftest)

    /// Tipo di un evento non di rinomina, dalle bandiere e dall'esistenza del path.
    static func tipoSemplice(flags: UInt32, esiste: Bool) -> String? {
        if (flags & flagCreato) != 0 && esiste { return "file_crea" }
        if (flags & flagRimosso) != 0 && !esiste { return "file_elimina" }
        if (flags & flagModificato) != 0 && esiste { return "file_mod" }
        return nil
    }
}
