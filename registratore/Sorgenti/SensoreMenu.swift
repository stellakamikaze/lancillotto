// SensoreMenu.swift: percorso delle voci di menu scelte, evento 'menu'.
//
//   NSWorkspace -> SensoreApp -> .lancillottoAppAttiva -> SensoreMenu.aggancia(pid)
//   AXObserver(pid): kAXMenuItemSelectedNotification sull'app attiva
//        -> risale i genitori (AXMenu / AXMenuItem / AXMenuBarItem) -> "Archivio > Esporta…"
//        -> Annotatore.menu
//   ombra: AXIsProcessTrusted() falso -> niente observer, controllo ogni 5 s.
//
// Il percorso entra solo quando il filtro corrente dà `pieno`: un menu di un'app esclusa
// non si legge. La redazione del percorso la fa il Registro (redigiDettaglio). Se la voce
// scelta è un Incolla, l'evento porta cc = changeCount corrente, come il cmd+v.

import AppKit
import ApplicationServices
import Foundation

final class SensoreMenu: NSObject, Sensore {
    let dip: Dipendenze
    private var osservatore: AXObserver?
    private var elementoApp: AXUIElement?
    private var pid: pid_t = 0
    private var controllo: Timer?
    private var attivo = false

    init(dip: Dipendenze) {
        self.dip = dip
        super.init()
    }

    func avvia() {
        NotificationCenter.default.addObserver(self, selector: #selector(appAttiva(_:)), name: .lancillottoAppAttiva, object: nil)
        let t = Timer(timeInterval: 5, target: self, selector: #selector(controllaPermesso), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        controllo = t
        controllaPermesso()
    }

    func ferma() {
        NotificationCenter.default.removeObserver(self)
        controllo?.invalidate()
        controllo = nil
        sgancia()
        attivo = false
    }

    @objc private func controllaPermesso() {
        let fidato = AXIsProcessTrusted()
        if fidato && !attivo {
            attivo = true
            if let app = NSWorkspace.shared.frontmostApplication,
               app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                aggancia(app.processIdentifier)
            }
        } else if !fidato && attivo {
            attivo = false
            sgancia()
        }
    }

    @objc private func appAttiva(_ n: Notification) {
        guard attivo, let p = n.userInfo?["pid"] as? Int32 else { return }
        aggancia(p)
    }

    // MARK: Observer

    private func aggancia(_ nuovoPid: pid_t) {
        sgancia()
        pid = nuovoPid
        let el = AXUIElementCreateApplication(nuovoPid)
        AXUIElementSetMessagingTimeout(el, 0.25)
        elementoApp = el
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, elemento, _, refcon in
            guard let refcon = refcon else { return }
            let s = Unmanaged<SensoreMenu>.fromOpaque(refcon).takeUnretainedValue()
            s.selezionato(elemento)
        }
        guard AXObserverCreate(nuovoPid, callback, &obs) == .success, let o = obs else {
            dip.registro.salute(sensore: "menu", stato: "degradato", dettaglio: "AXObserverCreate non riuscito")
            return
        }
        osservatore = o
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(o, el, kAXMenuItemSelectedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }

    private func sgancia() {
        if let o = osservatore {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        }
        osservatore = nil
        elementoApp = nil
    }

    private func selezionato(_ elemento: AXUIElement) {
        guard dip.contesto.leggi().esito == .pieno else { return }
        let titoli = SensoreMenu.titoli(da: elemento)
        guard !titoli.isEmpty else { return }
        let percorso = SensoreMenu.percorso(titoli)
        // Un Incolla porta il changeCount, come il cmd+v, per legare l'incolla alla copia.
        let cc = SensoreMenu.èIncolla(titoli.last ?? "") ? NSPasteboard.general.changeCount : nil
        dip.annotatore.menu(percorso: percorso, cc: cc, ts: oraMs())
    }

    /// Titoli dalla voce scelta su fino alla barra, dalla radice alla foglia.
    static func titoli(da elemento: AXUIElement) -> [String] {
        var raccolti: [String] = []
        var corrente: AXUIElement? = elemento
        var n = 0
        while let c = corrente, n < 30 {
            let ruolo = AX.stringa(c, kAXRoleAttribute) ?? ""
            if ruolo == "AXMenuItem" || ruolo == "AXMenuBarItem" {
                if let t = AX.stringa(c, kAXTitleAttribute), !t.isEmpty {
                    raccolti.append(String(t.prefix(100)))
                }
            }
            if ruolo == "AXMenuBar" { break }
            corrente = AX.elemento(c, kAXParentAttribute)
            n += 1
        }
        return raccolti.reversed()
    }

    // MARK: Puro (testato dal selftest)

    /// Unisce i titoli dalla radice alla foglia con " > ".
    static func percorso(_ titoli: [String]) -> String {
        titoli.joined(separator: " > ")
    }

    /// true se il titolo di una voce è un comando di incolla (it/en).
    static func èIncolla(_ titolo: String) -> Bool {
        let t = titolo.lowercased()
        return t.hasPrefix("incolla") || t.hasPrefix("paste")
    }
}
