// Pannello.swift: i dati e le azioni della finestra di Lancillotto (FinestraPrincipale, Guida).
//
//   aggiorna() -> CLI `stato --json`, `oggi --json`, `telemetria mostra --json` (coda di fondo)
//              -> impostazioni.json letto dal file -> @Published sul main thread -> SwiftUI
//   azioni: pausa, riprendi, dimentica, impostazioni -> AppDelegate (stesso percorso del menu)
//           escludi app, dimentica oggi, telemetria spegni/accendi -> CLI
//   ombra: CLI assente -> cliAssente = true, la finestra lo dice e indica installa.sh
//   ombra: registro vuoto (primo giorno) -> numeri a zero, frase "ancora niente da mostrare"

import AppKit
import Foundation

struct VoceApp: Identifiable, Equatable {
    let nome: String
    let minuti: Int
    var id: String { nome }
}

final class Pannello: ObservableObject {
    // Stato del registratore
    @Published var stato = "acceso"          // acceso | in pausa | fermo
    @Published var finoA: String?
    @Published var permessoAX = false
    @Published var permessoSchermo = false
    @Published var sensoriGuasti: [String] = []
    @Published var giorniTenuti = 0
    // Oggi
    @Published var minutiAttivi = 0
    @Published var app: [VoceApp] = []
    @Published var routine = 0
    // Impostazioni
    @Published var testoSchermo = false
    @Published var telemetria = true
    @Published var codaTelemetria: [String] = []
    // Ambiente
    @Published var cliAssente = false
    @Published var arturo = false
    @Published var skill = false
    @Published var claude: String?
    @Published var caricato = false

    let cartella: URL
    weak var registro: Registro?
    var modificaImpostazioni: (((inout [String: Any]) -> Void) -> Void)?
    var pausa: ((Int) -> Void)?          // minuti; 0 = riprendi
    var dimenticaDieci: (() -> Void)?

    init(cartella: URL) {
        self.cartella = cartella
    }

    // MARK: Lettura

    func aggiorna() {
        leggiImpostazioni()
        leggiAmbiente()
        cliAssente = CLI.trova() == nil
        CLI.esegui(["stato", "--json"], cartella: cartella, registro: registro) { [weak self] d in
            self?.applicaStato(Pannello.json(d))
        }
        CLI.esegui(["oggi", "--json"], cartella: cartella, registro: registro) { [weak self] d in
            self?.applicaOggi(Pannello.json(d))
        }
        CLI.esegui(["telemetria", "mostra", "--json"], cartella: cartella, registro: registro) { [weak self] d in
            guard let j = Pannello.json(d) else { return }
            self?.telemetria = (j["accesa"] as? Bool) ?? false
            self?.codaTelemetria = ((j["in_coda"] as? [[String: Any]]) ?? []).compactMap { r in
                guard let e = r["evento"] as? String else { return nil }
                let v = (r["valore"] as? String) ?? ""
                return v.isEmpty ? e : "\(e) \(v)"
            }
        }
    }

    static func json(_ d: Data?) -> [String: Any]? {
        guard let d = d else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func applicaStato(_ j: [String: Any]?) {
        guard let j = j else { return }
        stato = (j["stato"] as? String) ?? "fermo"
        finoA = j["fino"] as? String
        let p = (j["permessi"] as? [String: Any]) ?? [:]
        permessoAX = (p["accessibilita"] as? Bool) ?? false
        permessoSchermo = (p["schermo"] as? Bool) ?? false
        let s = (j["sensori"] as? [String: [String: Any]]) ?? [:]
        sensoriGuasti = s.filter { ($0.value["stato"] as? String).map { $0 == "guasto" || $0 == "degradato" } ?? false }
            .map { $0.key }.sorted()
        giorniTenuti = (j["giorni_tenuti"] as? Int) ?? 0
        caricato = true
    }

    private func applicaOggi(_ j: [String: Any]?) {
        guard let j = j else { return }
        minutiAttivi = (j["attivo_min"] as? Int) ?? 0
        app = ((j["app"] as? [[Any]]) ?? []).compactMap { r in
            guard r.count >= 2, let n = r[0] as? String, let m = r[1] as? Int else { return nil }
            return VoceApp(nome: n, minuti: m)
        }
        routine = ((j["routine"] as? [Any]) ?? []).count
    }

    private func leggiImpostazioni() {
        let u = cartella.appendingPathComponent("impostazioni.json")
        guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        testoSchermo = (j["testo_schermo"] as? Bool) ?? false
        telemetria = (j["telemetria"] as? Bool) ?? true
    }

    private func leggiAmbiente() {
        let fm = FileManager.default
        let casa = NSHomeDirectory()
        arturo = fm.fileExists(atPath: casa + "/.claude/bin/arturo")
        skill = fm.fileExists(atPath: casa + "/.claude/skills/lancillotto/SKILL.md")
        claude = [casa + "/.local/bin/claude", casa + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: Azioni

    func impostaTesto(_ si: Bool) {
        testoSchermo = si
        modificaImpostazioni? { d in
            d["testo_schermo"] = si
            d["valori_campi"] = si
        }
        registra("impostazione", "testo:" + (si ? "si" : "no"))
        if si { PermessoSchermo.chiedi() }
    }

    func impostaTelemetria(_ si: Bool) {
        // Prima l'evento (con la telemetria ancora accesa), poi lo spegnimento, che cancella la coda.
        if !si { registra("impostazione", "telemetria:no") }
        CLI.esegui(["telemetria", si ? "accendi" : "spegni"], cartella: cartella, registro: registro) { [weak self] _ in
            if si { self?.registra("impostazione", "telemetria:si") }
            self?.aggiorna()
        }
        telemetria = si
    }

    func escludi(app nome: String) {
        CLI.esegui(["escludi", "app", nome, "--json"], cartella: cartella, registro: registro) { [weak self] _ in self?.aggiorna() }
    }

    func escludi(sito: String) {
        CLI.esegui(["escludi", "sito", sito, "--json"], cartella: cartella, registro: registro) { [weak self] _ in self?.aggiorna() }
    }

    func dimenticaOggi() {
        let inizio = Calendar.current.startOfDay(for: Date())
        let minuti = max(1, Int(Date().timeIntervalSince(inizio) / 60) + 1)
        CLI.esegui(["dimentica", String(minuti), "--json"], cartella: cartella, registro: registro) { [weak self] _ in self?.aggiorna() }
    }

    /// Il prompt da incollare in Arturo: fa partire la taratura (che lavoro fai) e poi le proposte.
    static let promptArturo = """
    Usa la skill lancillotto e leggi il registro di Lancillotto dei giorni che ci sono.
    1. Dimmi in tre righe che lavoro hai capito che faccio, e chiedimi se è giusto.
    2. Poi proponimi al massimo tre compiti che ripeto e che puoi fare tu con Arturo: per ognuno quante volte e quanto tempo, e quale strumento di Arturo useresti.
    3. Non cambiare niente sul mio computer finché non ti dico quale provare.
    """

    func copiaPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Pannello.promptArturo, forType: .string)
        registra("finestra", "arturo")
    }

    /// La domanda ad Arturo, in un file .command che il Terminale apre da solo: nessun permesso di automazione.
    func chiediAdArturo() {
        let u = cartella.appendingPathComponent("chiedi-ad-arturo.command")
        let comando = claude ?? "claude"
        let prompt = Pannello.promptArturo.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
        let testo = "#!/bin/zsh -l\ncd ~\n\"\(comando)\" \"\(prompt)\"\n"
        do {
            try testo.write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
            NSWorkspace.shared.open(u)
            registra("finestra", "arturo")
        } catch {
            registro?.salute(sensore: "menu", stato: "guasto", dettaglio: "chiedi ad Arturo: \(error.localizedDescription)")
        }
    }

    func apriPaginaCompleta() {
        CLI.esegui(["mostra", "--apri"], cartella: cartella, registro: registro)
    }

    func registra(_ evento: String, _ valore: String) {
        CLI.esegui(["telemetria", "registra", evento, valore], cartella: cartella, registro: registro)
    }

    // MARK: Testi

    var oreAttive: String {
        let h = minutiAttivi / 60, m = minutiAttivi % 60
        if minutiAttivi == 0 { return "ancora nessun minuto" }
        return h == 0 ? "\(m) minuti" : (m == 0 ? "\(h) ore" : "\(h) ore e \(m) minuti")
    }

    var giorniAllaLettura: Int { max(0, 3 - giorniTenuti) }
}
