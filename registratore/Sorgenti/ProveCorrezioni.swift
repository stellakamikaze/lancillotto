// ProveCorrezioni.swift: test del selftest per le correzioni della revisione del 24/10/2026.
//
// Ogni prova nasce da un difetto confermato e fallisce sulla versione di prima: il nome dice
// quale. Non tocca AX, TCC, schermo né finestre. Le prove con il Registro usano una cartella
// temporanea propria (mai LANCILLOTTO_DIR né la cartella dati reale) e la cancellano alla fine.
// Sulla build VELENO filtri e redattore sono spenti: molte di queste prove falliscono, ed è il
// veleno che attacca.

import Foundation
import SQLite3

private final class AlberoFinto {
    struct Nodo {
        var ruolo: String
        var subruolo: String? = nil
        var testo: String? = nil
        var figli: [Int] = []
    }
    var nodi: [Nodo]
    init(_ nodi: [Nodo]) { self.nodi = nodi }
}

/// Bandiera e contatore della prova di stress, condivisi fra le code sotto lock.
private final class StatoStress {
    private let lock = NSLock()
    private var fine = false
    private var n = 0
    func basta() -> Bool { lock.lock(); defer { lock.unlock() }; return fine }
    func ferma() { lock.lock(); fine = true; lock.unlock() }
    func aggiungi(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    func letture() -> Int { lock.lock(); defer { lock.unlock() }; return n }
}

enum ProveCorrezioni {
    static func controlli() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func vero(_ c: Bool, _ nome: String) { out.append((c, "correzioni: " + nome)) }
        func uguale<T: Equatable>(_ a: T, _ b: T, _ nome: String) {
            out.append((a == b, a == b ? "correzioni: " + nome : "correzioni: \(nome): \(a) invece di \(b)"))
        }
        pure(vero, uguale)
        conRegistro(vero, uguale)
        return out
    }

    // MARK: Funzioni pure

    private static func pure(_ vero: (Bool, String) -> Void, _ uguale: (String, String, String) -> Void) {
        let r = Regole()
        func o(_ bundle: String, titolo: String? = nil, url: String? = nil, documento: String? = nil,
               attributi: [String: String] = [:]) -> Osservazione {
            Osservazione(ora: 1000, bundle: bundle, nomeApp: nil, titolo: titolo, url: url, attributiFinestra: attributi,
                         ruoloFocus: nil, subruoloFocus: nil, secureInput: false,
                         browser: Esclusioni.browser.contains(bundle), documento: documento)
        }
        func esito(_ e: Esito) -> String { "\(e)" }

        // 3. browser senza URL letto: nel dubbio no.
        uguale(esito(RegoleFiltro.decidi(o("org.mozilla.firefox", titolo: "Fineco - Saldo e movimenti"), r)),
               esito(.escluso("dubbio")), "3 browser senza url: dubbio")
        uguale(esito(RegoleFiltro.decidi(o("org.mozilla.firefox", titolo: "Fineco", url: "https://www.fineco.it/conto"), r)),
               esito(.escluso("dominio")), "3 browser con url escluso: dominio")
        uguale(esito(RegoleFiltro.decidi(o("com.google.Chrome", titolo: "Ordini", url: "https://portale.esempio.it/ordini"), r)),
               esito(.pieno), "3 browser con url normale: pieno")
        uguale(esito(RegoleFiltro.decidi(o("com.google.Chrome"), r)), esito(.pieno), "3 browser prima del titolo: pieno senza testo")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.TextEdit", titolo: "Nota"), r)), esito(.pieno), "3 app non browser senza url: pieno")

        // 6. documento a fuoco in una cartella esclusa.
        uguale(esito(RegoleFiltro.decidi(o("com.apple.TextEdit", titolo: ".env", documento: "/Users/x/progetto/.env"), r)),
               esito(.escluso("cartella")), "6 documento .env: cartella")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.TextEdit", titolo: "config", documento: "/Users/x/.ssh/config"), r)),
               esito(.escluso("cartella")), "6 documento in .ssh: cartella")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.TextEdit", titolo: "x", documento: "/Users/x/Library/Preferences/a.plist"), r)),
               esito(.escluso("cartella")), "6 documento in Library: cartella")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.Preview", titolo: "ordine.pdf",
                                          documento: "/Users/x/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/A/ordine.pdf"), r)),
               esito(.pieno), "6 allegato di Mail resta pieno")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.iWork.Pages", titolo: "Tesi",
                                          documento: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Tesi.pages"), r)),
               esito(.pieno), "6 documento su iCloud Drive resta pieno")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.TextEdit", titolo: "s", documento: "/Users/x/Library/Mobile Documents/x/client_secret.json"), r)),
               esito(.escluso("cartella")), "6 secret anche su iCloud: cartella")

        // 8. esclusione per nome dell'app.
        vero(RegoleFiltro.appEsclusa(bundle: "com.google.Chrome", nome: "Google Chrome", extra: ["Chrome"]), "8 nome breve Chrome esclude")
        vero(RegoleFiltro.appEsclusa(bundle: "com.tinyspeck.slackmacgap", nome: "Slack", extra: ["slack"]), "8 nome Slack esclude")
        vero(!RegoleFiltro.appEsclusa(bundle: "com.apple.mail", nome: "Mail", extra: ["Slack"]), "8 nome di un'altra app non esclude")

        // 11. finestre private di Safari e Arc non riconoscibili: privata nel dubbio.
        uguale(esito(RegoleFiltro.decidi(o("com.apple.Safari", titolo: "Diagnosi PRIVATAVELENO", url: "https://esempio.it/a",
                                          attributi: ["AXSubrole": "AXStandardWindow"]), r)),
               esito(.escluso("privata")), "11 Safari senza segno: privata")
        uguale(esito(RegoleFiltro.decidi(o("company.thebrowser.Browser", titolo: "Pagina", url: "https://esempio.it/a"), r)),
               esito(.escluso("privata")), "11 Arc senza segno: privata")
        uguale(esito(RegoleFiltro.decidi(o("com.apple.Safari", titolo: "Pagina", url: "https://esempio.it/a", attributi: ["privata": "0"]), r)),
               esito(.pieno), "11 Safari con segno provato di finestra normale: pieno")

        // 9. campi con l'etichetta di un segreto.
        vero(RegoleFiltro.campoSensibile("Password"), "9 etichetta Password")
        vero(RegoleFiltro.campoSensibile("CVV"), "9 etichetta CVV")
        vero(RegoleFiltro.campoSensibile("Codice di sicurezza"), "9 etichetta codice di sicurezza")
        vero(RegoleFiltro.campoSensibile("PIN del bancomat"), "9 etichetta PIN")
        vero(!RegoleFiltro.campoSensibile("Importo"), "9 etichetta Importo normale")
        vero(!RegoleFiltro.campoSensibile("Spinner"), "9 pin dentro una parola non conta")

        // 9, 5, 6. redattore.
        let red = Redattore(hmac: Hmac.diProva())
        func via(_ testo: String, _ veleno: String, _ nome: String) {
            let t = red.redigi(testo).testo
            vero(!t.contains(veleno), "\(nome): \(t)")
        }
        via("La tua nuova password è PWDVELENO99", "PWDVELENO99", "9 password in una frase")
        via("Password temporanea PWDVELENO77", "PWDVELENO77", "9 password temporanea")
        via("La tua password temporanea è: PWDVELENO55", "PWDVELENO55", "9 password temporanea è:")
        via("CVV 123 e PIN: 4821", "4821", "9 pin con cifre")
        uguale(red.redigi("La password è sbagliata").testo, "La password è sbagliata", "9 frase senza password resta")
        via("portale.esempio.it/reset?token=QUERYVELENO2", "QUERYVELENO2", "5 url senza schema perde la query")
        via("vai su https://portale.esempio.it/reset?token=QUERYVELENO1&cliente=Rossi#FRAMMVELENO ora", "VELENO", "5 url con schema")
        uguale(red.redigi("portale.esempio.it/reset?token=x").testo, "portale.esempio.it/reset", "5 resta host e percorso")
        uguale(red.redigi("Hai finito?").testo, "Hai finito?", "5 domanda normale resta")
        let stripe = "sk_" + "live_" + "51HabcdefGHIJ1234567890"
        via("STRIPE_SECRET=" + stripe, "51HabcdefGHIJ", "6 chiave sk_live")
        via("AWS_SECRET_ACCESS_KEY=" + "wJalrXUtnFEMI" + "K7MDENGbPxRfiCY", "wJalrXUtnFEMI", "6 assegnazione AWS")
        via("API_TOKEN=9f8e7d6c5b4a" + "3210", "9f8e7d6c5b4a", "6 assegnazione TOKEN") // gitleaks:allow (token finto del test)
        via("\"client_secret\": \"" + "abcDEF123456ghi" + "\"", "abcDEF123456", "6 json client_secret")
        vero(red.redigi(red.redigi("API_TOKEN=9f8e7d6c5b4a3210 password è Abc12345").testo).n == 0, "redazione nuova idempotente") // gitleaks:allow

        // 4. visita dei browser: solo la pagina.
        let a = AlberoFinto([
            .init(ruolo: "AXWindow", figli: [1, 6]),
            .init(ruolo: "AXGroup", figli: [2, 5]),
            .init(ruolo: "AXTabGroup", figli: [3, 4]),
            .init(ruolo: "AXRadioButton", subruolo: "AXTabButton", testo: "Fineco - SCHEDAVELENO"),
            .init(ruolo: "AXRadioButton", subruolo: "AXTabButton", testo: "Posta in arrivo - Gmail"),
            .init(ruolo: "AXToolbar", figli: [7]),
            .init(ruolo: "AXWebArea", figli: [8]),
            .init(ruolo: "AXTextField", testo: "fineco.it/conto"),
            .init(ruolo: "AXStaticText", testo: "Ciao Mario"),
        ])
        func visita(_ solo: Bool) -> (RisultatoVisita, Int?) {
            var b = Budget(nodi: 100, ms: 1000)
            var trovata: Int?
            let v = VisitaAX.visita(radice: 0, budget: &b, valoriCampi: true, soloWebArea: solo,
                                    struttura: { i in (a.nodi[i].ruolo, a.nodi[i].subruolo) },
                                    figli: { i, _ in a.nodi[i].figli }, testo: { i, _ in a.nodi[i].testo },
                                    webArea: { trovata = $0 })
            return (v, trovata)
        }
        let (soloPagina, area) = visita(true)
        vero(soloPagina.testi == ["Ciao Mario"], "4 browser: solo il testo della pagina \(soloPagina.testi)")
        vero(area == 6, "4 browser: la pagina trovata per il ritaglio dell'OCR")
        vero(visita(false).0.testi.contains("Ciao Mario"), "4 app normale: visita intera")
        let rit = TestoSchermo.ritaglioNormalizzato(finestra: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                                    area: CGRect(x: 100, y: 200, width: 1000, height: 700))
        vero(rit.map { abs($0.minY) < 0.0001 && abs($0.height - 0.875) < 0.0001 } ?? false, "4 ritaglio della pagina in coordinate di Vision")
        let voci = [VoceOCR(testo: "Fineco - SCHEDAVELENO", x: 0.1, y: 0.95, altezza: 0.02),
                    VoceOCR(testo: "Ciao", x: 0.1, y: 0.5, altezza: 0.02)]
        vero(TestoSchermo.dentroRitaglio(voci, rit).map { $0.testo } == ["Ciao"], "4 OCR del browser: via la barra delle schede")

        // 7, 13. clic e menu.
        vero(!SensoreInput.stessaApp(pidElemento: 5, pidAttivo: 7), "7 bersaglio di un'altra app scartato")
        vero(!SensoreInput.stessaApp(pidElemento: 0, pidAttivo: 0), "7 pid sconosciuto scartato")
        vero(SensoreInput.stessaApp(pidElemento: 7, pidAttivo: 7), "7 bersaglio dell'app attiva ammesso")
        uguale(Annotatore.percorsoMenuSicuro("Cronologia > Fineco | MENUVELENO conto"), "Cronologia", "13 menu Cronologia senza titoli")
        uguale(Annotatore.percorsoMenuSicuro("Window > Navigazione privata"), "Window", "13 menu Window senza titoli")
        uguale(Annotatore.percorsoMenuSicuro("Archivio > Esporta come PDF…"), "Archivio > Esporta come PDF…", "13 menu normale intero")
        vero(!Annotatore.etichettaClicAmmessa(bundle: "com.google.Chrome", subruolo: nil), "13 etichetta della cornice del browser scartata")
        vero(!Annotatore.etichettaClicAmmessa(bundle: "com.apple.Notes", subruolo: "AXTabButton"), "13 etichetta di una scheda scartata")
        vero(Annotatore.etichettaClicAmmessa(bundle: "com.apple.mail", subruolo: nil), "13 etichetta di un pulsante normale ammessa")

        // 16, 24, 34.
        uguale(SensoreInput.cambioPermesso(prima: false, ora: true) ?? "nil", "ok", "16 permesso arrivato: ok")
        uguale(SensoreInput.cambioPermesso(prima: nil, ora: false) ?? "nil", "degradato", "16 primo controllo senza permesso")
        uguale(SensoreInput.cambioPermesso(prima: true, ora: true) ?? "nil", "nil", "16 niente cambia")
        vero(SensoreInput.portaCC("shift+cmd+v"), "24 shift+cmd+v porta il cc")
        vero(SensoreInput.portaCC("opt+shift+cmd+v"), "24 opt+shift+cmd+v porta il cc")
        vero(SensoreInput.portaCC("cmd+v") && !SensoreInput.portaCC("cmd+c"), "24 cmd+v sì, cmd+c no")
        vero(AvvioLogin.daRegistrare(nonRegistrato: true, saltato: false, percorsoApp: "/Users/x/Applications/Lancillotto.app", home: "/Users/x"),
             "34 non registrato e non saltato: si registra al lancio")
        vero(!AvvioLogin.daRegistrare(nonRegistrato: true, saltato: true, percorsoApp: "/Users/x/Applications/Lancillotto.app", home: "/Users/x"),
             "34 saltato dalla persona: no")
        vero(!AvvioLogin.daRegistrare(nonRegistrato: true, saltato: false, percorsoApp: "/Users/x/lancillotto/registratore/build/Lancillotto.app", home: "/Users/x"),
             "34 build di prova: no")
        let agente = AvvioLogin.contenuto(binario: "/Users/x/Applications/Lancillotto.app/Contents/MacOS/Lancillotto")
        vero((agente["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false,
             "login: riparte dopo un crash, non dopo Esci")
        vero((agente["ProgramArguments"] as? [String])?.first == "/Users/x/Applications/Lancillotto.app/Contents/MacOS/Lancillotto"
             && agente["Label"] as? String == "org.stellakamikaze.lancillotto", "login: binario ed etichetta")
        vero(SensoreAX.paginaValida(descrizione: "(2) Instagram", titolo: "(2) Instagram — Mario Rossi"),
             "firefox: pagina ricordata valida se apre il titolo")
        vero(!SensoreAX.paginaValida(descrizione: "(2) Instagram", titolo: "Fineco — Mario Rossi"),
             "firefox: scheda cambiata, pagina ricordata non vale")
        vero(!SensoreAX.paginaValida(descrizione: "", titolo: "Qualcosa") && !SensoreAX.paginaValida(descrizione: "ab", titolo: "abc"),
             "firefox: descrizione vuota o troppo corta non vale")
    }

    // MARK: Con un registro temporaneo

    private static func conRegistro(_ vero: (Bool, String) -> Void, _ uguale: (String, String, String) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lancillotto-correzioni-" + UUID().uuidString, isDirectory: true)
        defer {
            chmod(dir.appendingPathComponent("chiave-illeggibile").path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            try Registro.preparaCartella(dir)
            let hmac = try Hmac.caricaOCrea(cartella: dir)
            let r = Registro(cartella: dir, hmac: hmac)
            try r.apri()
            let ctx = Contesto()
            let ann = Annotatore(registro: r, filtri: Filtri(), contesto: ctx, home: "/Users/x", secureInput: { false })
            let chrome = AppRif(bundle: "com.google.Chrome", nome: "Google Chrome")
            let t0: Int64 = 1_800_000_000_000
            func conta(_ sql: String, _ arg: [Any?] = []) -> Int64 {
                ((try? r.leggi { d in try d.intero(sql, arg) }) ?? nil) ?? -1
            }
            func valori() -> [String] {
                (try? r.leggi { d -> [String] in
                    var v: [String] = []
                    let s = try d.istruzione("SELECT valore_z FROM campo WHERE valore_z IS NOT NULL")
                    defer { s.azzera() }
                    while try s.passo() { if let z = s.blob(0) { v.append(Compressione.decomprimiTesto(z) ?? "") } }
                    return v
                }) ?? []
            }

            // 2. il valore del campo lasciato su una pagina esclusa non passa sotto la finestra nuova.
            ann.cambiaApp(chrome, pid: 10, ts: t0)
            ann.cambiaFinestra(titolo: "Fineco - Conto", url: "https://www.fineco.it/conto", documento: nil, ts: t0)
            ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Causale", ts: t0 + 100)
            ann.cambiaFinestra(titolo: "Posta in arrivo", url: "https://mail.example.com/", documento: nil, ts: t0 + 200)
            ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Causale", valore: "Affitto BANCAVELENO via Roma", durMs: 300, ts: t0 + 300)
            ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t0 + 300)
            // finestra privata -> finestra normale della stessa app
            ann.cambiaFinestra(titolo: "Navigazione privata - Cerca", url: "https://cerca.example.com/", documento: nil, ts: t0 + 400)
            ann.cambiaFocus(ruolo: "AXSearchField", subruolo: nil, etichetta: "Cerca", ts: t0 + 500)
            ann.cambiaFinestra(titolo: "Notizie", url: "https://notizie.example.com/", documento: nil, ts: t0 + 600)
            ann.campoValore(ruolo: "AXSearchField", subruolo: nil, etichetta: "Cerca", valore: "PRIVATOVELENO sintomi", durMs: 200, ts: t0 + 700)
            ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t0 + 700)
            // controllo: un campo normale nella stessa finestra si salva
            ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Importo", ts: t0 + 800)
            ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Importo", valore: "1.234,56", durMs: 200, ts: t0 + 1000)
            ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t0 + 1000)
            // 9. campo con etichetta Password non protetto (dopo "Mostra password"): niente valore
            ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Password", ts: t0 + 1100)
            ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Password", valore: "Hunter2!xQ", durMs: 200, ts: t0 + 1300)
            ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t0 + 1300)
            // 5. la barra indirizzi incollata come valore: via query e frammento
            ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Ricerca", ts: t0 + 1400)
            ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Ricerca",
                            valore: "https://portale.esempio.it/reset?token=QUERYVELENO1&cliente=RossiSpa#FRAMMVELENO", durMs: 200, ts: t0 + 1600)
            ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t0 + 1600)
            // 7, 13. clic su una scheda fineco da una pagina permessa, menu Cronologia
            ann.clic(ruolo: "AXRadioButton", subruolo: "AXTabButton", etichetta: "Fineco - SCHEDAVELENO saldo", web: false, ts: t0 + 1700)
            ann.menu(percorso: "Cronologia > Fineco | MENUVELENO conto", ts: t0 + 1800)
            // 10. download da un dominio escluso
            ann.file(tipo: "file_crea", info: InfoFile(path: "/Users/x/Downloads/Estratto FILEVELENO 445566.pdf", inode: 77, provenienza: "fineco.it"), ts: t0 + 1900)
            _ = r.svuota()
            let v = valori()
            vero(!v.contains { $0.contains("BANCAVELENO") }, "2 campo della pagina esclusa non salvato sotto la finestra nuova")
            vero(!v.contains { $0.contains("PRIVATOVELENO") }, "2 campo della finestra privata non salvato")
            vero(v.contains("1.234,56"), "2 campo normale salvato: \(v)")
            vero(!v.contains { $0.contains("Hunter2") }, "9 valore del campo Password non salvato")
            vero(!v.contains { $0.contains("QUERYVELENO") || $0.contains("FRAMMVELENO") }, "5 valore senza query e frammento: \(v)")
            let dettagli = (try? r.leggi { d -> String in
                var t = ""
                let s = try d.istruzione("SELECT COALESCE(dettaglio, '') FROM evento")
                defer { s.azzera() }
                while try s.passo() { t += (s.testo(0) ?? "") + "\n" }
                return t
            }) ?? ""
            vero(!dettagli.contains("SCHEDAVELENO"), "13 titolo della scheda non nel dettaglio del clic")
            vero(!dettagli.contains("MENUVELENO"), "13 voce di Cronologia non nel percorso")
            uguale(String(conta("SELECT COUNT(*) FROM oggetto WHERE tipo = 'file' AND (etichetta IS NOT NULL OR provenienza IS NOT NULL)")), "0",
                   "10 download da dominio escluso senza nome né provenienza")
            uguale(String(conta("SELECT COUNT(*) FROM impronta WHERE fonte = 'file'")), "0", "10 nessuna impronta del nome")
            uguale(String(conta("SELECT COUNT(*) FROM evento WHERE tipo = 'file_crea'")), "1", "10 l'evento del download resta")

            // 15. un OCR finito dopo un dimentica non scrive nell'intervallo dimenticato.
            let preview = AppRif(bundle: "com.apple.Preview", nome: "Anteprima")
            let ora = t0 + 3_600_000
            ann.cambiaApp(preview, pid: 11, ts: ora - 5000)
            ann.cambiaFinestra(titolo: "scansione.pdf", url: nil, documento: nil, ts: ora - 5000)
            ann.dimenticato(ora)
            _ = r.dimenticaSubito(da: ora - 600_000, a: ora - 1)
            ann.schermo(fonte: "ocr", ms: 1500, righe: ["Referto OCRVELENO", "seconda riga"], troncato: false, ts: ora - 2000)
            _ = r.svuota()
            uguale(String(conta("SELECT COUNT(*) FROM evento WHERE tipo = 'schermo' AND ts >= ? AND ts <= ?", [ora - 600_000, ora - 1])), "0",
                   "15 OCR in ritardo scartato")

            // 21. testo_schermo spento: nessuna riga di testo arriva al registro, neanche da un OCR in volo.
            ann.cambiaFinestra(titolo: "documento.pdf", url: nil, documento: nil, ts: ora + 1000)
            ann.testoSchermo = false
            ann.schermo(fonte: "ax", ms: 10, righe: ["Riga TESTOSPENTOVELENO"], troncato: false, ts: ora + 2000)
            ann.testoSchermo = true
            _ = r.svuota()
            uguale(String(conta("SELECT COUNT(*) FROM evento WHERE tipo = 'schermo' AND ts = ?", [ora + 2000])), "0",
                   "21 testo spento: nessuno schermo scritto")

            // 14. gli id non tornano indietro dopo un dimentica e un riavvio.
            let base = ora + 100_000
            var ids: [Int64] = []
            for k in 0..<5 { ids.append(r.evento(tipo: "servizio", ts: base + Int64(k) * 1000, dettaglio: ["cosa": "prova"])) }
            _ = r.svuota()
            let cancPrima = (try? r.leggi { d in try d.testo("SELECT valore FROM meta WHERE chiave = 'cancellazioni'") }) ?? nil
            _ = r.dimenticaSubito(da: base + 3000, a: base + 4000)
            let cancDopo = (try? r.leggi { d in try d.testo("SELECT valore FROM meta WHERE chiave = 'cancellazioni'") }) ?? nil
            vero((Int(cancDopo ?? "0") ?? 0) > (Int(cancPrima ?? "0") ?? 0), "14 meta.cancellazioni sale a ogni dimentica")
            r.chiudi()
            let r2 = Registro(cartella: dir, hmac: hmac)
            try r2.apri()
            let nuovo = r2.evento(tipo: "servizio", ts: base + 10_000, dettaglio: ["cosa": "dopo"])
            vero(nuovo > (ids.last ?? 0), "14 id nuovo \(nuovo) dopo il riavvio sopra il vecchio massimo \(ids.last ?? 0)")
            _ = r2.svuota()

            // 20. la cache delle righe controlla l'hash: un id riusato non aggiorna la riga sbagliata.
            let b = AppRif(bundle: "com.esempio.b", nome: "B")
            let aApp = AppRif(bundle: "com.esempio.a", nome: "A")
            let c = AppRif(bundle: "com.esempio.c", nome: "C")
            let tr = base + 20_000
            r2.righe(ts: tr, app: b, finestra: OggettoRif(tipo: "finestra", valore: "b\u{0}fb", etichetta: "fb"), fonte: "ax", ms: 1, righe: ["riga di b uno"], troncato: false)
            r2.righe(ts: tr + 1, app: aApp, finestra: OggettoRif(tipo: "finestra", valore: "a\u{0}fa", etichetta: "fa"), fonte: "ax", ms: 1, righe: ["testo vecchio della app a"], troncato: false)
            _ = r2.svuota()
            // come la CLI: cancella da fuori la riga dell'app esclusa (id più alto), senza avvisare
            var esterno: OpaquePointer?
            sqlite3_open(r2.percorso, &esterno)
            sqlite3_busy_timeout(esterno, 2000)
            sqlite3_exec(esterno, "DELETE FROM riga WHERE id = (SELECT MAX(id) FROM riga)", nil, nil, nil)
            sqlite3_close(esterno)
            r2.righe(ts: tr + 2, app: b, finestra: OggettoRif(tipo: "finestra", valore: "b\u{0}fb2", etichetta: "fb2"), fonte: "ax", ms: 1, righe: ["testo NUOVO di b"], troncato: false)
            r2.righe(ts: tr + 3, app: c, finestra: OggettoRif(tipo: "finestra", valore: "c\u{0}fc", etichetta: "fc"), fonte: "ax", ms: 1, righe: ["testo vecchio della app a"], troncato: false)
            _ = r2.svuota()
            func conta2(_ sql: String, _ arg: [Any?] = []) -> Int64 {
                ((try? r2.leggi { d in try d.intero(sql, arg) }) ?? nil) ?? -1
            }
            let hA = sha256Breve("testo vecchio della app a")
            uguale(String(conta2("SELECT COUNT(*) FROM riga WHERE h = ?", [hA])), "1", "20 la riga ricomparsa è riscritta col suo hash")
            let aggiunteC = (try? r2.leggi { d in try d.testo("SELECT aggiunte FROM schermo ORDER BY id DESC LIMIT 1") }) ?? nil
            let idA = conta2("SELECT id FROM riga WHERE h = ?", [hA])
            uguale(aggiunteC ?? "", "[\(idA)]", "20 lo schermo di C punta alla riga giusta")
            uguale(String(conta2("SELECT volte FROM riga WHERE h = ?", [sha256Breve("testo NUOVO di b")])), "1", "20 la riga di B non è stata toccata")

            // 19. il consenso si legge anche mentre la coda aspetta il lock della CLI.
            _ = try r2.leggi { d in
                try d.scrivi("INSERT INTO consenso(id, t0, t1, descrizione, richiesto_ts) VALUES('c9', 1, 2, 'prova', 3)")
            }
            var blocco: OpaquePointer?
            sqlite3_open(r2.percorso, &blocco)
            sqlite3_exec(blocco, "BEGIN IMMEDIATE", nil, nil, nil)
            r2.evento(tipo: "servizio", ts: tr + 10, dettaglio: ["cosa": "in coda"])
            r2.dimentica(da: 1, a: 2)   // occupa la coda sul BEGIN IMMEDIATE fino al rilascio del lock
            Thread.sleep(forTimeInterval: 0.2)
            let inizio = Date()
            let attese = r2.consensiInAttesa()
            let ms = Int(Date().timeIntervalSince(inizio) * 1000)
            Thread.sleep(forTimeInterval: 0.3)
            sqlite3_exec(blocco, "ROLLBACK", nil, nil, nil)
            sqlite3_close(blocco)
            vero(attese.map { $0.id } == ["c9"] && ms < 800, "19 consensi letti in \(ms) ms con la coda ferma sul lock")
            _ = r2.svuota()
            r2.chiudi()

            // 18. chiave presente ma illeggibile: errore chiaro, niente ricorsione.
            let cartellaChiave = dir.appendingPathComponent("chiave-illeggibile", isDirectory: true)
            try Registro.preparaCartella(cartellaChiave)
            _ = try Hmac.caricaOCrea(cartella: cartellaChiave)
            chmod(cartellaChiave.appendingPathComponent("chiave").path, 0o000)
            var errore = ""
            do {
                _ = try Hmac.caricaOCrea(cartella: cartellaChiave)
            } catch {
                errore = "\(error)"
            }
            chmod(cartellaChiave.appendingPathComponent("chiave").path, 0o600)
            vero(errore.contains("non si legge"), "18 chiave illeggibile: \(errore)")

            // 17. impostazioni lette da un'altra coda mentre il main le riscrive.
            // Senza lock la copia della struct durante l'assegnazione è un comportamento indefinito:
            // di solito un crash, ma non sempre. Più lettori e molte scritture lo rendono probabile.
            let imp = Impostazioni(cartella: dir)
            imp.carica()
            let gruppo = DispatchGroup()
            let stato = StatoStress()
            for _ in 0..<6 {
                gruppo.enter()
                DispatchQueue.global().async {
                    var n = 0
                    while !stato.basta() {
                        for _ in 0..<200 { n += imp.attuali.cartelle.count + imp.attuali.escludiApp.count }
                    }
                    stato.aggiungi(n)
                    gruppo.leave()
                }
            }
            for k in 0..<1500 {
                imp.modifica { d in
                    d["cartelle"] = (0..<(k % 7 + 1)).map { "~/c\($0)" }
                    d["escludi_app"] = (0..<(k % 5)).map { "com.esempio.\($0)" }
                }
            }
            stato.ferma()
            gruppo.wait()
            vero(stato.letture() > 0, "17 letture concorrenti senza crash")
        } catch {
            vero(false, "registro: \(error)")
        }
    }
}
