// Sensori.swift: avvia e ferma tutti i sensori, e definisce cosa ricevono.
//
// COME SI AGGANCIA UN SENSORE NUOVO
//   1. Crea Sorgenti/SensoreX.swift con una classe che rispetta il protocollo `Sensore`
//      e ha `init(dip: Dipendenze)`. avvia() e ferma() si chiamano sul main thread.
//   2. Sostituisci in questo file la riga di aggancio che ti spetta con
//         elenco.append(SensoreX(dip: dip))
//      (le righe "AGGANCIO_SENSORI_INPUT" e "AGGANCIO_SENSORI_SCHERMO" più sotto).
//   3. Il sensore NON scrive nel Registro da solo: passa sempre dall'Annotatore, che applica
//      i Filtri (pausa, secure input, esclusioni) e il Redattore. Le chiamate utili:
//         dip.annotatore.comando(tasti:cc:ts:)          scorciatoie (input)
//         dip.annotatore.input(tasti:click:)            conteggi del tratto (input)
//         dip.annotatore.clic(ruolo:etichetta:web:ts:)  bersaglio dei clic (input)
//         dip.annotatore.menu(percorso:ts:)             voci di menu (input)
//         dip.annotatore.appunti(cc:tipi:riservato:lunghezza:selezione:ts:)
//         dip.annotatore.file(tipo:info:daPath:ts:)     FSEvents
//         dip.annotatore.schermo(fonte:ms:righe:troncato:ts:)  testo AX od OCR
//      Le eccezioni sono la salute del sensore: dip.registro.salute(sensore:stato:dettaglio:),
//      e i dati di contesto: dip.contesto.leggi() (app attiva, finestra, AXUIElement,
//      ultimo changeCount) e dip.contesto.modifica { ... } (es. ultimoChangeCount).
//   4. Il sensore controlla i suoi permessi e, se mancano, scrive salute "degradato" e
//      resta fermo senza chiedere niente: la finestra dei permessi la apre solo App.swift.
//   5. Le impostazioni correnti (ocr, valori_campi, cartelle) sono in dip.impostazioni?.attuali;
//      nello scenario sintetico dip.impostazioni è nil.

import ApplicationServices
import Foundation

protocol Sensore: AnyObject {
    func avvia()
    func ferma()
}

/// Lo stato condiviso fra i sensori. Thread-safe: si legge una copia, si modifica sotto lock.
final class Contesto {
    struct Stato {
        var app: AppRif?
        var pid: Int32 = 0
        var finestra: OggettoRif?
        var finestraAX: AXUIElement?
        var ultimoChangeCount = -1
        var esito: Esito = .scarta
        var inattivo = false
        var pausa = false
        var permessoAX = false
    }

    private let lock = NSLock()
    private var stato = Stato()

    func leggi() -> Stato {
        lock.lock()
        defer { lock.unlock() }
        return stato
    }

    func modifica(_ cambia: (inout Stato) -> Void) {
        lock.lock()
        cambia(&stato)
        lock.unlock()
    }
}

/// Tutto quello che un sensore riceve.
struct Dipendenze {
    let registro: Registro
    let filtri: Filtri
    let redattore: Redattore
    let contesto: Contesto
    let annotatore: Annotatore
    let impostazioni: Impostazioni?
}

final class Sensori {
    let dip: Dipendenze
    private(set) var elenco: [Sensore] = []

    init(dip: Dipendenze) {
        self.dip = dip
        elenco.append(SensoreApp(dip: dip))
        elenco.append(SensoreAX(dip: dip))
        let ponteAppunti = PonteAppunti()
        elenco.append(SensoreInput(dip: dip, ponte: ponteAppunti))
        elenco.append(SensoreMenu(dip: dip))
        elenco.append(SensoreAppunti(dip: dip, ponte: ponteAppunti))
        elenco.append(SensoreFile(dip: dip))
        elenco.append(SensoreSchermo(dip: dip))
    }

    func avvia() {
        for s in elenco { s.avvia() }
    }

    func ferma() {
        for s in elenco.reversed() { s.ferma() }
    }
}

extension Notification.Name {
    /// SensoreApp la invia dopo aver passato la nuova app all'Annotatore. userInfo: "pid" (Int32).
    static let lancillottoAppAttiva = Notification.Name("org.stellakamikaze.lancillotto.appAttiva")
}
