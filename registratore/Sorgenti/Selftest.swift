// Selftest.swift: test puri del nucleo, lanciati con --selftest.
//
// Non tocca Accessibilità, TCC, schermo né finestre. Il test del Registro usa una cartella
// temporanea propria (mai LANCILLOTTO_DIR né la cartella dati reale) e la cancella alla fine.
// Stampa "SELFTEST OK n" (n = controlli passati) oppure "SELFTEST FALLITO: ..." con exit 1.
// Sulla build VELENO i test del Redattore e dei Filtri falliscono: è il veleno che attacca.

import Foundation

private final class Banco {
    var passati = 0
    var falliti: [String] = []

    func vero(_ c: Bool, _ nome: String) {
        if c { passati += 1 } else { falliti.append(nome) }
    }

    func uguale<T: Equatable>(_ a: T, _ b: T, _ nome: String) {
        if a == b { passati += 1 } else { falliti.append("\(nome): \(a) invece di \(b)") }
    }
}

enum Selftest {
    static func esegui() -> Int32 {
        let b = Banco()
        let hmac = Hmac.diProva()
        let red = Redattore(hmac: hmac)
        provaControlli(b)
        provaRedattore(b, red)
        provaURL(b, red)
        provaImpronte(b, red, hmac)
        provaFiltri(b)
        provaHmacECompressione(b, hmac)
        provaImpostazioni(b)
        provaCLI(b)
        provaRegistro(b)
        for (ok, nome) in SelftestSchermo.controlli() { b.vero(ok, nome) }
        for (ok, nome) in ProveSensori.controlli() { b.vero(ok, nome) }
        for (ok, nome) in ProveCorrezioni.controlli() { b.vero(ok, nome) }
        if b.falliti.isEmpty {
            print("SELFTEST OK \(b.passati)")
            return 0
        }
        print("SELFTEST FALLITO: \(b.falliti.count) su \(b.passati + b.falliti.count)")
        for f in b.falliti { print("  - " + f) }
        return 1
    }

    // MARK: Controlli numerici

    private static func provaControlli(_ b: Banco) {
        b.vero(Controlli.luhn("4111111111111111"), "luhn valido")
        b.vero(!Controlli.luhn("4111111111111112"), "luhn non valido")
        b.vero(Controlli.ibanValido("IT60X0542811101000000123456"), "iban IT valido")
        b.vero(Controlli.ibanValido("DE89370400440532013000"), "iban DE valido")
        b.vero(!Controlli.ibanValido("IT60X0542811101000000123457"), "iban IT mod-97 sbagliato")
        b.vero(!Controlli.ibanValido("IT60X054281110100000012345"), "iban IT corto")
        b.vero(Controlli.cfValido("RSSMRA85T10A562S"), "cf valido")
        b.vero(!Controlli.cfValido("RSSMRA85T10A562T"), "cf carattere di controllo sbagliato")
    }

    // MARK: Redattore

    private static func segnaposto(_ s: String, _ tipo: String) -> Bool {
        s.range(of: "\\[\(tipo)#[0-9a-f]{4}\\]", options: .regularExpression) != nil
    }

    private static func provaRedattore(_ b: Banco, _ r: Redattore) {
        func caso(_ testo: String, _ tipo: String, _ via: String, _ nome: String) {
            let out = r.redigi(testo).testo
            b.vero(segnaposto(out, tipo) && !out.contains(via), "\(nome): \(out)")
        }
        func resta(_ testo: String, _ nome: String) {
            let out = r.redigi(testo)
            b.uguale(out.testo, testo, nome)
        }
        // CARTA
        caso("carta 4111 1111 1111 1111 scade 12/29", "CARTA", "1111 1111", "carta a gruppi")
        caso("4111111111111111", "CARTA", "4111111111111111", "carta compatta")
        resta("numero 4111111111111112 che non passa Luhn", "16 cifre senza Luhn")
        // IBAN
        caso("IBAN IT60X0542811101000000123456 per il bonifico", "IBAN", "0542811101", "iban IT")
        caso("IT60 X054 2811 1010 0000 0123 456 e poi", "IBAN", "2811 1010", "iban IT a gruppi")
        caso("DE89370400440532013000", "IBAN", "370400440532013000", "iban DE")
        resta("IT60X0542811101000000123457", "iban con controllo sbagliato")
        b.vero(r.redigi("IT60 X054 2811 1010 0000 0123 456 e poi").testo.hasSuffix(" e poi"), "iban a gruppi non mangia il testo dopo")
        // CF
        caso("CF: RSSMRA85T10A562S.", "CF", "RSSMRA85T10A562S", "codice fiscale")
        resta("RSSMRA85T10A562T", "cf con controllo sbagliato")
        // CHIAVE
        caso("chiave sk-ant-api03-ABCDEFGHIJ1234567890xyz", "CHIAVE", "ABCDEFGHIJ", "sk-ant")
        caso("sk-proj-abcdefghijklmnop1234", "CHIAVE", "abcdefghijklmnop", "sk-")
        caso("token ghp_abcdefghijklmnopqrstuvwxyz0123456789", "CHIAVE", "abcdefghijklmnopqrst", "ghp_")
        caso("github_pat_11ABCDEFG0123456789_abcdefghij", "CHIAVE", "11ABCDEFG", "github_pat_")
        caso("AKIAIOSFODNN7EXAMPLE", "CHIAVE", "IOSFODNN7", "AKIA")
        caso("xoxb-1234567890-abcdefghij", "CHIAVE", "1234567890-abc", "xoxb")
        caso("AIzaSyA1234567890abcdefghijklmnopqrstu", "CHIAVE", "SyA1234567890", "AIza")
        caso("GOCSPX-abcdefghij123456", "CHIAVE", "abcdefghij123456", "GOCSPX")
        resta("desk-topabcdefghijklmnopqrstu e sk-1", "parole con sk- dentro")
        // JWT
        caso("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abcdEFGH_ij-kl", "JWT", "eyJzdWIi", "jwt")
        resta("eyJ.abc.def", "jwt troppo corto")
        // PEM
        caso("-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIBAAJBAKj34GkxFhD90vcNLYLInFEX6Ppy1tPf9Cnzj4p4WGeKLs1Pt8Qu\n-----END RSA PRIVATE KEY-----", "PEM", "MIIBOgIB", "pem completo") // gitleaks:allow (chiave finta del test)
        caso("-----BEGIN PRIVATE KEY-----", "PEM", "BEGIN PRIVATE", "pem solo intestazione") // gitleaks:allow
        resta("-----BEGIN PUBLIC KEY-----", "chiave pubblica")
        // OTP
        caso("Il tuo codice di verifica è 482913", "OTP", "482913", "otp con parola chiave")
        caso("482913", "OTP", "482913", "otp da solo sulla riga")
        caso("Your code: 12345678", "OTP", "12345678", "otp 8 cifre")
        resta("Ordine 482913 spedito ieri", "6 cifre senza contesto")
        resta("Totale: 1.234,56 EUR", "importo")
        resta("codice 1.234567", "numero decimale non è otp")
        // PASSWORD
        let p = r.redigi("password: Segreta!1 e poi").testo
        b.vero(p.hasPrefix("password: [PASSWORD#") && !p.contains("Segreta") && p.hasSuffix(" e poi"), "password dopo i due punti: \(p)")
        caso("pwd=abc123", "PASSWORD", "abc123", "pwd=")
        caso("Passcode: 9911", "PASSWORD", "9911", "passcode")
        resta("la password è lunga", "parola password senza valore")
        // Conteggio e determinismo
        let d = r.redigi("IT60X0542811101000000123456 e 4111111111111111")
        b.uguale(d.n, 2, "conteggio redazioni")
        b.uguale(r.redigi("IT60X0542811101000000123456").testo, r.redigi("IT60X0542811101000000123456").testo, "segnaposto deterministico")
        b.uguale(r.redigi(r.redigi("IT60X0542811101000000123456 sk-ant-api03-ABCDEFGHIJ1234567890xyz").testo).n, 0, "redazione idempotente")
        // Normalizzazione e titoli
        b.uguale(Redattore.normalizzaRiga("  a   b \t c  "), "a b c", "normalizza spazi")
        b.uguale(Redattore.normalizzaRiga(" x "), nil, "riga sotto i 2 caratteri")
        b.uguale(Redattore.normalizzaRiga("   "), nil, "riga vuota")
        b.uguale(r.pulisciTitolo(String(repeating: "a", count: 300)).count, 200, "titolo troncato a 200")
        b.vero(segnaposto(r.pulisciTitolo("Bonifico IT60X0542811101000000123456"), "IBAN"), "titolo redatto")
    }

    // MARK: URL

    private static func provaURL(_ b: Banco, _ r: Redattore) {
        let u = r.pulisciURL("https://portale.fornitore-esempio.it/ordini?token=SEGRETO#frammento")
        b.uguale(u?.completo, "https://portale.fornitore-esempio.it/ordini", "url senza query e frammento")
        b.uguale(u?.etichetta, "portale.fornitore-esempio.it/ordini", "etichetta url")
        let v = r.pulisciURL("https://utente:pw@www.Esempio.it:8080/a/b/c?q=1")
        b.uguale(v?.completo, "https://www.esempio.it:8080/a/b/c", "url senza credenziali")
        b.uguale(v?.dominio, "esempio.it", "dominio senza www")
        b.uguale(v?.etichetta, "esempio.it/a", "etichetta col primo segmento")
        b.uguale(r.pulisciURL("portale.esempio.it/ordini")?.completo, "https://portale.esempio.it/ordini", "barra indirizzi senza schema")
        b.vero(r.pulisciURL("cerca qualcosa") == nil, "testo che non è un url")
        b.vero(r.pulisciURL("ciao") == nil, "parola senza punto")
        b.uguale(r.pulisciURL("https://x.it/reset/abcdef1234567890abcdef")?.completo, "https://x.it/reset/[ID]", "segmento opaco")
        b.uguale(r.pulisciURL("https://x.it")?.etichetta, "x.it", "url senza path")
        b.uguale(r.pulisciURL("about:blank")?.completo, "about:blank", "about:blank")
    }

    // MARK: Impronte

    private static func provaImpronte(_ b: Banco, _ r: Redattore, _ h: Hmac) {
        let imp = r.impronte("Ordine ORD-2026-4521 importo 1.234,56 IBAN IT60X0542811101000000123456 a Mario@Esempio.it")
        let tipi = Set(imp.map { $0.tipo })
        b.vero(tipi == ["numero", "iban", "email", "codice"], "tipi di impronta: \(tipi.sorted())")
        b.vero(imp.contains(Impronta(h: h.hex("123456"), tipo: "numero")), "impronta numero = HMAC delle sole cifre")
        b.vero(imp.contains(Impronta(h: h.hex("IT60X0542811101000000123456"), tipo: "iban")), "impronta iban")
        b.vero(imp.contains(Impronta(h: h.hex("mario@esempio.it"), tipo: "email")), "impronta email minuscola")
        b.vero(imp.contains(Impronta(h: h.hex("ORD-2026-4521"), tipo: "codice")), "impronta codice")
        b.vero(!imp.contains { $0.tipo == "codice" && $0.h == h.hex("IT60X0542811101000000123456") }, "iban non anche codice")
        b.vero(r.impronte("sk-ant-api03-ABCDEFGHIJ1234567890xyz").isEmpty, "nessuna impronta da una chiave")
        b.vero(r.impronte("4111111111111111").isEmpty, "nessuna impronta da una carta")
        b.vero(r.impronte("ore 12:30 del 20/10").isEmpty, "niente impronte da numeri corti")
    }

    // MARK: Filtri

    private static func provaFiltri(_ b: Banco) {
        let r = Regole()
        func o(_ bundle: String, nome: String? = nil, titolo: String? = nil, url: String? = nil,
               ruolo: String? = nil, subruolo: String? = nil, secure: Bool = false, attributi: [String: String] = [:]) -> Osservazione {
            Osservazione(ora: 1000, bundle: bundle, nomeApp: nome, titolo: titolo, url: url, attributiFinestra: attributi,
                         ruoloFocus: ruolo, subruoloFocus: subruolo, secureInput: secure)
        }
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", titolo: "Ordini", url: "https://portale.esempio.it/ordini"), r), .pieno, "osservazione normale")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome"), Regole(pausaFino: 2000)), .scarta, "pausa")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome"), Regole(pausaFino: 500)), .pieno, "pausa scaduta")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", secure: true), r), .protetto, "secure input")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", ruolo: "AXTextField", subruolo: "AXSecureTextField"), r), .protetto, "campo protetto")
        b.uguale(RegoleFiltro.decidi(o("com.1password.1password", titolo: "Cassaforte"), r), .escluso("app"), "1password")
        b.uguale(RegoleFiltro.decidi(o("com.apple.MobileSMS"), r), .escluso("app"), "Messaggi")
        b.uguale(RegoleFiltro.decidi(o("com.esempio.app", nome: "MyBank"), r), .escluso("app"), "parola bank nel nome")
        b.uguale(RegoleFiltro.decidi(o("it.fineco.mobile"), r), .escluso("app"), "parola fineco nel bundle")
        b.uguale(RegoleFiltro.decidi(o("com.esempio.x"), Regole(escludiApp: ["com.esempio"])), .escluso("app"), "esclusione aggiunta per prefisso")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", titolo: "Navigazione privata — x"), r), .escluso("privata"), "titolo privato")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", titolo: "Nuova scheda - Google Chrome (Incognito)"), r), .escluso("privata"), "incognito")
        b.uguale(RegoleFiltro.decidi(o("org.mozilla.firefox", titolo: "Pagina", attributi: ["AXIdentifier": "PrivateBrowsingWindow"]), r), .escluso("privata"), "attributo privato")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", titolo: "Conto", url: "https://www.fineco.it/conto"), r), .escluso("dominio"), "dominio banca")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", url: "https://accounts.google.com/x"), r), .escluso("dominio"), "login google")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", url: "https://esempio.it/login?next=1"), r), .escluso("dominio"), "path di login")
        b.uguale(RegoleFiltro.decidi(o("org.mozilla.firefox", url: "https://web.bbva.it/home"), r), .escluso("dominio"), "banca bbva")
        b.uguale(RegoleFiltro.decidi(o("org.mozilla.firefox", url: "https://www.relaxbanking.it/x"), r), .escluso("dominio"), "banca dal nome dell'host")
        b.vero(!Esclusioni.paroleHost.contains { "www.decathlon.it".contains($0) }, "host comune non escluso")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", url: "https://notfineco.it/x"), r), .pieno, "suffisso solo su confine di dominio")
        b.uguale(RegoleFiltro.decidi(o("com.google.Chrome", url: "https://a.esempio.it/x"), Regole(escludiDomini: ["esempio.it"])), .escluso("dominio"), "dominio aggiunto")
        b.vero(RegoleFiltro.cartellaEsclusa("/Users/x/Documents/progetto/.git/config"), "cartella .git")
        b.vero(RegoleFiltro.cartellaEsclusa("/Users/x/Library/Caches/a"), "cartella Library")
        b.vero(RegoleFiltro.cartellaEsclusa("/Users/x/Documents/app/.env.local"), ".env.local")
        b.vero(RegoleFiltro.cartellaEsclusa("/Users/x/Documents/client_secrets.json"), "nome con secret")
        b.vero(!RegoleFiltro.cartellaEsclusa("/Users/x/Documents/fattura.pdf"), "documento normale")
        b.uguale(RegoleFiltro.classificaCartella("/Users/x/Downloads/a.pdf", home: "/Users/x"), "download", "cartella download")
        b.uguale(RegoleFiltro.classificaCartella("/Users/x/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/U/a.pdf", home: "/Users/x"), "mail_allegati", "allegato mail")
        b.uguale(RegoleFiltro.classificaCartella("/Users/x/Documents/a.pdf", home: "/Users/x"), "documenti", "cartella documenti")
        b.uguale(RegoleFiltro.classificaCartella("/tmp/a.pdf", home: "/Users/x"), "altro", "cartella altro")
    }

    // MARK: HMAC e compressione

    private static func provaHmacECompressione(_ b: Banco, _ h: Hmac) {
        // Vettore calcolato con Python: hmac.new(b'\x07'*32, b'abc', sha256).hexdigest()[:32]
        b.uguale(h.hex("abc"), "127da4ced6a839b8f6118bc244684d26", "hmac uguale a Python")
        b.uguale(h.hex("abc"), h.hex("abc"), "hmac deterministico")
        b.vero(h.hex("abc") != h.hex("abd"), "hmac distingue")
        b.vero(Hmac(chiave: .init(data: Data(repeating: 8, count: 32))).hex("abc") != h.hex("abc"), "hmac dipende dalla chiave")
        b.uguale(sha256Breve("Totale: 1.234,56 EUR"), "0071ee5f9d0affb1653f0112aed2d05b", "sha256 uguale a Python")
        for testo in ["", "ciao", "àèìòù ciao " + String(repeating: "ripetizione ", count: 500), String(repeating: "x", count: 100_000)] {
            let z = Compressione.comprimi(testo)
            b.uguale(Compressione.decomprimiTesto(z), testo, "compressione andata e ritorno (\(testo.count) caratteri)")
        }
        // Prodotto da Python: zlib.compressobj(9, zlib.DEFLATED, -15) su "ciao ciao ciao àèì".
        let python = Data([75, 206, 76, 204, 87, 72, 134, 19, 135, 23, 28, 94, 113, 120, 13, 0])
        b.uguale(Compressione.decomprimiTesto(python), "ciao ciao ciao àèì", "deflate raw letto come Python lo scrive")
    }

    // MARK: Impostazioni

    private static func provaImpostazioni(_ b: Banco) {
        let d = ImpostazioniDati.daDizionario([
            "pausa_fino": 5, "conservazione_giorni": 7, "escludi_app": ["com.x"], "valori_campi": false,
            "dimentica_richieste": [["da": 1, "a": 2], ["da": 5, "a": 1]],
        ])
        b.uguale(d.pausaFino, 5, "impostazioni pausa_fino")
        b.uguale(d.conservazioneGiorni, 7, "impostazioni conservazione")
        b.uguale(d.valoriCampi, false, "impostazioni valori_campi")
        b.uguale(d.dimenticaRichieste, [RichiestaDimentica(da: 1, a: 2)], "richieste dimentica valide")
        let vecchie = ImpostazioniDati.daDizionario(["escludi_app": ["a", "b"], "escludi_domini": ["x.it"]])
        let nuove = ImpostazioniDati.daDizionario(["escludi_app": ["a"]])
        b.uguale(Impostazioni.esclusioniTolte(da: vecchie, a: nuove), ["app:b", "dominio:x.it"], "esclusioni tolte")
        b.uguale(ImpostazioniDati.daDizionario(ImpostazioniDati.dizionarioDefault), ImpostazioniDati(), "default coerenti")
    }

    // MARK: Ricerca della CLI in una casa temporanea

    private static func provaCLI(_ b: Banco) {
        let fm = FileManager.default
        let casa = fm.temporaryDirectory.appendingPathComponent("lancillotto-cli-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: casa) }
        let vuota = casa.appendingPathComponent("vuota")
        func eseguibile(_ rel: String) {
            let u = casa.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        b.vero(CLI.trova(path: "", accanto: vuota, casa: casa.path) == nil, "cli assente")
        eseguibile("bin/lancillotto")
        b.uguale(CLI.trova(path: "/usr/bin:/bin", accanto: vuota, casa: casa.path) ?? "",
                 casa.path + "/bin/lancillotto", "cli in ~/bin con PATH di launchd")
        eseguibile(".local/bin/lancillotto")
        b.uguale(CLI.trova(path: "", accanto: vuota, casa: casa.path) ?? "",
                 casa.path + "/.local/bin/lancillotto", "cli in ~/.local/bin prima di ~/bin")
    }

    // MARK: Registro su un db temporaneo

    private static func provaRegistro(_ b: Banco) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lancillotto-selftest-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try Registro.preparaCartella(dir)
            let hmac = try Hmac.caricaOCrea(cartella: dir)
            let hmac2 = try Hmac.caricaOCrea(cartella: dir)
            b.uguale(hmac.hex("x"), hmac2.hex("x"), "chiave riletta uguale")
            b.uguale(permessi(dir.appendingPathComponent("chiave").path), 0o600, "chiave 600")
            let r = Registro(cartella: dir, hmac: hmac)
            try r.apri()
            b.uguale(permessi(dir.path), 0o700, "cartella 700")
            b.uguale(permessi(r.percorso), 0o600, "registro 600")
            let app = AppRif(bundle: "com.esempio.app", nome: "Esempio")
            let fin = OggettoRif(tipo: "finestra", valore: "com.esempio.app\u{0}Titolo", etichetta: "Titolo IT60X0542811101000000123456")
            let t0: Int64 = 1_792_000_000_000
            let e1 = r.evento(tipo: "finestra", ts: t0, app: app, oggetto: fin, dettaglio: ["pid": 1], tasti: 0, click: 0)
            r.durata(id: e1, ts: t0, dur: 5000, tasti: 3, click: 1)
            r.durata(id: e1, ts: t0, dur: 9000, tasti: 4, click: 1)
            let e2 = r.campo(ts: t0 + 1000, dur: 2000, app: app, finestra: fin, ruolo: "AXTextField", etichetta: "Importo",
                             valore: "1.234,56 e la carta 4111111111111111")
            r.righe(ts: t0 + 2000, app: app, finestra: fin, fonte: "ax", ms: 3, righe: ["Riga uno", "Riga  uno", "Riga due", "x"], troncato: false)
            r.righe(ts: t0 + 3000, app: app, finestra: fin, fonte: "ax", ms: 3, righe: ["Riga uno", "Riga tre"], troncato: false)
            r.impronte(eventoId: e1, testo: "ordine 123456", fonte: "titolo")
            r.salute(sensore: "prova", stato: "ok", ts: t0)
            b.vero(r.svuota(), "lotto scritto")
            let letto = try r.leggi { d -> [String: Int64] in
                var m: [String: Int64] = [:]
                m["eventi"] = try d.intero("SELECT COUNT(*) FROM evento")
                m["dur"] = try d.intero("SELECT dur_ms FROM evento WHERE id = ?", [e1])
                m["tasti"] = try d.intero("SELECT tasti FROM evento WHERE id = ?", [e1])
                m["righe"] = try d.intero("SELECT COUNT(*) FROM riga")
                m["volteUno"] = try d.intero("SELECT volte FROM riga WHERE h = ?", [sha256Breve("Riga uno")])
                m["schermi"] = try d.intero("SELECT COUNT(*) FROM schermo")
                m["impronte"] = try d.intero("SELECT COUNT(*) FROM impronta")
                m["app"] = try d.intero("SELECT COUNT(*) FROM app")
                m["oggetti"] = try d.intero("SELECT COUNT(*) FROM oggetto")
                m["giorno"] = try d.intero("SELECT eventi FROM giorno")
                m["schema"] = Int64(try d.testo("SELECT valore FROM meta WHERE chiave = 'schema_versione'") ?? "0")
                return m
            } ?? [:]
            b.uguale(letto["eventi"], 4, "eventi scritti")
            b.uguale(letto["dur"], 9000, "durata: vince l'ultima")
            b.uguale(letto["tasti"], 4, "tasti del tratto")
            b.uguale(letto["righe"], 3, "righe uniche (normalizzate e deduplicate)")
            b.uguale(letto["volteUno"], 1, "riga ripetuta non riconteggiata se resta a schermo")
            b.uguale(letto["schermi"], 2, "istantanee di schermo")
            b.vero((letto["impronte"] ?? 0) >= 2, "impronte scritte")
            b.uguale(letto["app"], 1, "app interned")
            b.uguale(letto["oggetti"], 1, "oggetto interned")
            b.uguale(letto["giorno"], 4, "giorno aggiornato")
            b.uguale(letto["schema"], 1, "schema_versione")
            let valore = try r.leggi { d -> String? in
                let s = try d.istruzione("SELECT valore_z, lunghezza, redazioni FROM campo WHERE evento_id = ?")
                d.lega(s, [e2])
                defer { s.azzera() }
                guard try s.passo(), let z = s.blob(0) else { return nil }
                return Compressione.decomprimiTesto(z)
            } ?? nil
            b.vero(valore?.hasPrefix("1.234,56 e la carta [CARTA#") ?? false, "valore del campo redatto: \(valore ?? "nil")")
            let etichetta = try r.leggi { d in try d.testo("SELECT etichetta FROM oggetto") } ?? nil
            b.vero(etichetta.map { segnaposto($0, "IBAN") } ?? false, "etichetta oggetto ripassata dal redattore")
            let modo = try r.leggi { d in try d.testo("PRAGMA journal_mode") } ?? nil
            b.uguale(modo, "wal", "journal WAL")
            let tolta = try r.leggi { d in try d.testo("SELECT tolte FROM schermo ORDER BY ts DESC LIMIT 1") } ?? nil
            b.vero(tolta != nil && tolta != "[]", "righe tolte nella seconda istantanea")

            // Fusione dei tratti nell'Annotatore.
            let ctx = Contesto()
            let ann = Annotatore(registro: r, filtri: Filtri(), contesto: ctx, home: "/Users/x", secureInput: { false })
            let a = AppRif(bundle: "com.esempio.a", nome: "A")
            let bb = AppRif(bundle: "com.esempio.b", nome: "B")
            let t1 = t0 + 100_000
            ann.cambiaApp(a, pid: 1, ts: t1)
            ann.cambiaFinestra(titolo: "Uno", url: nil, documento: nil, ts: t1)
            ann.battito(t1 + 10_000)
            ann.cambiaFinestra(titolo: "Uno", url: nil, documento: nil, ts: t1 + 20_000)
            ann.cambiaApp(bb, pid: 2, ts: t1 + 30_000)
            ann.cambiaApp(a, pid: 1, ts: t1 + 40_000)
            ann.cambiaFinestra(titolo: "Uno", url: nil, documento: nil, ts: t1 + 40_000)
            ann.inizioInattivita(da: t1 + 50_000)
            ann.fineInattivita(da: t1 + 50_000, ts: t1 + 300_000)
            ann.chiudi(t1 + 310_000)
            let tratti = try r.leggi { d in try d.intero("SELECT COUNT(*) FROM evento WHERE tipo = 'finestra' AND ts >= ?", [t1]) } ?? nil
            // A "Uno" (il titolo arriva sul tratto appena aperto, poi il battito lo allunga),
            // B senza titolo, A "Uno" dopo B (oltre 30 s dal primo: tratto nuovo), A "Uno" dopo l'inattività.
            b.uguale(tratti, 4, "tratti finestra")
            let vuoti = try r.leggi { d in try d.intero("SELECT COUNT(*) FROM evento WHERE tipo = 'finestra' AND ts >= ? AND ogg_id IS NULL AND app_id = (SELECT id FROM app WHERE bundle = 'com.esempio.a')", [t1]) } ?? nil
            b.uguale(vuoti, 0, "nessun tratto vuoto prima del titolo")
            let lungo = try r.leggi { d in try d.intero("SELECT dur_ms FROM evento WHERE tipo = 'finestra' AND ts = ?", [t1]) } ?? nil
            b.vero(lungo != nil, "tratto iniziale presente")
            let durUno = try r.leggi { d in
                try d.intero("SELECT e.dur_ms FROM evento e JOIN oggetto o ON o.id = e.ogg_id WHERE e.tipo = 'finestra' AND e.ts = ?", [t1])
            } ?? nil
            b.uguale(durUno, 30_000, "tratto Uno allungato dal battito fino al cambio app")
            let inattivo = try r.leggi { d in try d.intero("SELECT dur_ms FROM evento WHERE tipo = 'inattivo'") } ?? nil
            b.uguale(inattivo, 250_000, "evento inattivo con durata")
            let troncato = try r.leggi { d in
                try d.intero("SELECT dur_ms FROM evento WHERE tipo = 'finestra' AND ts = ?", [t1 + 40_000])
            } ?? nil
            b.vero((troncato ?? -1) <= 10_000, "tratto chiuso all'inizio dell'inattività: \(troncato ?? -1)")

            // Esclusione con l'Annotatore: niente titolo.
            ann.cambiaApp(AppRif(bundle: "com.1password.1password", nome: "1Password"), pid: 3, ts: t1 + 400_000)
            ann.cambiaFinestra(titolo: "Cassaforte Segreta", url: nil, documento: nil, ts: t1 + 400_000)
            ann.chiudi(t1 + 410_000)
            let escluso = try r.leggi { d in try d.intero("SELECT COUNT(*) FROM evento WHERE tipo = 'escluso' AND ogg_id IS NULL") } ?? nil
            b.uguale(escluso, 1, "app esclusa: solo tratto escluso")
            let segreta = try r.leggi { d in try d.intero("SELECT COUNT(*) FROM oggetto WHERE etichetta LIKE '%Cassaforte%'") } ?? nil
            b.uguale(segreta, 0, "titolo dell'app esclusa non salvato")

            // Consenso L2.
            _ = try r.leggi { d in
                try d.scrivi("INSERT INTO consenso(id, t0, t1, descrizione, richiesto_ts) VALUES('c1', 1, 2, 'prova', 3)")
            }
            b.uguale(r.consensiInAttesa().map { $0.id }, ["c1"], "consenso in attesa")
            b.vero(r.decidiConsenso(id: "c1", si: true, ora: 10), "consenso deciso")
            b.vero(!r.decidiConsenso(id: "c1", si: false, ora: 11), "consenso non si decide due volte")
            let scade = try r.leggi { d in try d.intero("SELECT scade_ts FROM consenso WHERE id = 'c1'") } ?? nil
            b.uguale(scade, 600_010, "scade dopo 10 minuti")

            // Dimentica, esclusione retroattiva, conservazione.
            let tolti = r.dimenticaSubito(da: t0, a: t0 + 3500)
            b.uguale(tolti, 4, "dimentica: eventi nell'intervallo")
            let rimasti = try r.leggi { d -> [Int64?] in
                [try d.intero("SELECT COUNT(*) FROM riga"), try d.intero("SELECT COUNT(*) FROM campo"),
                 try d.intero("SELECT COUNT(*) FROM schermo"), try d.intero("SELECT COUNT(*) FROM impronta WHERE evento_id = ?", [e1])]
            } ?? []
            b.uguale(rimasti, [0, 0, 0, 0], "dimentica: righe, campi, schermi e impronte orfani via")
            r.cancellaApp(bundle: "com.esempio.a")
            let restiA = try r.leggi { d in
                try d.intero("SELECT COUNT(*) FROM evento WHERE app_id = (SELECT id FROM app WHERE bundle = 'com.esempio.a')")
            } ?? nil
            b.uguale(restiA, 0, "esclusione retroattiva")
            let esclusa = try r.leggi { d in try d.intero("SELECT esclusa FROM app WHERE bundle = 'com.esempio.a'") } ?? nil
            b.uguale(esclusa, 1, "app marcata esclusa")
            let vecchi = r.conserva(giorni: 14, ora: t0 + 30 * 86_400_000)
            b.vero(vecchi > 0, "conservazione toglie gli eventi vecchi")
            let dopo = try r.leggi { d in try d.intero("SELECT COUNT(*) FROM evento") } ?? nil
            b.uguale(dopo, 0, "registro vuoto dopo la conservazione")
            // Dopo le cancellazioni il registro scrive ancora (cache svuotate).
            r.evento(tipo: "finestra", ts: t0 + 31 * 86_400_000, app: app, oggetto: fin)
            b.vero(r.svuota(), "scrittura dopo le cancellazioni")
            r.chiudi()
            // Riapertura: gli id ripartono dal massimo.
            let r2 = Registro(cartella: dir, hmac: hmac)
            try r2.apri()
            let id = r2.evento(tipo: "servizio", ts: t0, dettaglio: ["cosa": "avvio"])
            b.vero(id > e2, "id dopo la riapertura")
            b.vero(r2.svuota(), "scrittura dopo la riapertura")
            r2.chiudi()
        } catch {
            b.vero(false, "registro: \(error)")
        }
    }

    private static func permessi(_ p: String) -> Int {
        var st = stat()
        guard stat(p, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o777)
    }
}
