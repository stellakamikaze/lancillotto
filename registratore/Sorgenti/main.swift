// main.swift: punto d'ingresso di Lancillotto.
//
//   --selftest            test puri (Redattore, Filtri, URL, HMAC, compressione, Registro su db temporaneo)
//   --scenario-sintetico  registro sintetico in LANCILLOTTO_DIR (obbligatoria), dai veri filtri e redattore
//   --versione            stampa la versione
//   --anteprima CARTELLA  PNG della guida e della finestra, chiare e scure, con dati finti
//   --scrivi-avvio-login  scrive il LaunchAgent in ~/Library/LaunchAgents (lo usa installa.sh)
//   senza argomenti       app nella barra dei menu (NSApplication, activationPolicy .accessory)
//
// Le modalità da riga di comando non toccano Accessibilità, TCC, schermo né finestre.

import AppKit
import Foundation

let argomenti = Array(CommandLine.arguments.dropFirst())

if argomenti.contains("--versione") {
    #if VELENO
    print("Lancillotto \(versioneBinario) (schema \(versioneSchema)) BUILD VELENO")
    #else
    print("Lancillotto \(versioneBinario) (schema \(versioneSchema))")
    #endif
    exit(0)
}
if argomenti.contains("--selftest") {
    exit(Selftest.esegui())
}
if let i = argomenti.firstIndex(of: "--anteprima"), i + 1 < argomenti.count {
    exit(Anteprima.esegui(argomenti[i + 1]))
}
if argomenti.contains("--scenario-sintetico") {
    exit(Scenario.esegui())
}
// Per installa.sh: scrive il LaunchAgent dell'avvio al login per questo binario. Non tocca TCC.
if argomenti.contains("--scrivi-avvio-login") {
    do {
        try AvvioLogin.scrivi(binario: Bundle.main.executablePath ?? "")
        print(AvvioLogin.percorsoPlist)
        exit(0)
    } catch {
        FileHandle.standardError.write("avvio al login non scritto: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
// macOS passa -psn_... quando l'app parte dal Finder: si ignora. Ogni altro argomento è un errore.
let sconosciuti = argomenti.filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
if let primo = sconosciuti.first, primo.hasPrefix("--") {
    FileHandle.standardError.write("argomento sconosciuto: \(primo)\nuso: Lancillotto [--selftest | --scenario-sintetico | --scrivi-avvio-login | --versione]\n".data(using: .utf8)!)
    exit(2)
}

#if VELENO
FileHandle.standardError.write("Build VELENO: filtri e redattore spenti. Solo --selftest e --scenario-sintetico.\n".data(using: .utf8)!)
exit(2)
#else
let applicazione = NSApplication.shared
let delegato = AppDelegate()
applicazione.delegate = delegato
applicazione.setActivationPolicy(.accessory)
applicazione.run()
#endif
