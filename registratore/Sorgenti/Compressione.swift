// Compressione.swift: DEFLATE raw per `riga.testo_z` e `campo.valore_z`.
//
// Apple COMPRESSION_ZLIB produce DEFLATE raw (RFC 1951), senza intestazione zlib.
// Python lo legge con zlib.decompress(b, -15) (docs/CONTRATTO.md).

import Compression
import Foundation

enum Compressione {
    /// Il DEFLATE raw di una stringa vuota: un blocco finale fisso vuoto.
    private static let vuoto = Data([0x03, 0x00])

    static func comprimi(_ testo: String) -> Data {
        comprimi(Data(testo.utf8))
    }

    static func comprimi(_ sorgente: Data) -> Data {
        if sorgente.isEmpty { return vuoto }
        let capienza = sorgente.count + sorgente.count / 8 + 64
        var uscita = Data(count: capienza)
        let n = uscita.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            sorgente.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capienza,
                    src.bindMemory(to: UInt8.self).baseAddress!, sorgente.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        // n == 0 vuol dire buffer troppo piccolo: con questa capienza non succede, ma
        // nel dubbio si salva il blocco "stored" fatto a mano, sempre valido.
        if n == 0 { return blocchiNonCompressi(sorgente) }
        uscita.count = n
        return uscita
    }

    /// DEFLATE raw con soli blocchi "stored" (tipo 00): valido per ogni decoder.
    private static func blocchiNonCompressi(_ s: Data) -> Data {
        var out = Data()
        var i = 0
        let byte = [UInt8](s)
        while i < byte.count {
            let n = min(65535, byte.count - i)
            let finale: UInt8 = (i + n >= byte.count) ? 1 : 0
            out.append(finale)
            out.append(UInt8(n & 0xff))
            out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xff))
            out.append(UInt8((~n >> 8) & 0xff))
            out.append(contentsOf: byte[i..<(i + n)])
            i += n
        }
        return out
    }

    static func decomprimi(_ sorgente: Data) -> Data? {
        if sorgente.isEmpty { return nil }
        var capienza = max(256, sorgente.count * 8)
        while capienza <= 64 * 1024 * 1024 {
            var uscita = Data(count: capienza)
            let n = uscita.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                sorgente.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capienza,
                        src.bindMemory(to: UInt8.self).baseAddress!, sorgente.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            // Se l'uscita riempie il buffer, potrebbe essere troncata: si riprova più grande.
            if n > 0 && n < capienza {
                uscita.count = n
                return uscita
            }
            if n == 0 && sorgente == vuoto { return Data() }
            if n == 0 { return nil }
            capienza *= 4
        }
        return nil
    }

    static func decomprimiTesto(_ sorgente: Data) -> String? {
        guard let d = decomprimi(sorgente) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
