// Guida.swift: la guida del primo avvio, un passo per schermata.
//
//   benvenuto -> accessibilita (controllo ogni secondo, va avanti da sola) -> testo (No preselezionato;
//   Sì chiede la Registrazione schermo) -> telemetria (Sì preselezionato) -> avvio al login (solo
//   informato) -> fatto. Ogni passo lascia in telemetria guida:<passo>:<esito> (la CLI scarta se è spenta).
//   Alla fine "guida_fatta": true in impostazioni.json: la guida non torna, salvo Accessibilità persa.
//   ombra: finestra chiusa a metà -> la guida torna al prossimo avvio; Accessibilità persa dopo un
//   aggiornamento -> l'app riapre la guida al passo dei permessi.

import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

enum PassoGuida: Int, CaseIterable {
    case benvenuto, accessibilita, testo, telemetria, avvio, fatto
}

final class ModelloGuida: ObservableObject {
    @Published var passo: PassoGuida = .benvenuto
    @Published var ax = AXIsProcessTrusted()
    @Published var testo = false
    @Published var telemetria = true
    let pannello: Pannello
    var chiudi: (() -> Void)?
    var apriLancillotto: (() -> Void)?
    private var timer: Timer?

    init(pannello: Pannello) {
        self.pannello = pannello
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.controlla() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func controlla() {
        let ora = AXIsProcessTrusted()
        guard ora != ax else { return }
        ax = ora
        if ora {
            pannello.registro?.meta("permesso_ax", "1")
            if passo == .accessibilita {
                pannello.registra("guida", "accessibilita:ok")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.avanti() }
            }
        }
    }

    func avanti() {
        guard let p = PassoGuida(rawValue: passo.rawValue + 1) else { return }
        withAnimation(.easeOut(duration: 0.25)) { passo = p }
    }

    func indietro() {
        guard let p = PassoGuida(rawValue: passo.rawValue - 1) else { return }
        withAnimation(.easeOut(duration: 0.25)) { passo = p }
    }

    func chiediAccessibilita() {
        let opzioni = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opzioni)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func confermaTesto() {
        pannello.impostaTesto(testo)
        pannello.registra("guida", "testo:" + (testo ? "si" : "no"))
        avanti()
    }

    func confermaTelemetria() {
        if telemetria { pannello.registra("guida", "telemetria:si") }
        pannello.impostaTelemetria(telemetria)
        avanti()
    }

    func confermaAvvio() {
        AvvioLogin.registraLogin(registro: pannello.registro)
        avanti()
    }

    func fine() {
        pannello.registra("guida", "fatto:ok")
        pannello.modificaImpostazioni? { $0["guida_fatta"] = true }
        chiudi?()
    }
}

final class FinestraGuida: NSObject, NSWindowDelegate {
    private var finestra: NSWindow?
    private var modello: ModelloGuida?
    private let pannello: Pannello
    var dopo: (() -> Void)?

    init(pannello: Pannello) {
        self.pannello = pannello
    }

    func mostra(dalPasso passo: PassoGuida = .benvenuto) {
        if finestra == nil {
            let m = ModelloGuida(pannello: pannello)
            m.passo = passo
            m.testo = pannello.testoSchermo
            m.chiudi = { [weak self] in self?.finestra?.close() }
            m.apriLancillotto = { [weak self] in self?.finestra?.close(); self?.dopo?() }
            modello = m
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Lancillotto"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: VistaGuida(m: m))
            w.center()
            finestra = w
            pannello.registra("finestra", "guida")
            pannello.registra("guida", "benvenuto:ok")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        finestra?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finestra = nil
        modello = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

struct VistaGuida: View {
    @ObservedObject var m: ModelloGuida

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Marchio()
                Text("Lancillotto").textCase(.uppercase).font(Stile.etichetta(12)).tracking(0.6)
                Spacer()
                if m.passo != .benvenuto && m.passo != .fatto {
                    Text("Passo \(m.passo.rawValue) di 4").textCase(.uppercase).font(Stile.etichetta(11)).tracking(0.6).foregroundStyle(Stile.cenere)
                }
            }
            .padding(.bottom, 28)
            Group {
                switch m.passo {
                case .benvenuto: benvenuto
                case .accessibilita: accessibilita
                case .testo: testo
                case .telemetria: telemetria
                case .avvio: avvio
                case .fatto: fatto
                }
            }
            .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 32)
        .frame(width: 560, height: 460, alignment: .topLeading)
        .background(Stile.carta)
        .foregroundStyle(Stile.inchiostro)
        .tint(Stile.azione)
    }

    private func titolo(_ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t).font(Stile.titolo(28)).accessibilityAddTraits(.isHeader)
            Text(s).font(Stile.lead).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func piede<P: View>(@ViewBuilder _ principale: () -> P) -> some View {
        HStack(spacing: 10) {
            if m.passo != .benvenuto && m.passo != .fatto {
                Button("Indietro") { m.indietro() }.buttonStyle(StileAzione(piena: false))
            }
            Spacer()
            principale()
        }
        .padding(.top, 24)
    }

    private var benvenuto: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Imparo come lavori, per alleggerirti la giornata",
                   "Lancillotto annota quali app, siti e file usi durante la giornata. Fra qualche giorno Arturo legge i riassunti e ti dice quali compiti può fare al posto tuo.")
            VStack(alignment: .leading, spacing: 8) {
                Punto("Il registro resta su questo Mac e si cancella da solo dopo 14 giorni.")
                Punto("Non registro video, foto dello schermo, audio o le lettere che scrivi.")
                Punto("Banche, password e messaggi privati restano fuori.")
            }
            Spacer(minLength: 0)
            piede { Button("Cominciamo") { m.avanti() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction) }
        }
    }

    private var accessibilita: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Un permesso, poi faccio da solo",
                   "Per sapere quale finestra e quale sito hai davanti mi serve l'Accessibilità. Premi il pulsante, cerca Lancillotto nella lista e accendi l'interruttore.")
            HStack(spacing: 10) {
                Image(systemName: m.ax ? "checkmark.circle" : "circle.dashed")
                    .font(.system(size: 18)).foregroundStyle(m.ax ? Stile.passa : Stile.cenere)
                Text(m.ax ? "Fatto: vado avanti da solo." : "Aspetto l'interruttore. Questa finestra va avanti da sola.")
                    .font(Stile.testo(14)).foregroundStyle(Stile.grafite)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            piede {
                if m.ax {
                    Button("Avanti") { m.avanti() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction)
                } else {
                    Button("Apri Accessibilità") { m.chiediAccessibilita() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var testo: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Quanto vuoi che veda?", "Puoi cambiare idea quando vuoi, dalla finestra di Lancillotto.")
            VStack(spacing: 10) {
                Scelta(titolo: "App, siti e file", spiega: "Basta per capire i tuoi flussi di lavoro. Consigliato.",
                       scelta: !m.testo) { m.testo = false }
                Scelta(titolo: "Anche il testo delle finestre",
                       spiega: "Arturo capisce meglio cosa fai, ma il registro tiene pezzi di email e documenti, anche di altre persone. Serve un permesso in più.",
                       scelta: m.testo) { m.testo = true }
            }
            Spacer(minLength: 0)
            piede { Button("Avanti") { m.confermaTesto() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction) }
        }
    }

    private var telemetria: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Aiuti a migliorare Lancillotto?",
                   "Chi lo mantiene riceve pochi dati d'uso: i passi di questa guida, i permessi, quante ore hai lavorato in fasce, i guasti. Mai app, siti, titoli, file o testo.")
            VStack(spacing: 10) {
                Scelta(titolo: "Sì, manda i dati d'uso", spiega: "Un id casuale e il solo giorno. Si spegne quando vuoi.",
                       scelta: m.telemetria) { m.telemetria = true }
                Scelta(titolo: "No", spiega: "Lancillotto funziona uguale.", scelta: !m.telemetria) { m.telemetria = false }
            }
            Spacer(minLength: 0)
            piede { Button("Avanti") { m.confermaTelemetria() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction) }
        }
    }

    private var avvio: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Mi riaccendo da solo",
                   "Quando accendi il Mac, Lancillotto riparte da solo. macOS te lo segnala con la notifica \"Elemento in background aggiunto\": è normale.")
            Punto("Per una pausa usa il pallino in alto, nella barra dei menu.")
            Punto("Se scegli \"Esci\", resto spento fino al prossimo accesso.")
            Spacer(minLength: 0)
            piede { Button("Va bene") { m.confermaAvvio() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction) }
        }
    }

    private var fatto: some View {
        VStack(alignment: .leading, spacing: 18) {
            titolo("Fatto. Ora lavora come sempre",
                   "Fra tre giorni apri Arturo e chiedigli: \"Dove mi puoi aiutare?\". Lancillotto ti ricorda la domanda nella sua finestra.")
            Punto("Il pallino verde in alto vuol dire che sto annotando.")
            Punto("Dal pallino apri Lancillotto: vedi cosa ho annotato e decidi cosa tenere fuori.")
            Spacer(minLength: 0)
            piede {
                Button("Apri Lancillotto") { m.fine(); m.apriLancillotto?() }.buttonStyle(StileAzione(piena: false))
                Button("Chiudi") { m.fine() }.buttonStyle(StileAzione()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Una scelta fra due: riquadro con bordo, quello scelto ha il bordo dell'accento.
struct Scelta: View {
    let titolo: String
    let spiega: String
    let scelta: Bool
    let azione: () -> Void
    var body: some View {
        Button(action: azione) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: scelta ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16)).foregroundStyle(scelta ? Stile.azione : Stile.cenere)
                VStack(alignment: .leading, spacing: 3) {
                    Text(titolo).font(Stile.testo(14, .semibold)).foregroundStyle(Stile.inchiostro)
                    Text(spiega).font(Stile.testo(13)).foregroundStyle(Stile.grafite)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Rectangle().fill(scelta ? Stile.azioneVelo : Stile.carta2))
            .overlay(Rectangle().strokeBorder(scelta ? Stile.azione : Stile.filetto, lineWidth: scelta ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scelta ? [.isSelected] : [])
    }
}
