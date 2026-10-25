// Stile.swift: i token visivi di Lancillotto (DESIGN.md), presi dalla landing di Arturo di oggi
// (arturo-landing/DESIGN.md, sito/stile/colori.css). Carta grigio caldo, inchiostro quasi nero, un solo
// blu d'azione, la stella arancio solo nel marchio, angoli vivi. In modo scuro la fascia "vuoto".
// Font OFL dal bundle (Contents/Resources/Font), registrati per il solo processo: Archivo variabile
// (titoli larghi e leggeri, etichette strette maiuscole) e Atkinson Next per il testo.

import AppKit
import CoreText
import SwiftUI

enum Stile {
    private static func dinamico(_ chiaro: UInt32, _ scuro: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? scuro : chiaro
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }

    static let carta = dinamico(0xf5f5f3, 0x05080c)
    static let carta2 = dinamico(0xebebe8, 0x10151c)
    static let cielo = dinamico(0xd7ebff, 0x10151c)
    static let inchiostro = dinamico(0x0b0d10, 0xe8ecf1)
    static let grafite = dinamico(0x2a2e35, 0xd3d9e0)
    static let cenere = dinamico(0x59606a, 0x9ba5b1)
    static let filetto = dinamico(0xd6d8d4, 0x232b35)
    static let azione = dinamico(0x0b5fff, 0x5c95ff)
    static let azioneVelo = dinamico(0xe3efff, 0x14233d)
    static let passa = dinamico(0x1f7a45, 0x7dcca0)
    static let blocca = dinamico(0xb8301d, 0xff9a8a)
    static let stella = Color(red: 0xf2 / 255, green: 0xa2 / 255, blue: 0x4a / 255)

    // Archivo variabile: assi peso ('wght') e larghezza ('wdth').
    private static func archivo(_ p: CGFloat, peso: CGFloat, larghezza: CGFloat) -> Font {
        let assi: [NSNumber: NSNumber] = [NSNumber(value: 0x77676874): NSNumber(value: Double(peso)),
                                          NSNumber(value: 0x77647468): NSNumber(value: Double(larghezza))]
        // Il file di Archivo chiama la famiglia "Archivo SemiBold": si sceglie per nome PostScript, poi gli assi.
        let d = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: "ArchivoRoman-Thin",
                                                      kCTFontVariationAttribute: assi] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(d, p, nil))
    }

    /// Titoli: Archivo largo e leggero (The Due Larghezze Rule).
    static func titolo(_ p: CGFloat = 30) -> Font { archivo(p, peso: 300, larghezza: 112) }
    static func titoloRiga(_ p: CGFloat = 19) -> Font { archivo(p, peso: 380, larghezza: 108) }
    /// Etichette e pulsanti: Archivo stretto, da scrivere in maiuscolo.
    static func etichetta(_ p: CGFloat = 12) -> Font { archivo(p, peso: 560, larghezza: 75) }

    private static let sans = "Atkinson Hyperlegible Next"
    static func testo(_ p: CGFloat = 14, _ peso: Font.Weight = .regular) -> Font { .custom(sans, size: p).weight(peso) }
    static let meta = Font.custom(sans, size: 12)
    /// Atkinson Mono, solo per ciò che si copia in Claude (The Terminale Mono Rule).
    static func mono(_ p: CGFloat = 12.5) -> Font { .custom("AtkinsonHyperlegibleMono-ExtraLight_Regular", size: p) }
    static let lead = Font.custom(sans, size: 16)

    /// Una volta all'avvio: i font del bundle, solo per questo processo.
    static func registraFont() {
        guard let cartella = Bundle.main.resourceURL?.appendingPathComponent("Font") else { return }
        let file = (try? FileManager.default.contentsOfDirectory(at: cartella, includingPropertiesForKeys: nil)) ?? []
        for u in file where u.pathExtension == "woff2" {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }
}

/// Un blocco su carta con il filetto sopra, come gli elenchi della landing: niente raggio, niente ombra.
struct Foglio<Contenuto: View>: View {
    var fondo: Color = Stile.carta2
    @ViewBuilder var contenuto: Contenuto
    var body: some View {
        contenuto
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(fondo))
            .overlay(alignment: .top) { Rectangle().fill(Stile.inchiostro).frame(height: 1) }
    }
}

/// Pulsante principale: blocco blu pieno e squadrato. Secondario: contorno d'inchiostro. Etichetta stretta maiuscola.
struct StileAzione: ButtonStyle {
    var piena = true
    @Environment(\.isEnabled) private var attivo
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textCase(.uppercase)
            .font(Stile.etichetta(12.5))
            .tracking(0.5)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .foregroundStyle(piena ? Color.white : Stile.inchiostro)
            .background(Rectangle().fill(piena ? Stile.azione : Color.clear))
            .overlay(Rectangle().strokeBorder(piena ? Color.clear : Stile.inchiostro, lineWidth: 1))
            .opacity(attivo ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// Esito: etichetta piccola stretta maiuscola con bordo, mai fondo pieno.
struct Badge: View {
    let testo: String
    let colore: Color
    var body: some View {
        Text(testo)
            .textCase(.uppercase)
            .font(Stile.etichetta(11))
            .tracking(0.6)
            .foregroundStyle(colore)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Rectangle().strokeBorder(colore, lineWidth: 1))
    }
}

/// Il marchio: l'icona dell'app, o il punto della stella se l'icona manca.
struct Marchio: View {
    var lato: CGFloat = 22
    var body: some View {
        Group {
            if let i = NSApp.applicationIconImage {
                Image(nsImage: i).resizable().interpolation(.high)
            } else {
                Circle().fill(Stile.stella)
            }
        }
        .frame(width: lato, height: lato)
        .accessibilityHidden(true)
    }
}
