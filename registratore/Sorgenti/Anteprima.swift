// Anteprima.swift: `Lancillotto --anteprima CARTELLA` disegna in PNG la guida e la finestra, chiare e scure,
// con dati finti. Serve a guardare l'interfaccia senza aprirla sullo schermo (QA, README). Non legge il
// registro, non lancia la CLI, non tocca impostazioni né permessi.

import AppKit
import SwiftUI

enum Anteprima {
    static func esegui(_ cartella: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Stile.registraFont()
        let uscita = URL(fileURLWithPath: cartella, isDirectory: true)
        try? FileManager.default.createDirectory(at: uscita, withIntermediateDirectories: true)
        let p = Pannello(cartella: uscita)
        p.stato = "acceso"; p.permessoAX = true; p.minutiAttivi = 274; p.giorniTenuti = 2; p.routine = 3
        p.app = [VoceApp(nome: "Mail", minuti: 96), VoceApp(nome: "Firefox", minuti: 81), VoceApp(nome: "Excel", minuti: 52),
                 VoceApp(nome: "Anteprima", minuti: 23), VoceApp(nome: "Finder", minuti: 14)]
        p.telemetria = true; p.codaTelemetria = ["permesso ax:si", "giorno ore:3", "guida fatto:ok"]
        p.arturo = true; p.skill = true; p.claude = "/Users/x/.local/bin/claude"
        p.caricato = true
        var fatte = 0
        for (nome, aspetto) in [("chiaro", NSAppearance.Name.aqua), ("scuro", NSAppearance.Name.darkAqua)] {
            for s in Sezione.allCases {
                let vista = HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Sezione.allCases) { x in
                            Label(x.titolo, systemImage: x.icona).font(Stile.testo(14))
                                .foregroundStyle(x == s ? Stile.azione : Stile.inchiostro)
                        }
                        Spacer()
                    }
                    .padding(.top, 44).padding(.horizontal, 18).frame(width: 190, alignment: .leading)
                    .background(Stile.carta2)
                    Dettaglio(pannello: p, scelta: s).frame(maxHeight: .infinity, alignment: .top).background(Stile.carta)
                }
                .foregroundStyle(Stile.inchiostro).tint(Stile.azione)
                fatte += disegna(vista, NSSize(width: 860, height: 700), aspetto,
                                 uscita.appendingPathComponent("finestra-\(s.rawValue)-\(nome).png"))
            }
            for passo in PassoGuida.allCases {
                let m = ModelloGuida(pannello: p)
                m.passo = passo
                fatte += disegna(VistaGuida(m: m), NSSize(width: 560, height: 460), aspetto,
                                 uscita.appendingPathComponent("guida-\(passo.rawValue)-\(nome).png"))
            }
        }
        print("ANTEPRIMA \(fatte) immagini in \(uscita.path)")
        return fatte > 0 ? 0 : 1
    }

    private static func disegna<V: View>(_ vista: V, _ lato: NSSize, _ aspetto: NSAppearance.Name, _ file: URL) -> Int {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: lato), styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: aspetto)
        let h = NSHostingView(rootView: vista.frame(width: lato.width, height: lato.height))
        h.frame = NSRect(origin: .zero, size: lato)
        w.contentView = h
        h.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return 0 }
        h.cacheDisplay(in: h.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 0 }
        return (try? png.write(to: file)) != nil ? 1 : 0
    }
}
