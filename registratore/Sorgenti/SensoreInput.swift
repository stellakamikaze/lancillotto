// SensoreInput.swift: scorciatoie, conteggi di tasti e clic, bersaglio dei clic.
//
//   NSEvent.addGlobalMonitorForEvents (keyDown, leftMouseDown) -> Annotatore
//   keyDown:  SOLO le combinazioni con cmd o ctrl diventano un evento 'comando' col nome
//             canonico (es. "shift+cmd+z"); per ogni altro tasto cresce solo un contatore.
//             MAI i caratteri digitati: il nome viene dal keyCode, non dal testo dell'evento.
//   leftMouseDown: contatore del clic e bersaglio via AXUIElementCopyElementAtPosition
//             (ruolo ed etichetta solo per i ruoli del CONTRATTO; dentro un AXWebArea solo il
//             ruolo con web=1). Un bersaglio di un'altra app (pid diverso da quello attivo: una
//             finestra in secondo piano, un pannello che non si attiva) non si annota: il filtro
//             vale per l'app attiva, non per quella sotto il cursore.
//   permesso: un controllo ogni 5 s. Quando l'Accessibilità arriva (o va via) i monitor si
//             registrano di nuovo e la salute "input" si riscrive.
//   secure input: se IsSecureEventInputEnabled() nient'altro, nemmeno i comandi né i conteggi.
//
// I conteggi e i comandi entrano solo quando il filtro corrente dà `pieno` (Contesto.esito):
// così il tratto 'escluso' o 'protetto' resta "solo app e durata".
// Al cmd+c (o cmd+x) legge l'AXSelectedText dell'elemento a fuoco e lo passa al PonteAppunti:
// il SensoreAppunti lo userà come fonte 'selezione' quando il changeCount cambia.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Scambio dell'ultima selezione vista a una copia, dal SensoreInput al SensoreAppunti.
final class PonteAppunti {
    private let lock = NSLock()
    private var selezione: String?
    private var ts: Int64 = 0

    /// Registra la selezione vista a una copia.
    func imposta(_ s: String, _ ora: Int64) {
        lock.lock()
        selezione = s
        ts = ora
        lock.unlock()
    }

    /// Restituisce e consuma la selezione, se vista entro `entro` millisecondi da `ora`.
    func preleva(entro: Int64, _ ora: Int64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = selezione, ora - ts <= entro else { return nil }
        selezione = nil
        return s
    }
}

final class SensoreInput: NSObject, Sensore {
    let dip: Dipendenze
    let ponte: PonteAppunti
    private var monitorTasti: Any?
    private var monitorClic: Any?
    private let sistema = AXUIElementCreateSystemWide()
    private var permessoNoto: Bool?
    private var controllo: Timer?

    init(dip: Dipendenze, ponte: PonteAppunti) {
        self.dip = dip
        self.ponte = ponte
        super.init()
        AXUIElementSetMessagingTimeout(sistema, 0.25)
    }

    func avvia() {
        controllaPermesso()
        let t = Timer(timeInterval: 5, target: self, selector: #selector(controllaPermesso), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        controllo = t
    }

    func ferma() {
        controllo?.invalidate()
        controllo = nil
        togliMonitor()
    }

    private func registraMonitor() {
        togliMonitor()
        monitorTasti = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.tasto(e)
        }
        monitorClic = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.clic(e)
        }
    }

    private func togliMonitor() {
        if let m = monitorTasti { NSEvent.removeMonitor(m) }
        if let m = monitorClic { NSEvent.removeMonitor(m) }
        monitorTasti = nil
        monitorClic = nil
    }

    /// Senza Accessibilità i monitor globali dei tasti non ricevono eventi. Quando il permesso
    /// cambia, i monitor si registrano di nuovo e la salute dice lo stato vero.
    @objc private func controllaPermesso() {
        let fidato = AXIsProcessTrusted()
        guard let azione = SensoreInput.cambioPermesso(prima: permessoNoto, ora: fidato) else { return }
        let primo = permessoNoto == nil
        permessoNoto = fidato
        registraMonitor()
        if azione == "ok" {
            dip.registro.salute(sensore: "input", stato: "ok", dettaglio: primo ? nil : "Accessibilità concessa: monitor registrati di nuovo")
        } else {
            dip.registro.salute(sensore: "input", stato: "degradato", dettaglio: "Accessibilità non concessa: niente scorciatoie né bersaglio dei clic")
        }
    }

    /// nil se niente è cambiato, altrimenti lo stato da scrivere in salute ("ok" o "degradato").
    static func cambioPermesso(prima: Bool?, ora: Bool) -> String? {
        if prima == ora { return nil }
        return ora ? "ok" : "degradato"
    }

    /// Le scorciatoie di incolla (cmd+v, shift+cmd+v, opt+shift+cmd+v...) portano il changeCount.
    static func portaCC(_ nome: String) -> Bool {
        nome == "cmd+v" || nome.hasSuffix("+cmd+v")
    }

    // MARK: Tastiera

    private func tasto(_ e: NSEvent) {
        // Secure input: niente, nemmeno il conteggio (CONTRATTO).
        if IsSecureEventInputEnabled() { return }
        let stato = dip.contesto.leggi()
        guard stato.esito == .pieno else { return }
        let ts = oraMs()
        // Ogni tasto è un conteggio del tratto; mai il carattere.
        dip.annotatore.input(tasti: 1, click: 0)
        guard let nome = SensoreInput.nomeComando(e.modifierFlags, e.keyCode) else { return }
        // Al cmd+v il changeCount corrente lega l'incolla alla copia che l'ha riempito.
        let cc = SensoreInput.portaCC(nome) ? NSPasteboard.general.changeCount : nil
        dip.annotatore.comando(tasti: nome, cc: cc, ts: ts)
        // Alla copia o al taglio si tiene la selezione dell'elemento a fuoco per le impronte.
        if (nome == "cmd+c" || nome == "cmd+x"), stato.permessoAX, stato.pid != 0 {
            if let sel = leggiSelezione(pid: stato.pid) { ponte.imposta(sel, ts) }
        }
    }

    /// AXSelectedText dell'elemento a fuoco dell'app attiva, mai da un AXSecureTextField.
    private func leggiSelezione(pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focus = AX.elemento(app, kAXFocusedUIElementAttribute) else { return nil }
        let ruolo = AX.stringa(focus, kAXRoleAttribute)
        let subruolo = AX.stringa(focus, kAXSubroleAttribute)
        if ruolo == "AXSecureTextField" || subruolo == "AXSecureTextField" { return nil }
        guard let sel = AX.stringa(focus, kAXSelectedTextAttribute), !sel.isEmpty else { return nil }
        return String(sel.prefix(5000))
    }

    // MARK: Mouse

    private func clic(_ e: NSEvent) {
        let stato = dip.contesto.leggi()
        guard stato.esito == .pieno else { return }
        dip.annotatore.input(tasti: 0, click: 1)
        guard stato.permessoAX, let punto = e.cgEvent?.location else { return }
        bersaglio(punto, pidAttivo: stato.pid, ts: oraMs())
    }

    /// Elemento sotto il clic: ruolo ed etichetta per i ruoli del CONTRATTO; in un AXWebArea solo il ruolo.
    /// Solo se l'elemento appartiene all'app attiva.
    private func bersaglio(_ punto: CGPoint, pidAttivo: Int32, ts: Int64) {
        var elemento: AXUIElement?
        let esito = AXUIElementCopyElementAtPosition(sistema, Float(punto.x), Float(punto.y), &elemento)
        guard esito == .success, let el = elemento else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, SensoreInput.stessaApp(pidElemento: pid, pidAttivo: pidAttivo) else { return }
        let ruolo = AX.stringa(el, kAXRoleAttribute) ?? ""
        guard Annotatore.ruoliClic.contains(ruolo) else { return }
        let subruolo = AX.stringa(el, kAXSubroleAttribute)
        if dentroWebArea(el) {
            dip.annotatore.clic(ruolo: ruolo, subruolo: subruolo, etichetta: nil, web: true, ts: ts)
        } else {
            dip.annotatore.clic(ruolo: ruolo, subruolo: subruolo, etichetta: SensoreAX.etichetta(el), web: false, ts: ts)
        }
    }

    /// Il bersaglio del clic è dell'app attiva. Un pid sconosciuto (0) non basta.
    static func stessaApp(pidElemento: Int32, pidAttivo: Int32) -> Bool {
        pidAttivo > 0 && pidElemento == pidAttivo
    }

    /// Risale i genitori (con tetto di nodi e di tempo) in cerca di un AXWebArea.
    private func dentroWebArea(_ elemento: AXUIElement) -> Bool {
        var corrente: AXUIElement? = elemento
        var n = 0
        let scadenza = DispatchTime.now().uptimeNanoseconds + 60_000_000
        while let c = corrente, n < 25, DispatchTime.now().uptimeNanoseconds < scadenza {
            if (AX.stringa(c, kAXRoleAttribute) ?? "") == "AXWebArea" { return true }
            corrente = AX.elemento(c, kAXParentAttribute)
            n += 1
        }
        return false
    }

    // MARK: Nome canonico delle scorciatoie (puro, testato dal selftest)

    /// Nome ordinato "ctrl+opt+shift+cmd+<tasto>" di una combinazione con cmd o ctrl.
    /// nil se non c'è cmd né ctrl, o se il tasto non è nella mappa. Mai il carattere digitato.
    static func nomeComando(_ flags: NSEvent.ModifierFlags, _ keyCode: UInt16) -> String? {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) || f.contains(.control) else { return nil }
        guard let tasto = nomeTasto(keyCode) else { return nil }
        var parti: [String] = []
        if f.contains(.control) { parti.append("ctrl") }
        if f.contains(.option) { parti.append("opt") }
        if f.contains(.shift) { parti.append("shift") }
        if f.contains(.command) { parti.append("cmd") }
        parti.append(tasto)
        return parti.joined(separator: "+")
    }

    /// keyCode fisico -> nome stabile. Indipendente dal layout e dal carattere prodotto.
    static func nomeTasto(_ keyCode: UInt16) -> String? {
        if let n = mappaTasti[keyCode] { return n }
        return nil
    }

    private static let mappaTasti: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
        36: "invio", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "n", 46: "m", 47: ".", 48: "tab", 49: "spazio", 50: "`", 51: "canc",
        53: "esc", 76: "invio", 65: ".", 67: "*", 69: "+", 75: "/", 78: "-", 71: "azzera",
        81: "=", 82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9",
        96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8", 101: "f9", 103: "f11",
        109: "f10", 111: "f12", 118: "f4", 120: "f2", 122: "f1",
        115: "inizio", 116: "pagsu", 117: "elimina", 119: "fine", 121: "paggiu",
        123: "sinistra", 124: "destra", 125: "giu", 126: "su",
    ]
}
