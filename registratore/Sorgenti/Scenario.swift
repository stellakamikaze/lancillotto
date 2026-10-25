// Scenario.swift: --scenario-sintetico, un registro finto con orari fissi, scritto dal VERO
// Annotatore (quindi dai veri Filtri e dal vero Redattore) e dal vero Registro.
//
// Contenuto: 3 giorni lavorativi dal 20/10/2026 alle 8:30 (ora locale). Ogni giorno:
//   - 4 ripetizioni della routine: Mail apre l'allegato PDF (cartella mail_allegati)
//     -> Anteprima (documento pdf) -> 6 volte [cmd+c con appunti cc=N -> Chrome
//     portale.fornitore-esempio.it/ordini -> campo_focus "Importo" -> cmd+v con cc=N];
//   - una catena di file: file_crea in Download (da mail.google.com), aperto in Anteprima,
//     file_sposta in Documenti;
//   - rumore: Finder, Safari su un sito di notizie, Spotify;
//   - istantanee di schermo con righe ripetute (per la deduplica).
// Più un campo_valore "Importo" = "1.234,56" e i VELENI, che non devono lasciare traccia:
//   IBAN IT60X0542811101000000123456 nel titolo, 1Password "Cassaforte Personale",
//   AXSecureTextField "Segreta123!Veleno", ?token=VELENOTOKEN#frammento,
//   sk-ant-api03-VELENOCHIAVE... a schermo, "Navigazione privata — VelenoPrivato",
//   www.fineco.it "Conto VelenoBanca"; e i veleni della revisione (veleniRevisione): campo lasciato
//   su una pagina esclusa, scheda e Cronologia, query senza schema, password in una frase, campo
//   Password non protetto, download dalla banca, Firefox senza URL, Safari, un .env in TextEdit.
// Alla fine: PRAGMA wal_checkpoint(TRUNCATE) e "SCENARIO OK eventi=n".
//
// Scrive solo in LANCILLOTTO_DIR, che deve essere impostata e non può essere la cartella reale.

import Foundation

private final class Interruttore {
    var acceso = false
}

enum Scenario {
    static let home = "/Users/esempio"

    static func esegui() -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["LANCILLOTTO_DIR"], !dir.isEmpty else {
            FileHandle.standardError.write("SCENARIO FALLITO: LANCILLOTTO_DIR non impostata\n".data(using: .utf8)!)
            return 2
        }
        let cartella = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        if cartella.resolvingSymlinksInPath().path == Registro.cartellaReale().resolvingSymlinksInPath().path {
            FileHandle.standardError.write("SCENARIO FALLITO: LANCILLOTTO_DIR punta alla cartella dati reale\n".data(using: .utf8)!)
            return 2
        }
        do {
            try Registro.preparaCartella(cartella)
            let hmac = try Hmac.caricaOCrea(cartella: cartella)
            let registro = Registro(cartella: cartella, hmac: hmac)
            try registro.apri()
            let secure = Interruttore()
            let ann = Annotatore(registro: registro, filtri: Filtri(regole: Regole()), contesto: Contesto(),
                                 home: home, secureInput: { secure.acceso })
            var gen = Generatore(ann: ann, secure: secure)
            for giorno in 0..<3 {
                gen.giornata(giorno)
                guard registro.svuota() else {
                    throw ErroreDb(codice: 0, messaggio: "lotto non scritto: \(registro.statoAttuale().errore ?? "?")")
                }
            }
            let n = try registro.leggi { d in try d.intero("SELECT COUNT(*) FROM evento") } ?? nil
            try registro.checkpoint()
            registro.chiudi()
            print("SCENARIO OK eventi=\(n ?? 0)")
            return 0
        } catch {
            print("SCENARIO FALLITO: \(error)")
            return 1
        }
    }

    /// 8:30 ora locale del 20/10/2026 + `giorno` giorni.
    static func inizio(_ giorno: Int) -> Int64 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = DateComponents(year: 2026, month: 10, day: 20 + giorno, hour: 8, minute: 30)
        return Int64((cal.date(from: c) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000)
    }
}

private struct Generatore {
    let ann: Annotatore
    let secure: Interruttore
    var t: Int64 = 0
    var cc = 1000
    var pid: Int32 = 400
    var campoScritto = false

    static let mail = AppRif(bundle: "com.apple.mail", nome: "Mail")
    static let anteprima = AppRif(bundle: "com.apple.Preview", nome: "Anteprima")
    static let chrome = AppRif(bundle: "com.google.Chrome", nome: "Google Chrome")
    static let finder = AppRif(bundle: "com.apple.finder", nome: "Finder")
    static let safari = AppRif(bundle: "com.apple.Safari", nome: "Safari")
    static let spotify = AppRif(bundle: "com.spotify.client", nome: "Spotify")
    static let unoPassword = AppRif(bundle: "com.1password.1password", nome: "1Password")
    static let portale = "https://portale.fornitore-esempio.it/ordini"

    init(ann: Annotatore, secure: Interruttore) {
        self.ann = ann
        self.secure = secure
    }

    mutating func passa(_ secondi: Double) {
        t += Int64(secondi * 1000)
    }

    mutating func app(_ a: AppRif, _ titolo: String?, url: String? = nil, documento: InfoFile? = nil,
                      attributi: [String: String] = [:]) {
        pid += 1
        ann.cambiaApp(a, pid: pid, ts: t)
        ann.cambiaFinestra(titolo: titolo, url: url, documento: documento, attributi: attributi, ts: t)
    }

    mutating func giornata(_ g: Int) {
        t = Scenario.inizio(g)
        if g > 0 { ann.riprendi("sblocco", ts: t) }
        for r in 0..<4 {
            routine(g, r)
            rumore(g, r)
            if r == 1 { catenaFile(g) }
            if g == 0 && r == 2 { veleni() }
        }
        passa(60)
        ann.sospendi("blocco", ts: t)
    }

    mutating func routine(_ g: Int, _ r: Int) {
        let n = 4500 + g * 10 + r
        app(Generatore.mail, "Ordine \(n) - Fornitore Esempio")
        passa(25)
        ann.clic(ruolo: "AXButton", etichetta: "ordine_\(n).pdf", web: false, ts: t)
        passa(2)
        let allegato = InfoFile(path: Scenario.home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/7C1E-\(g)\(r)/ordine_\(n).pdf")
        let righe = ["Ordine n. \(n)", "Fornitore Esempio S.r.l.", "Totale: 1.234,56 EUR",
                     "Pagamento a 30 giorni", "Pagamento a 30 giorni", "Pagina 1 di 1"]
        for k in 0..<6 {
            app(Generatore.anteprima, "ordine_\(n).pdf", documento: allegato)
            if k == 0 || k == 3 {
                ann.schermo(fonte: "ax", ms: 12, righe: righe, troncato: false, ts: t)
            }
            passa(6)
            ann.comando(tasti: "cmd+c", cc: nil, ts: t)
            cc += 1
            ann.appunti(cc: cc, tipi: ["public.utf8-plain-text"], riservato: false, lunghezza: 8, selezione: "1.234,56", ts: t)
            ann.input(tasti: 2, click: 1)
            passa(2)
            app(Generatore.chrome, "Ordini - Portale Fornitore", url: Generatore.portale)
            passa(2)
            ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Importo", ts: t)
            passa(1)
            ann.comando(tasti: "cmd+v", cc: cc, ts: t)
            ann.input(tasti: 1, click: 1)
            passa(3)
            if !campoScritto {
                campoScritto = true
                ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Importo", valore: "1.234,56", durMs: 4000, ts: t)
            }
            ann.cambiaFocus(ruolo: "AXButton", subruolo: nil, etichetta: "Salva", ts: t)
            ann.clic(ruolo: "AXButton", etichetta: "Salva", web: false, ts: t)
            passa(4)
        }
    }

    mutating func rumore(_ g: Int, _ r: Int) {
        app(Generatore.finder, "Download")
        passa(15)
        // Il Safari del rumore ha il segno provato di finestra normale (privata = "0"), come lo
        // scriverà il sensore quando la sonda della fase 0 lo trova; quello dei veleni no.
        app(Generatore.safari, "Notizia del giorno - Il Post", url: "https://www.ilpost.it/2026/10/2\(g)/notizia-\(r)/",
            attributi: ["privata": "0"])
        ann.schermo(fonte: "ax", ms: 20, righe: ["Il Post", "Notizia del giorno numero \(r)", "Leggi anche"], troncato: false, ts: t)
        passa(90)
        app(Generatore.spotify, "Spotify Premium")
        passa(10)
    }

    mutating func catenaFile(_ g: Int) {
        let nome = "fattura_2026_\(118 + g).pdf"
        let scaricato = InfoFile(path: Scenario.home + "/Downloads/" + nome, inode: Int64(880_000 + g), provenienza: "mail.google.com")
        ann.file(tipo: "file_crea", info: scaricato, ts: t)
        passa(3)
        app(Generatore.anteprima, nome, documento: scaricato)
        passa(30)
        var spostato = scaricato
        spostato.path = Scenario.home + "/Documents/Fatture/" + nome
        ann.file(tipo: "file_sposta", info: spostato, daPath: scaricato.path, ts: t)
        passa(5)
    }

    mutating func veleni() {
        // IBAN nel titolo di Chrome: deve restare solo [IBAN#abcd].
        app(Generatore.chrome, "Bonifico a IT60X0542811101000000123456 - Portale Fornitore",
            url: "https://portale.fornitore-esempio.it/pagamenti")
        passa(20)
        // 1Password: app esclusa, né titolo né testo.
        app(Generatore.unoPassword, "Cassaforte Personale")
        ann.schermo(fonte: "ax", ms: 5, righe: ["Cassaforte Personale", "Login banca"], troncato: false, ts: t)
        ann.comando(tasti: "cmd+c", cc: nil, ts: t)
        passa(15)
        // Campo protetto: né il valore né l'evento.
        app(Generatore.chrome, "Accesso - Portale Fornitore", url: Generatore.portale)
        ann.cambiaFocus(ruolo: "AXTextField", subruolo: "AXSecureTextField", etichetta: "Password", ts: t)
        passa(5)
        ann.campoValore(ruolo: "AXTextField", subruolo: "AXSecureTextField", etichetta: "Password",
                        valore: "Segreta123!Veleno", durMs: 5000, ts: t)
        ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t)
        // Secure input acceso da un'altra app: niente comandi.
        secure.acceso = true
        ann.comando(tasti: "cmd+v", cc: cc, ts: t)
        secure.acceso = false
        passa(3)
        // URL con query e frammento: restano schema, host e path.
        ann.cambiaFinestra(titolo: "Ordini - Portale Fornitore",
                           url: "https://portale.fornitore-esempio.it/ordini?token=VELENOTOKEN#frammento", documento: nil, ts: t)
        passa(10)
        // Chiave API a schermo.
        ann.schermo(fonte: "ax", ms: 8, righe: ["Configurazione API", "sk-ant-api03-VELENOCHIAVE1234567890abcdef"], troncato: false, ts: t)
        ScenarioSchermo.aggiungi(ann: ann, ts: t)
        passa(10)
        // Finestra privata.
        ann.cambiaFinestra(titolo: "Navigazione privata — VelenoPrivato", url: nil, documento: nil, ts: t)
        ann.schermo(fonte: "ax", ms: 4, righe: ["Pagina VelenoPrivato aperta"], troncato: false, ts: t)
        passa(20)
        // Dominio di banca.
        ann.cambiaFinestra(titolo: "Conto VelenoBanca", url: "https://www.fineco.it/conto", documento: nil, ts: t)
        ann.schermo(fonte: "ax", ms: 4, righe: ["Saldo del Conto VelenoBanca"], troncato: false, ts: t)
        passa(30)
        veleniRevisione()
    }

    /// Veleni della revisione del 24/10/2026: ognuno passava dal filtro o dal redattore di prima.
    mutating func veleniRevisione() {
        // Campo aperto su una pagina esclusa, valore letto dopo il cambio di finestra.
        app(Generatore.chrome, "Fineco - Bonifico", url: "https://www.fineco.it/bonifico")
        ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Causale", ts: t)
        passa(4)
        ann.cambiaFinestra(titolo: "Ordini - Portale Fornitore", url: Generatore.portale, documento: nil, ts: t)
        ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Causale", valore: "Affitto BANCAVELENO", durMs: 4000, ts: t)
        ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t)
        passa(2)
        // Scheda di una pagina esclusa cliccata da una pagina permessa, voce di Cronologia.
        ann.clic(ruolo: "AXRadioButton", subruolo: "AXTabButton", etichetta: "Fineco - SCHEDAVELENO", web: false, ts: t)
        ann.menu(percorso: "Cronologia > Fineco MENUVELENO", ts: t)
        passa(2)
        // URL senza schema con query a schermo e nel valore di un campo; password in una frase.
        ann.schermo(fonte: "ax", ms: 6, righe: ["portale.esempio.it/reset?token=QUERYVELENO", "La tua nuova password è PWDVELENO99"],
                    troncato: false, ts: t)
        ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Link", ts: t)
        passa(3)
        ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Link",
                        valore: "https://portale.esempio.it/reset?token=QUERYVELENO#frammento", durMs: 3000, ts: t)
        // Campo Password non protetto (dopo "Mostra password").
        ann.cambiaFocus(ruolo: "AXTextField", subruolo: nil, etichetta: "Password", ts: t)
        passa(3)
        ann.campoValore(ruolo: "AXTextField", subruolo: nil, etichetta: "Password", valore: "Hunter2!PWDVELENO1", durMs: 3000, ts: t)
        ann.cambiaFocus(ruolo: nil, subruolo: nil, etichetta: nil, ts: t)
        passa(2)
        // Download da un dominio escluso.
        ann.file(tipo: "file_crea", info: InfoFile(path: Scenario.home + "/Downloads/Estratto FILEVELENO.pdf", inode: 990_001,
                                                   provenienza: "fineco.it"), ts: t)
        passa(2)
        // Firefox senza URL letto su una pagina della banca.
        app(AppRif(bundle: "org.mozilla.firefox", nome: "Firefox"), "Saldo BANCAURLVELENO")
        ann.schermo(fonte: "ax", ms: 4, righe: ["Movimenti BANCAURLVELENO"], troncato: false, ts: t)
        passa(10)
        // Safari: la finestra privata non si riconosce, quindi niente titolo né testo.
        app(Generatore.safari, "Referto PRIVATAVELENO", url: "https://salute.esempio.it/referto")
        ann.schermo(fonte: "ax", ms: 4, righe: ["Diagnosi PRIVATAVELENO"], troncato: false, ts: t)
        passa(10)
        // Un .env aperto in TextEdit.
        app(AppRif(bundle: "com.apple.TextEdit", nome: "TextEdit"), ".env ENVVELENO",
            documento: InfoFile(path: Scenario.home + "/progetto/.env"))
        ann.schermo(fonte: "ax", ms: 4, righe: ["DB_HOST=ENVVELENO.interno"], troncato: false, ts: t)
        passa(10)
    }
}
