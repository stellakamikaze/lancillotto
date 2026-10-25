// SensoreApp.swift: app in primo piano, sonno e risveglio, blocco schermo, inattività.
//
// Non chiede permessi: funziona anche senza Accessibilità (allora è l'unico sensore attivo).
// Ogni 5 s: battito dell'Annotatore (allunga il tratto, controlla pausa e secure input)
// e inattività con CGEventSource: oltre 180 s senza input si chiude il tratto all'inizio
// dell'inattività, e al ritorno si scrive un evento `inattivo` con la durata.

import AppKit
import CoreGraphics
import Foundation

final class SensoreApp: NSObject, Sensore {
    let dip: Dipendenze
    private var timer: Timer?
    private var inattivoDa: Int64?
    static let sogliaInattivita: Double = 180

    init(dip: Dipendenze) {
        self.dip = dip
        super.init()
    }

    func avvia() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appAttivata(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(sonno(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(risveglio(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(blocco(_:)), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(sblocco(_:)), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        if let primo = NSWorkspace.shared.frontmostApplication { registra(primo) }
        let t = Timer(timeInterval: 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        dip.registro.salute(sensore: "app", stato: "ok")
    }

    func ferma() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        timer?.invalidate()
        timer = nil
    }

    @objc private func appAttivata(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        registra(app)
    }

    private func registra(_ app: NSRunningApplication) {
        // Lancillotto stesso (finestra dei permessi) non si annota.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        let bundle = app.bundleIdentifier ?? ("senza-bundle:" + (app.executableURL?.lastPathComponent ?? "sconosciuta"))
        dip.annotatore.cambiaApp(AppRif(bundle: bundle, nome: app.localizedName), pid: app.processIdentifier, ts: oraMs())
        NotificationCenter.default.post(name: .lancillottoAppAttiva, object: nil, userInfo: ["pid": app.processIdentifier])
    }

    @objc private func sonno(_ n: Notification) {
        dip.annotatore.sospendi("sonno", ts: oraMs())
    }

    @objc private func risveglio(_ n: Notification) {
        inattivoDa = nil
        dip.annotatore.riprendi("risveglio", ts: oraMs())
    }

    @objc private func blocco(_ n: Notification) {
        dip.annotatore.sospendi("blocco", ts: oraMs())
    }

    @objc private func sblocco(_ n: Notification) {
        inattivoDa = nil
        dip.annotatore.riprendi("sblocco", ts: oraMs())
    }

    @objc private func tick() {
        let ora = oraMs()
        // kCGAnyInputEventType = ~0: qualunque input (tastiera, mouse, trackpad).
        let tutti = CGEventType(rawValue: UInt32.max) ?? .null
        let secondi = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: tutti)
        if secondi >= SensoreApp.sogliaInattivita {
            if inattivoDa == nil {
                let da = ora - Int64(secondi * 1000)
                inattivoDa = da
                dip.annotatore.inizioInattivita(da: da)
            }
        } else if let da = inattivoDa {
            inattivoDa = nil
            dip.annotatore.fineInattivita(da: da, ts: ora - Int64(secondi * 1000))
        }
        dip.annotatore.battito(ora)
    }
}
