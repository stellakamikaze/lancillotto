// CLI.swift: l'app chiama la CLI Python `lancillotto` (aggregati per la finestra, pagina mostra, telemetria).
// Il binario Swift non ha funzioni di rete: quando serve la rete (telemetria invia) lo fa la CLI.
//
//   esegui(args) -> Process su una coda di fondo -> stdout letto intero -> completamento sul main thread
//   ombra: CLI non trovata -> completamento(nil); uscita diversa da 0 -> completamento(nil) e riga in salute.

import Foundation

enum CLI {
    /// `lancillotto` nel PATH, accanto al bundle, in ~/.local/bin o in ~/bin (le due cartelle di installa.sh:
    /// l'app avviata da launchd ha un PATH corto e non le vede da sola).
    static func trova(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                      accanto: URL = Bundle.main.bundleURL.deletingLastPathComponent(),
                      casa: String = NSHomeDirectory()) -> String? {
        var candidati: [String] = []
        for d in path.split(separator: ":") { candidati.append(String(d) + "/lancillotto") }
        candidati.append(accanto.appendingPathComponent("lancillotto").path)
        candidati.append(accanto.appendingPathComponent("bin/lancillotto").path)
        candidati.append(casa + "/.local/bin/lancillotto")
        candidati.append(casa + "/bin/lancillotto")
        return candidati.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Lancia la CLI con la cartella dati dell'app. `completamento` riceve lo stdout (nil se non è partita
    /// o è uscita con errore), sempre sul main thread.
    static func esegui(_ argomenti: [String], cartella: URL, registro: Registro? = nil,
                       completamento: ((Data?) -> Void)? = nil) {
        guard let cli = trova() else {
            DispatchQueue.main.async { completamento?(nil) }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = argomenti
            var env = ProcessInfo.processInfo.environment
            env["LANCILLOTTO_DIR"] = cartella.path
            // I verbi lanciati dall'app non contano come "comandi di Claude" nella telemetria.
            env["LANCILLOTTO_DALLA_APP"] = "1"
            p.environment = env
            let uscita = Pipe()
            p.standardOutput = uscita
            p.standardError = FileHandle.nullDevice
            var dati: Data?
            do {
                try p.run()
                let letto = uscita.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                dati = p.terminationStatus == 0 ? letto : nil
                if p.terminationStatus != 0 {
                    registro?.salute(sensore: "menu", stato: "degradato",
                                     dettaglio: "lancillotto \(argomenti.first ?? ""): uscita \(p.terminationStatus)")
                }
            } catch {
                registro?.salute(sensore: "menu", stato: "guasto", dettaglio: "lancillotto \(argomenti.first ?? ""): \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completamento?(dati) }
        }
    }
}
