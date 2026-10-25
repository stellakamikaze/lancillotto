// FinestraPrincipale.swift: la finestra di Lancillotto, aperta dall'icona ("Apri Lancillotto").
// Quattro sezioni in una barra laterale: Oggi, Cosa vede Claude, Privacy, Arturo.
// I dati li tiene Pannello; qui solo la forma (DESIGN.md: carta, un accento, titoli serif).

import AppKit
import SwiftUI

enum Sezione: String, CaseIterable, Identifiable {
    case oggi, claude, privacy, arturo
    var id: String { rawValue }
    var titolo: String {
        switch self {
        case .oggi: return "Oggi"
        case .claude: return "Cosa vede Claude"
        case .privacy: return "Privacy"
        case .arturo: return "Arturo"
        }
    }
    var icona: String {
        switch self {
        case .oggi: return "sun.max"
        case .claude: return "eye"
        case .privacy: return "hand.raised"
        case .arturo: return "star"
        }
    }
}

final class FinestraPrincipale: NSObject, NSWindowDelegate {
    private var finestra: NSWindow?
    private let pannello: Pannello
    private var timer: Timer?

    init(pannello: Pannello) {
        self.pannello = pannello
    }

    func mostra(_ sezione: Sezione = .oggi) {
        if finestra == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Lancillotto"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 680, height: 480)
            w.delegate = self
            w.contentView = NSHostingView(rootView: VistaPrincipale(pannello: pannello, scelta: sezione))
            w.center()
            finestra = w
        }
        pannello.aggiorna()
        pannello.registra("finestra", sezione.rawValue)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        finestra?.makeKeyAndOrderFront(nil)
        if timer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.pannello.aggiorna() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        // Torna un'app della sola barra dei menu: niente icona nel Dock a finestra chiusa.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct VistaPrincipale: View {
    @ObservedObject var pannello: Pannello
    @State var scelta: Sezione

    var body: some View {
        NavigationSplitView {
            List(Sezione.allCases, selection: Binding(get: { scelta }, set: { if let s = $0 { scelta = s; pannello.registra("finestra", s.rawValue) } })) { s in
                Label(s.titolo, systemImage: s.icona)
                    .font(Stile.testo(14))
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            ScrollView { Dettaglio(pannello: pannello, scelta: scelta) }
                .background(Stile.carta)
        }
        .foregroundStyle(Stile.inchiostro)
        .tint(Stile.azione)
    }
}

/// Il contenuto di una sezione, senza la barra laterale (lo usa anche l'anteprima).
struct Dettaglio: View {
    @ObservedObject var pannello: Pannello
    let scelta: Sezione
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if pannello.cliAssente { AvvisoCLI() }
            switch scelta {
            case .oggi: SezioneOggi(pannello: pannello)
            case .claude: SezioneClaude(pannello: pannello)
            case .privacy: SezionePrivacy(pannello: pannello)
            case .arturo: SezioneArturo(pannello: pannello)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Titolo serif della sezione con la frase che la riassume.
struct Testata: View {
    let titolo: String
    let sintesi: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titolo).font(Stile.titolo()).accessibilityAddTraits(.isHeader)
            Text(sintesi).font(Stile.lead).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AvvisoCLI: View {
    var body: some View {
        Foglio {
            VStack(alignment: .leading, spacing: 6) {
                Text("Manca il comando lancillotto").font(Stile.testo(14, .semibold)).foregroundStyle(Stile.blocca)
                Text("Senza, la finestra non può leggere il registro. Rilancia ./installa.sh nella cartella di Lancillotto.")
                    .font(Stile.testo(13)).foregroundStyle(Stile.grafite)
            }
        }
    }
}

// MARK: - Oggi

struct SezioneOggi: View {
    @ObservedObject var pannello: Pannello

    private var fraseStato: (String, String, Color) {
        switch pannello.stato {
        case "in pausa": return ("In pausa", "Riprende da solo alle \(pannello.finoA ?? "ora indicata"). Nel frattempo non annoto niente.", Stile.cenere)
        case "fermo": return ("Fermo", "Lancillotto non sta annotando. Riaprilo dalla cartella Applicazioni.", Stile.blocca)
        default:
            return pannello.permessoAX
                ? ("Sta annotando", "Annoto app, finestre, siti e file. Il registro resta su questo Mac.", Stile.passa)
                : ("Annota a metà", "Manca l'Accessibilità: vedo solo quale app usi e per quanto.", Stile.blocca)
        }
    }

    var body: some View {
        let (titolo, frase, colore) = fraseStato
        VStack(alignment: .leading, spacing: 24) {
            Testata(titolo: "Oggi", sintesi: pannello.minutiAttivi == 0 ? "Oggi non ho ancora annotato lavoro." : "Oggi hai lavorato al Mac per \(pannello.oreAttive).")
            Foglio(fondo: Stile.cielo) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Badge(testo: titolo, colore: colore)
                        Spacer()
                    }
                    Text(frase).font(Stile.testo(14)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        if pannello.stato == "in pausa" {
                            Button("Riprendi") { pannello.pausa?(0); pannello.aggiorna() }.buttonStyle(StileAzione())
                        } else if pannello.stato != "fermo" {
                            Button("Pausa di un'ora") { pannello.pausa?(60); pannello.aggiorna() }.buttonStyle(StileAzione())
                            Button("Dimentica gli ultimi 10 minuti") { pannello.dimenticaDieci?(); pannello.aggiorna() }
                                .buttonStyle(StileAzione(piena: false))
                        }
                    }
                }
            }
            Permessi(pannello: pannello)
            VStack(alignment: .leading, spacing: 10) {
                Text("Dove è andato il tempo").font(Stile.titoloRiga())
                if pannello.app.isEmpty {
                    Text("Ancora niente da mostrare: torna fra un'ora di lavoro.").font(Stile.testo(14)).foregroundStyle(Stile.cenere)
                } else {
                    VStack(spacing: 0) {
                        ForEach(pannello.app.prefix(8)) { a in
                            HStack {
                                Text(a.nome).font(Stile.testo(14))
                                Spacer()
                                Text(a.minuti >= 60 ? "\(a.minuti / 60) h \(a.minuti % 60) min" : "\(a.minuti) min")
                                    .font(Stile.testo(14).monospacedDigit()).foregroundStyle(Stile.grafite)
                            }
                            .padding(.vertical, 9)
                            Divider().overlay(Stile.filetto)
                        }
                    }
                }
            }
        }
    }
}

struct Permessi: View {
    @ObservedObject var pannello: Pannello
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permessi").font(Stile.titoloRiga())
            RigaPermesso(nome: "Accessibilità", spiega: "Serve per sapere quale finestra e quale sito usi. Obbligatorio.",
                         dato: pannello.permessoAX,
                         apri: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            if pannello.testoSchermo {
                RigaPermesso(nome: "Registrazione schermo", spiega: "Serve solo a leggere il testo delle app che non lo danno in altro modo.",
                             dato: pannello.permessoSchermo,
                             apri: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                             chiedi: { PermessoSchermo.chiedi() })
            }
            if !pannello.sensoriGuasti.isEmpty {
                Text("Qualcosa non va in: \(pannello.sensoriGuasti.joined(separator: ", ")). Se dura, dillo a chi ti ha dato Lancillotto.")
                    .font(Stile.testo(13)).foregroundStyle(Stile.cenere)
            }
        }
    }
}

struct RigaPermesso: View {
    let nome: String
    let spiega: String
    let dato: Bool
    let apri: String
    /// Chiesto prima di aprire le Impostazioni. macOS mette l'app nella lista della Registrazione schermo
    /// solo dopo che l'app l'ha chiesta (PermessoSchermo), e installa.sh cancella la voce vecchia con tccutil.
    var chiedi: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: dato ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 16)).foregroundStyle(dato ? Stile.passa : Stile.blocca)
                .accessibilityLabel(dato ? "concesso" : "manca")
            VStack(alignment: .leading, spacing: 3) {
                Text(nome).font(Stile.testo(14, .semibold))
                Text(spiega).font(Stile.testo(13)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !dato {
                Button("Apri Impostazioni") {
                    chiedi?()
                    if let u = URL(string: apri) { NSWorkspace.shared.open(u) }
                }.buttonStyle(StileAzione(piena: false))
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Cosa vede Claude

struct SezioneClaude: View {
    @ObservedObject var pannello: Pannello
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Testata(titolo: "Cosa vede Claude",
                    sintesi: "Claude legge solo riassunti, e solo quando glielo chiedi tu. I nomi di persone e clienti diventano segnaposto.")
            Foglio {
                VStack(alignment: .leading, spacing: 10) {
                    Text(pannello.routine == 0 ? "Ancora nessun lavoro ripetuto"
                         : (pannello.routine == 1 ? "1 lavoro che ripeti" : "\(pannello.routine) lavori che ripeti"))
                        .font(Stile.titoloRiga())
                    Text(pannello.giorniAllaLettura > 0
                         ? "Le proposte diventano affidabili dopo tre giorni di uso: ne manca\(pannello.giorniAllaLettura == 1 ? "" : "no") \(pannello.giorniAllaLettura)."
                         : "Ci sono abbastanza giorni per chiedere ad Arturo dove ti può aiutare.")
                        .font(Stile.testo(14)).foregroundStyle(Stile.grafite)
                    Button("Apri la pagina completa") { pannello.apriPaginaCompleta() }.buttonStyle(StileAzione(piena: false))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Cosa esce dal Mac").font(Stile.titoloRiga())
                Punto("Quando chiedi a Claude, i riassunti passano dai server di Anthropic, come ogni conversazione con Claude.")
                Punto("Le routine che confermi diventano una nota nella memoria di Claude, solo dopo il tuo sì.")
                Punto(pannello.telemetria
                      ? "Pochi dati d'uso vanno a chi mantiene Lancillotto: li vedi e li spegni in Privacy."
                      : "I dati d'uso per chi mantiene Lancillotto sono spenti.")
            }
        }
    }
}

struct Punto: View {
    let testo: String
    init(_ testo: String) { self.testo = testo }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Stile.cenere).frame(width: 4, height: 4).offset(y: -3)
            Text(testo).font(Stile.testo(14)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Privacy

struct SezionePrivacy: View {
    @ObservedObject var pannello: Pannello
    @State private var appScelta = ""
    @State private var sito = ""
    @State private var chiediConferma = false
    @State private var mostraCoda = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Testata(titolo: "Privacy", sintesi: "Decidi tu cosa annota Lancillotto e cosa esce dal Mac.")
            Foglio {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(get: { pannello.testoSchermo }, set: { pannello.impostaTesto($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Annota anche il testo delle finestre").font(Stile.testo(14, .semibold))
                            Text("Aiuta Claude a capire cosa fai, ma porta dentro pezzi di email e documenti. Di base è spento.")
                                .font(Stile.testo(13)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.switch)
                    Divider().overlay(Stile.filetto)
                    Toggle(isOn: Binding(get: { pannello.telemetria }, set: { pannello.impostaTelemetria($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Manda i dati d'uso a chi mantiene Lancillotto").font(Stile.testo(14, .semibold))
                            Text("Passi della guida, permessi, numeri del giorno in fasce, guasti. Mai app, siti, titoli o testo.")
                                .font(Stile.testo(13)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
                        }
                    }.toggleStyle(.switch)
                    if pannello.telemetria {
                        DisclosureGroup(isExpanded: $mostraCoda) {
                            VStack(alignment: .leading, spacing: 4) {
                                if pannello.codaTelemetria.isEmpty {
                                    Text("Niente in attesa.").font(Stile.testo(13)).foregroundStyle(Stile.cenere)
                                }
                                ForEach(Array(pannello.codaTelemetria.prefix(40).enumerated()), id: \.offset) { _, r in
                                    Text(r).font(Stile.mono(12)).foregroundStyle(Stile.grafite)
                                }
                            }.padding(.top, 6)
                        } label: {
                            Text("Cosa partirà al prossimo invio (\(pannello.codaTelemetria.count))").font(Stile.testo(13))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Non annotare più").font(Stile.titoloRiga())
                HStack(spacing: 10) {
                    Picker("", selection: $appScelta) {
                        Text("Scegli un'app di oggi").tag("")
                        ForEach(pannello.app) { a in Text(a.nome).tag(a.nome) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("App da escludere")
                    Button("Escludi l'app") { pannello.escludi(app: appScelta); appScelta = "" }
                        .buttonStyle(StileAzione(piena: false)).disabled(appScelta.isEmpty)
                }
                HStack(spacing: 10) {
                    TextField("un sito, per esempio banca.it", text: $sito)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Button("Escludi il sito") { pannello.escludi(sito: sito); sito = "" }
                        .buttonStyle(StileAzione(piena: false)).disabled(!sito.contains("."))
                }
                Text("Escludere cancella anche quello che Lancillotto aveva già annotato su quell'app o quel sito.")
                    .font(Stile.testo(13)).foregroundStyle(Stile.cenere)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Dimentica").font(Stile.titoloRiga())
                HStack(spacing: 10) {
                    Button("Gli ultimi 10 minuti") { pannello.dimenticaDieci?(); pannello.aggiorna() }.buttonStyle(StileAzione(piena: false))
                    Button("Tutta la giornata di oggi") { chiediConferma = true }.buttonStyle(StileAzione(piena: false))
                }
            }
        }
        .confirmationDialog("Cancello tutto quello che Lancillotto ha annotato oggi?", isPresented: $chiediConferma) {
            Button("Cancella oggi", role: .destructive) { pannello.dimenticaOggi() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Non si può annullare.")
        }
    }
}

// MARK: - Arturo

struct SezioneArturo: View {
    @ObservedObject var pannello: Pannello
    @State private var copiato = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Testata(titolo: "Arturo",
                    sintesi: "Arturo legge i riassunti di Lancillotto, capisce che lavoro fai e ti dice cosa può fare al posto tuo.")
            Foglio(fondo: Stile.cielo) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(pannello.giorniAllaLettura > 0
                         ? "Fra \(pannello.giorniAllaLettura) giorn\(pannello.giorniAllaLettura == 1 ? "o" : "i") ci saranno abbastanza dati"
                         : "È il momento di chiedere ad Arturo")
                        .font(Stile.titoloRiga())
                    Text("Copia questo prompt e incollalo in Arturo. Puoi farlo anche prima: Arturo ti dirà cosa vede finora.")
                        .font(Stile.testo(14)).foregroundStyle(Stile.grafite).fixedSize(horizontal: false, vertical: true)
                    Text(Pannello.promptArturo)
                        .font(Stile.mono())
                        .lineSpacing(4)
                        .foregroundStyle(Stile.inchiostro)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Rectangle().fill(Stile.carta))
                        .overlay(Rectangle().strokeBorder(Stile.inchiostro, lineWidth: 1))
                    HStack(spacing: 10) {
                        Button(copiato ? "Copiato: incollalo in Arturo" : "Copia il prompt per Arturo") {
                            pannello.copiaPrompt()
                            copiato = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { copiato = false }
                        }
                        .buttonStyle(StileAzione())
                        Button("Apri Arturo nel Terminale") { pannello.chiediAdArturo() }
                            .buttonStyle(StileAzione(piena: false)).disabled(pannello.claude == nil)
                    }
                    if pannello.claude == nil {
                        Text("Non trovo Claude Code su questo Mac: installa prima Arturo. Il prompt puoi copiarlo lo stesso.")
                            .font(Stile.testo(13)).foregroundStyle(Stile.blocca)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Collegamento").font(Stile.titoloRiga())
                RigaStato(nome: "Arturo", dato: pannello.arturo, spiega: pannello.arturo ? "installato" : "non installato")
                RigaStato(nome: "Claude Code", dato: pannello.claude != nil, spiega: pannello.claude == nil ? "non trovato" : "pronto")
                RigaStato(nome: "Abilità di Lancillotto per Claude", dato: pannello.skill,
                          spiega: pannello.skill ? "collegata" : "manca: rilancia ./installa.sh")
            }
        }
    }
}

struct RigaStato: View {
    let nome: String
    let dato: Bool
    let spiega: String
    var body: some View {
        HStack {
            Image(systemName: dato ? "checkmark.circle" : "circle.dashed").foregroundStyle(dato ? Stile.passa : Stile.cenere)
            Text(nome).font(Stile.testo(14))
            Spacer()
            Text(spiega).font(Stile.testo(13)).foregroundStyle(Stile.grafite)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
