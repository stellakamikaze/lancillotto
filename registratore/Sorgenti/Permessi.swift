// Permessi.swift: l'avvio al login (LaunchAgent) e il passaggio a launchd.
// La guida del primo avvio, con i permessi, sta in Guida.swift (25/10/2026, prima era qui in AppKit).
// Lo stato dell'avvio al login va in salute (sensore "avvio_login"). Se la persona salta il passo nella
// guida, meta.avvio_login_saltato vale 1 e l'app non lo registra da sola.

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// Chiede la Registrazione schermo. Su macOS 15 e 26 CGRequestScreenCaptureAccess non mostra niente e non
/// mette l'app nella lista: tccd risponde "Service kTCCServiceScreenCapture does not allow prompting" (log del
/// 25/10/2026). L'app entra nella lista quando prova a leggere lo schermo con ScreenCaptureKit.
enum PermessoSchermo {
    static func chiedi() {
        if CGPreflightScreenCaptureAccess() { return }
        if #available(macOS 15, *) {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { _, _ in }
        } else {
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

/// Avvio al login con un LaunchAgent in ~/Library/LaunchAgents. SMAppService.mainApp con la firma
/// ad-hoc risponde .notFound anche da ~/Applications (prova del 25/10/2026), e il LaunchAgent dà in
/// più il riavvio dopo un crash: KeepAlive con SuccessfulExit falso, quindi "Esci" (exit 0) non riparte.
enum AvvioLogin {
    static let etichetta = "org.stellakamikaze.lancillotto"

    static func statoLogin() -> String {
        if gestitoDaLaunchd() { return "Avvio al login: attivo." }
        if attivo() { return "Avvio al login: attivo dal prossimo accesso." }
        return "Avvio al login: non attivo."
    }

    /// Scrive il LaunchAgent e riporta l'esito in salute. Non lo carica subito: lo carica launchd
    /// al prossimo accesso, oppure installa.sh con launchctl bootstrap.
    @discardableResult
    static func registraLogin(registro: Registro?) -> String {
        do {
            try scrivi(binario: Bundle.main.executablePath ?? "")
            let stato = statoLogin()
            registro?.salute(sensore: "avvio_login", stato: "ok", dettaglio: stato)
            return "Fatto. " + stato
        } catch {
            let m = "Avvio al login non riuscito: \(error)"
            registro?.salute(sensore: "avvio_login", stato: "guasto", dettaglio: m)
            return m
        }
    }

    /// Aperta a mano (Finder, o "Esci e riapri" di macOS dopo la Registrazione schermo) mentre il suo
    /// LaunchAgent è caricato: l'app passa la mano a launchd, così torna il riavvio dopo un blocco (#3935).
    /// Un processo staccato aspetta 2 s e lancia `launchctl kickstart`; questa istanza intanto esce.
    /// Vero se ha passato la mano: chi chiama deve uscire subito.
    static func passaALaunchd() -> Bool {
        guard !gestitoDaLaunchd(), attivo() else { return false }
        let servizio = "gui/\(getuid())/\(etichetta)"
        let prova = Process()
        prova.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        prova.arguments = ["print", servizio]
        prova.standardOutput = FileHandle.nullDevice
        prova.standardError = FileHandle.nullDevice
        guard (try? prova.run()) != nil else { return false }
        prova.waitUntilExit()
        guard prova.terminationStatus == 0 else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /bin/launchctl kickstart \(servizio)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil
    }
    static var percorsoPlist: String { NSHomeDirectory() + "/Library/LaunchAgents/" + etichetta + ".plist" }

    /// Puro, testato dal selftest: il contenuto del LaunchAgent per un binario.
    static func contenuto(binario: String) -> [String: Any] {
        [
            "Label": etichetta,
            "ProgramArguments": [binario],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 10,
        ]
    }

    static func scrivi(binario: String) throws {
        guard binario.hasPrefix("/") else { throw NSError(domain: "Lancillotto", code: 1, userInfo: [NSLocalizedDescriptionKey: "percorso del binario sconosciuto"]) }
        let dati = try PropertyListSerialization.data(fromPropertyList: contenuto(binario: binario), format: .xml, options: 0)
        let cartella = (percorsoPlist as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: cartella, withIntermediateDirectories: true)
        try dati.write(to: URL(fileURLWithPath: percorsoPlist), options: .atomic)
    }

    /// Il LaunchAgent c'è e lancia proprio questo binario.
    static func attivo() -> Bool {
        guard let d = FileManager.default.contents(atPath: percorsoPlist),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let argomenti = p["ProgramArguments"] as? [String] else { return false }
        return argomenti.first == Bundle.main.executablePath
    }

    /// Questa istanza l'ha lanciata launchd con la nostra etichetta.
    static func gestitoDaLaunchd() -> Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == etichetta
    }

    /// Puro, testato dal selftest: si registra da solo solo se non è registrato, la persona non
    /// l'ha saltato e l'app sta in una cartella Applicazioni (mai una build di prova).
    static func daRegistrare(nonRegistrato: Bool, saltato: Bool, percorsoApp: String, home: String) -> Bool {
        guard nonRegistrato, !saltato else { return false }
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return percorsoApp.hasPrefix(h + "/Applications/") || percorsoApp.hasPrefix("/Applications/")
    }

    /// Al lancio: registra se serve e scrive sempre la riga "avvio_login" in salute.
    static func allAvvio(registro: Registro) {
        let saltato = registro.senzaCoda { d in try d.testo("SELECT valore FROM meta WHERE chiave = 'avvio_login_saltato'") } ?? nil
        if daRegistrare(nonRegistrato: !attivo(), saltato: saltato == "1",
                        percorsoApp: Bundle.main.bundlePath, home: NSHomeDirectory()) {
            registraLogin(registro: registro)
            return
        }
        let ok = attivo()
        registro.salute(sensore: "avvio_login", stato: ok ? "ok" : (saltato == "1" ? "spento" : "degradato"),
                        dettaglio: statoLogin())
    }
}
