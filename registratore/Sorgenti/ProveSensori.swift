// ProveSensori.swift: test puri dei sensori di input, menu, appunti e file.
//
// Non tocca AX, TCC, schermo né finestre: prova solo le funzioni pure (nome canonico delle
// scorciatoie, percorso dei menu, riconoscimento dell'incolla e del tipo riservato, mappatura
// delle bandiere di FSEvents). Il selftest la chiama con una riga, come SelftestSchermo.

import AppKit
import CoreServices
import Foundation

enum ProveSensori {
    /// Elenco (esito, nome) dei controlli, nello stile di SelftestSchermo.controlli().
    static func controlli() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func vero(_ c: Bool, _ nome: String) { out.append((c, nome)) }
        func uguale(_ a: String?, _ b: String?, _ nome: String) {
            out.append((a == b, a == b ? nome : "\(nome): \(a ?? "nil") invece di \(b ?? "nil")"))
        }

        // Nome canonico delle scorciatoie (keyCode: a=0, z=6, x=7, c=8, v=9).
        uguale(SensoreInput.nomeComando(.command, 8), "cmd+c", "cmd+c")
        uguale(SensoreInput.nomeComando(.command, 9), "cmd+v", "cmd+v")
        uguale(SensoreInput.nomeComando([.command, .shift], 6), "shift+cmd+z", "shift+cmd+z ordinato")
        uguale(SensoreInput.nomeComando([.command, .control, .option, .shift], 0), "ctrl+opt+shift+cmd+a", "ordine completo")
        uguale(SensoreInput.nomeComando(.control, 8), "ctrl+c", "ctrl+c")
        vero(SensoreInput.nomeComando(.shift, 8) == nil, "senza cmd né ctrl: niente comando")
        vero(SensoreInput.nomeComando([], 8) == nil, "nessun modificatore: niente comando")
        vero(SensoreInput.nomeComando(.command, 9999) == nil, "tasto fuori mappa: niente comando")

        // Percorso dei menu e riconoscimento dell'incolla.
        uguale(SensoreMenu.percorso(["Archivio", "Esporta come PDF…"]), "Archivio > Esporta come PDF…", "percorso menu")
        uguale(SensoreMenu.percorso(["Modifica"]), "Modifica", "percorso di una sola voce")
        vero(SensoreMenu.èIncolla("Incolla"), "incolla it")
        vero(SensoreMenu.èIncolla("Incolla e adatta stile"), "incolla con stile")
        vero(SensoreMenu.èIncolla("Paste"), "paste en")
        vero(!SensoreMenu.èIncolla("Copia"), "copia non è incolla")
        vero(!SensoreMenu.èIncolla("Esporta"), "esporta non è incolla")

        // Tipo riservato degli appunti.
        vero(SensoreAppunti.riservato(["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]), "concealed riservato")
        vero(SensoreAppunti.riservato(["org.nspasteboard.TransientType"]), "transient riservato")
        vero(!SensoreAppunti.riservato(["public.utf8-plain-text", "public.html"]), "testo normale non riservato")
        vero(!SensoreAppunti.riservato([]), "nessun tipo non è riservato")

        // Mappatura delle bandiere di FSEvents (non di rinomina).
        let creato = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        let rimosso = UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)
        let modificato = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        uguale(SensoreFile.tipoSemplice(flags: creato, esiste: true), "file_crea", "creato ed esiste")
        uguale(SensoreFile.tipoSemplice(flags: rimosso, esiste: false), "file_elimina", "rimosso e non esiste")
        uguale(SensoreFile.tipoSemplice(flags: modificato, esiste: true), "file_mod", "modificato ed esiste")
        vero(SensoreFile.tipoSemplice(flags: creato, esiste: false) == nil, "creato ma non esiste: niente")
        vero(SensoreFile.tipoSemplice(flags: rimosso, esiste: true) == nil, "rimosso ma esiste ancora: niente")

        return out
    }
}
