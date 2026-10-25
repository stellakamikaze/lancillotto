// Hmac.swift: chiave locale e HMAC-SHA256 (docs/CONTRATTO.md, "Tempo e testo").
//
// La chiave sta nel file `chiave` della cartella dati: 32 byte casuali, permessi 600,
// creata qui al primo avvio se manca. Se il file esiste con una lunghezza diversa da 32
// il registratore si ferma: riscriverla renderebbe illeggibili tutte le impronte già salvate.
// Se il file c'è ma non si legge (permessi, proprietario, una cartella con quel nome), si ferma
// con un errore chiaro: niente ricorsione, niente crash.

import CryptoKit
import Foundation
import Security

enum ErroreChiave: Error, CustomStringConvertible {
    case lunghezza(Int)
    case casuale(Int32)
    case scrittura(String)
    case illeggibile(String)

    var description: String {
        switch self {
        case .lunghezza(let n): return "il file chiave ha \(n) byte invece di 32"
        case .casuale(let c): return "SecRandomCopyBytes ha restituito \(c)"
        case .scrittura(let m): return "scrittura della chiave non riuscita: \(m)"
        case .illeggibile(let m): return "il file chiave c'è ma non si legge: \(m)"
        }
    }
}

struct Hmac {
    let chiave: SymmetricKey

    init(chiave: SymmetricKey) {
        self.chiave = chiave
    }

    /// Chiave fissa per i test puri: mai usata su un registro vero.
    static func diProva() -> Hmac {
        Hmac(chiave: SymmetricKey(data: Data(repeating: 7, count: 32)))
    }

    /// Legge la chiave dalla cartella dati, oppure la crea (32 byte, file 600) se manca.
    static func caricaOCrea(cartella: URL) throws -> Hmac {
        try caricaOCrea(cartella: cartella, tentativi: 2)
    }

    private static func caricaOCrea(cartella: URL, tentativi: Int) throws -> Hmac {
        let percorso = cartella.appendingPathComponent("chiave").path
        if let dati = FileManager.default.contents(atPath: percorso) {
            guard dati.count == 32 else { throw ErroreChiave.lunghezza(dati.count) }
            chmod(percorso, 0o600)
            return Hmac(chiave: SymmetricKey(data: dati))
        }
        var st = stat()
        if lstat(percorso, &st) == 0 {
            // C'è qualcosa che non si legge: riscriverlo perderebbe la chiave, aspettare non serve.
            let motivo: String
            if (st.st_mode & S_IFMT) == S_IFDIR {
                motivo = "è una cartella"
            } else {
                let fd = open(percorso, O_RDONLY)
                motivo = fd < 0 ? String(cString: strerror(errno)) : "lettura non riuscita"
                if fd >= 0 { close(fd) }
            }
            throw ErroreChiave.illeggibile(motivo + " (" + percorso + ")")
        }
        var byte = [UInt8](repeating: 0, count: 32)
        let esito = SecRandomCopyBytes(kSecRandomDefault, byte.count, &byte)
        guard esito == errSecSuccess else { throw ErroreChiave.casuale(esito) }
        // O_EXCL: se un altro processo l'ha creata nel frattempo, non la sovrascrive.
        let fd = open(percorso, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            // Un altro processo l'ha creata adesso: si rilegge una volta sola.
            if errno == EEXIST && tentativi > 0 { return try caricaOCrea(cartella: cartella, tentativi: tentativi - 1) }
            throw ErroreChiave.scrittura(String(cString: strerror(errno)))
        }
        let scritti = byte.withUnsafeBytes { write(fd, $0.baseAddress, 32) }
        fsync(fd)
        close(fd)
        guard scritti == 32 else { throw ErroreChiave.scrittura("scritti \(scritti) byte") }
        return Hmac(chiave: SymmetricKey(data: Data(byte)))
    }

    /// HMAC-SHA256 del testo UTF-8, in hex dei primi 16 byte (32 caratteri).
    func hex(_ testo: String) -> String {
        let codice = HMAC<SHA256>.authenticationCode(for: Data(testo.utf8), using: chiave)
        return esadecimale(Data(codice).prefix(16))
    }
}

/// SHA-256 nudo, in hex dei primi 16 byte. Solo per `riga.h`, che si calcola sul testo già redatto.
func sha256Breve(_ testo: String) -> String {
    let d = SHA256.hash(data: Data(testo.utf8))
    return esadecimale(Data(d).prefix(16))
}

func esadecimale(_ dati: Data) -> String {
    let cifre = Array("0123456789abcdef".utf8)
    var out = [UInt8]()
    out.reserveCapacity(dati.count * 2)
    for b in dati {
        out.append(cifre[Int(b >> 4)])
        out.append(cifre[Int(b & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
}
