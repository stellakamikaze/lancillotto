// App.swift: AppDelegate, icona nella barra dei menu e menu.
//
// Avvio:
//   cartella dati (700) -> chiave HMAC -> impostazioni.json -> Filtri -> Registro (WAL)
//   -> Annotatore -> Sensori -> Conservazione -> avvio al login -> icona e menu -> guida (primo avvio
//   o Accessibilità mancante). Aperta a mano con il LaunchAgent caricato: passa la mano a launchd ed esce.
//   ombra: registro che non si apre -> icona gialla, voce di stato con l'errore, nessun sensore.
//   avvio al login: se non è registrato e la persona non l'ha saltato nella finestra, si registra
//   qui (solo da ~/Applications o /Applications), e l'esito va sempre in salute "avvio_login".
//
// Icona: ● verde registra, ● grigio in pausa, ● giallo guasto o permesso mancante,
//        e un punto in più quando una richiesta di consenso L2 aspetta una risposta.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var cartella: URL!
    private var timerTelemetria: Timer?
    private var registro: Registro?
    private var impostazioni: Impostazioni?
    private var filtri = Filtri()
    private var contesto = Contesto()
    private var annotatore: Annotatore?
    private var sensori: Sensori?
    private var conservazione: Conservazione?
    private var pannello: Pannello?
    private var finestra: FinestraPrincipale?
    private var guida: FinestraGuida?
    private var icona: NSStatusItem?
    private var timerConsenso: Timer?
    private var timerIcona: Timer?
    private var consensi: [RichiestaConsenso] = []
    private var erroreAvvio: String?
    private var segnaleTerm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola istanza: se ne gira già una con lo stesso bundle, questa esce.
        if let b = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: b).count > 1 {
            NSApp.terminate(nil)
            return
        }
        if AvvioLogin.passaALaunchd() {
            NSApp.terminate(nil)
            return
        }
        Stile.registraFont()
        cartella = Registro.cartellaDati()
        do {
            try Registro.preparaCartella(cartella)
            let hmac = try Hmac.caricaOCrea(cartella: cartella)
            let imp = Impostazioni(cartella: cartella)
            imp.alGuasto = { [weak self] m in self?.registro?.salute(sensore: "impostazioni", stato: "guasto", dettaglio: m) }
            let dati = imp.carica()
            filtri.aggiorna(dati.regole)
            impostazioni = imp
            let r = Registro(cartella: cartella, hmac: hmac)
            try r.apri()
            r.avviaTemporizzatori()
            registro = r
            let ann = Annotatore(registro: r, filtri: filtri, contesto: contesto, secureInput: {
                IsSecureEventInputEnabled()
            })
            ann.valoriCampi = dati.valoriCampi
            ann.testoSchermo = dati.testoSchermo
            annotatore = ann
            let ora = oraMs()
            r.meta("avvio", String(ora))
            r.meta("permesso_ax", AXIsProcessTrusted() ? "1" : "0")
            r.meta("permesso_schermo", CGPreflightScreenCaptureAccess() ? "1" : "0")
            r.evento(tipo: "servizio", ts: ora, dettaglio: ["cosa": "avvio", "dettaglio": versioneBinario])
            imp.alCambio = { [weak self] nuove, vecchie in self?.impostazioniCambiate(nuove, vecchie) }
            imp.sorveglia()
            let dip = Dipendenze(registro: r, filtri: filtri, redattore: r.redattore, contesto: contesto, annotatore: ann, impostazioni: imp)
            let s = Sensori(dip: dip)
            s.avvia()
            sensori = s
            let c = Conservazione(registro: r, impostazioni: imp)
            c.dopoDimentica = { [weak self] ts, fino in self?.annotatore?.dimenticato(ts, fino: fino) }
            c.avvia()
            conservazione = c
            AvvioLogin.allAvvio(registro: r)
        } catch {
            erroreAvvio = "\(error)"
        }
        preparaIcona()
        preparaSegnali()
        let t = Timer(timeInterval: 2, target: self, selector: #selector(controllaConsensi), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timerConsenso = t
        let ti = Timer(timeInterval: 5, target: self, selector: #selector(aggiornaIcona), userInfo: nil, repeats: true)
        RunLoop.main.add(ti, forMode: .common)
        timerIcona = ti
        let tt = Timer(fire: Date().addingTimeInterval(300), interval: 3600, repeats: true) { [weak self] _ in self?.inviaTelemetria() }
        RunLoop.main.add(tt, forMode: .common)
        timerTelemetria = tt
        let p = Pannello(cartella: cartella)
        p.registro = registro
        p.modificaImpostazioni = { [weak self] cambia in self?.impostazioni?.modifica(cambia) }
        p.pausa = { [weak self] minuti in
            if minuti == 0 { self?.riprendi() } else { self?.impostaPausa(fino: oraMs() + Int64(minuti) * 60_000, motivo: "finestra") }
        }
        p.dimenticaDieci = { [weak self] in self?.dimentica() }
        pannello = p
        if registro != nil && (!AXIsProcessTrusted() || !guidaFatta()) {
            mostraGuida(dalPasso: guidaFatta() ? .accessibilita : .benvenuto)
        }
    }

    /// Lancillotto riaperto dal Finder, dal Launchpad o da Spotlight mentre gira già: apre la finestra.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        apriFinestra()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        let ora = oraMs()
        sensori?.ferma()
        annotatore?.chiudi(ora)
        registro?.evento(tipo: "servizio", ts: ora, dettaglio: ["cosa": "stop", "dettaglio": ""])
        registro?.chiudi()
    }

    /// launchd ferma con SIGTERM: si chiude in ordine, scrivendo il lotto in coda.
    private func preparaSegnali() {
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        s.resume()
        segnaleTerm = s
    }

    private func guidaFatta() -> Bool {
        let u = cartella.appendingPathComponent("impostazioni.json")
        guard let d = try? Data(contentsOf: u), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return false }
        return (j["guida_fatta"] as? Bool) ?? false
    }

    private func mostraGuida(dalPasso passo: PassoGuida = .benvenuto) {
        guard let p = pannello else { return }
        if guida == nil {
            let g = FinestraGuida(pannello: p)
            g.dopo = { [weak self] in self?.apriFinestra() }
            guida = g
        }
        guida?.mostra(dalPasso: passo)
    }

    @objc private func apriFinestra() {
        guard let p = pannello else { return }
        if finestra == nil { finestra = FinestraPrincipale(pannello: p) }
        finestra?.mostra()
    }

    // MARK: Impostazioni

    private func impostazioniCambiate(_ nuove: ImpostazioniDati, _ vecchie: ImpostazioniDati) {
        let ora = oraMs()
        filtri.aggiorna(nuove.regole)
        annotatore?.valoriCampi = nuove.valoriCampi
        annotatore?.testoSchermo = nuove.testoSchermo
        for tolta in Impostazioni.esclusioniTolte(da: vecchie, a: nuove) {
            registro?.evento(tipo: "servizio", ts: ora, dettaglio: ["cosa": "esclusione_tolta", "dettaglio": tolta])
        }
        var cambiate: [String] = []
        if nuove.pausaFino != vecchie.pausaFino { cambiate.append("pausa_fino") }
        if nuove.escludiApp != vecchie.escludiApp { cambiate.append("escludi_app") }
        if nuove.escludiDomini != vecchie.escludiDomini { cambiate.append("escludi_domini") }
        if nuove.conservazioneGiorni != vecchie.conservazioneGiorni { cambiate.append("conservazione_giorni") }
        if nuove.ocr != vecchie.ocr { cambiate.append("ocr") }
        if nuove.valoriCampi != vecchie.valoriCampi { cambiate.append("valori_campi") }
        if nuove.testoSchermo != vecchie.testoSchermo { cambiate.append("testo_schermo") }
        if nuove.cartelle != vecchie.cartelle { cambiate.append("cartelle") }
        if !cambiate.isEmpty {
            registro?.evento(tipo: "servizio", ts: ora, dettaglio: ["cosa": "impostazioni", "dettaglio": cambiate.joined(separator: ",")])
        }
        annotatore?.regoleCambiate(ora)
        // Esclusioni nuove (dalla CLI): il lotto in RAM va su disco adesso, le app escluse si
        // cancellano anche qui (comprese le righe in coda), e meta.esclusioni_applicate dice alla
        // CLI che può cancellare all'indietro senza che un evento vecchio arrivi dopo.
        let appNuove = nuove.escludiApp.filter { !vecchie.escludiApp.contains($0) }
        let dominiNuovi = nuove.escludiDomini.filter { !vecchie.escludiDomini.contains($0) }
        if !appNuove.isEmpty || !dominiNuovi.isEmpty {
            registro?.applicaEsclusioni(app: appNuove, ts: ora) { [weak self] in
                // Il tratto aperto può essere stato cancellato con l'app: se ne apre uno nuovo.
                if !appNuove.isEmpty { DispatchQueue.main.async { self?.annotatore?.dimenticato(oraMs()) } }
            }
        }
        if !nuove.dimenticaRichieste.isEmpty { conservazione?.eseguiRichieste() }
        aggiornaIcona()
    }

    // MARK: Icona e menu

    private func preparaIcona() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false
        i.menu = m
        icona = i
        aggiornaIcona()
    }

    private enum StatoIcona { case registra, pausa, guasto }

    private func statoIcona() -> (StatoIcona, String) {
        if let e = erroreAvvio { return (.guasto, "Guasto all'avvio: \(e)") }
        guard let r = registro else { return (.guasto, "Registro non disponibile") }
        let s = r.statoAttuale()
        if let e = s.errore { return (.guasto, "Scrittura in errore (\(s.inCoda) in coda): \(e)") }
        if filtri.inPausa(oraMs()) {
            let fino = impostazioni?.attuali.pausaFino ?? 0
            return (.pausa, "In pausa fino alle " + AppDelegate.orario(fino))
        }
        if !AXIsProcessTrusted() { return (.guasto, "Manca l'Accessibilità: annoto solo app e durata") }
        return (.registra, "Registra")
    }

    @objc private func aggiornaIcona() {
        guard let pulsante = icona?.button else { return }
        let (stato, _) = statoIcona()
        let colore: NSColor
        switch stato {
        case .registra: colore = .systemGreen
        case .pausa: colore = .systemGray
        case .guasto: colore = .systemYellow
        }
        let testo = NSMutableAttributedString(string: "●", attributes: [.foregroundColor: colore, .font: NSFont.systemFont(ofSize: 13)])
        if !consensi.isEmpty {
            testo.append(NSAttributedString(string: "•", attributes: [.foregroundColor: NSColor.systemBlue, .font: NSFont.systemFont(ofSize: 11)]))
        }
        pulsante.attributedTitle = testo
        pulsante.toolTip = "Lancillotto"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (_, descrizione) = statoIcona()
        menu.addItem(voce(descrizione + " · " + pesoOggi(), nil, attiva: false))
        menu.addItem(.separator())
        for c in consensi {
            menu.addItem(voce("Claude chiede il testo di: " + c.descrizione, nil, attiva: false))
            let mostra = voce("    Mostra", #selector(consensoSi(_:)))
            mostra.representedObject = c.id
            menu.addItem(mostra)
            let rifiuta = voce("    Rifiuta", #selector(consensoNo(_:)))
            rifiuta.representedObject = c.id
            menu.addItem(rifiuta)
        }
        if !consensi.isEmpty { menu.addItem(.separator()) }
        let attivo = registro != nil
        let inPausa = filtri.inPausa(oraMs())
        menu.addItem(voce("Apri Lancillotto", #selector(apriFinestra), attiva: attivo))
        if !AXIsProcessTrusted() {
            menu.addItem(voce("Concedi il permesso…", #selector(apriPermessi)))
        }
        menu.addItem(.separator())
        if inPausa {
            menu.addItem(voce("Riprendi", #selector(riprendi), attiva: attivo))
        } else {
            menu.addItem(voce("Pausa di un'ora", #selector(pausaOra), attiva: attivo))
            menu.addItem(voce("Pausa fino a domani", #selector(pausaDomani), attiva: attivo))
        }
        menu.addItem(.separator())
        menu.addItem(voce("Esci", #selector(esci)))
    }

    private func voce(_ titolo: String, _ azione: Selector?, attiva: Bool = true) -> NSMenuItem {
        let v = NSMenuItem(title: titolo, action: azione, keyEquivalent: "")
        v.target = self
        v.isEnabled = attiva && azione != nil
        return v
    }

    /// Dalla connessione di sola lettura: aprire il menu non aspetta mai la coda di scrittura.
    private func pesoOggi() -> String {
        guard let r = registro else { return "" }
        let mb = Double(r.byteSuDisco()) / 1_048_576
        let eventi = r.eventiDelGiorno(Registro.giornoDi(oraMs()).data)
        return String(format: "oggi %d eventi, registro %.1f MB", Int(eventi ?? 0), mb)
    }

    static func orario(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm 'del' d/M"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: Azioni

    private func impostaPausa(fino: Int64, motivo: String) {
        annotatore?.motivoPausa = motivo
        impostazioni?.modifica { $0["pausa_fino"] = NSNumber(value: fino) }
        aggiornaIcona()
    }

    @objc private func pausaOra() {
        impostaPausa(fino: oraMs() + 3_600_000, motivo: "menu")
    }

    @objc private func pausaDomani() {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let domani = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        impostaPausa(fino: Int64(domani.timeIntervalSince1970 * 1000), motivo: "fino_a_domani")
    }

    @objc private func riprendi() {
        impostazioni?.modifica { $0["pausa_fino"] = NSNumber(value: 0) }
        aggiornaIcona()
    }

    @objc private func dimentica() {
        guard let r = registro else { return }
        let ora = oraMs()
        // Prima si apre un tratto nuovo a `ora`, poi si cancella fino a ora - 1: il tratto
        // vecchio, se è partito prima, viene accorciato all'inizio dell'intervallo.
        annotatore?.dimenticato(ora)
        r.dimentica(da: ora - 600_000, a: ora - 1)
    }

    /// Ogni ora (la prima volta 5 minuti dopo l'avvio): una volta al giorno la CLI cerca un aggiornamento
    /// (git, lancillotto/aggiorna.py), poi aggiunge i numeri del giorno e manda la coda della telemetria.
    /// Se la telemetria è spenta, la CLI non manda niente. Il binario resta senza rete.
    @objc private func inviaTelemetria() {
        guard registro != nil else { return }
        CLI.esegui(["aggiorna", "--se-serve", "--json"], cartella: cartella, registro: registro) { [weak self] _ in
            guard let self = self else { return }
            CLI.esegui(["telemetria", "invia"], cartella: self.cartella, registro: self.registro)
        }
    }

    @objc private func apriPermessi() {
        mostraGuida(dalPasso: .accessibilita)
    }

    @objc private func esci() {
        NSApp.terminate(nil)
    }

    // MARK: Consenso L2

    @objc private func controllaConsensi() {
        guard let r = registro else { return }
        let nuovi = r.consensiInAttesa()
        if nuovi != consensi {
            consensi = nuovi
            aggiornaIcona()
        }
    }

    @objc private func consensoSi(_ v: NSMenuItem) {
        decidi(v, si: true)
    }

    @objc private func consensoNo(_ v: NSMenuItem) {
        decidi(v, si: false)
    }

    private func decidi(_ v: NSMenuItem, si: Bool) {
        guard let id = v.representedObject as? String, let r = registro else { return }
        r.decidiConsenso(id: id, si: si)
        controllaConsensi()
    }
}
