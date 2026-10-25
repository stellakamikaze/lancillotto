// Filtri.swift: decide alla fonte cosa di un'osservazione può toccare il disco.
//
// Ordine delle domande (docs/PIANO.md, "Architettura"):
//   1. pausa?                                    -> scarta tutto
//   2. secure input o AXSecureTextField a fuoco? -> protetto (nient'altro)
//   3. app esclusa?                              -> escluso "app" (solo app e durata)
//   4. finestra privata, o dubbio?               -> escluso "privata"
//      (anche un browser che non ha un segno provato della finestra privata: Safari, Arc)
//   5. dominio escluso o path di login?          -> escluso "dominio"
//   6. browser con il titolo ma senza URL letto? -> escluso "dubbio" (nel dubbio no)
//   7. documento a fuoco in una cartella esclusa? -> escluso "cartella"
//   altrimenti                                   -> pieno
// Le esclusioni di default stanno qui, nel binario. impostazioni.json può solo aggiungere.
// Build VELENO: decidi() restituisce sempre .pieno e nessuna cartella è esclusa.

import Foundation

enum Esito: Equatable {
    case pieno
    case escluso(String)   // "app" | "dominio" | "privata" | "dubbio" | "cartella"
    case protetto
    case scarta
}

/// Quello che un sensore sa nel momento in cui osserva.
struct Osservazione {
    var ora: Int64
    var bundle: String?
    var nomeApp: String?
    var titolo: String?
    var url: String?
    var attributiFinestra: [String: String] = [:]
    var ruoloFocus: String?
    var subruoloFocus: String?
    var secureInput: Bool = false
    /// L'app è un browser (Esclusioni.browser): senza URL letto non si sa su che sito è.
    var browser: Bool = false
    /// Path del documento a fuoco (AXDocument), se noto.
    var documento: String? = nil
    /// La finestra a fuoco è già stata letta (dopo un cambio d'app arriva circa 150 ms dopo).
    /// Prima non si sa niente della finestra: niente titolo, niente testo, come per ogni app.
    var finestraNota: Bool = true
}

/// Le regole variabili, prese da impostazioni.json.
struct Regole: Equatable {
    var escludiApp: [String] = []
    var escludiDomini: [String] = []
    var pausaFino: Int64 = 0
}

enum Esclusioni {
    static let app: [String] = [
        "com.1password", "com.agilebits", "com.bitwarden", "com.dashlane",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.automattic.beeper.desktop", "com.beeper",
    ]
    static let paroleApp: [String] = ["bank", "banca", "trading", "fineco", "intesa", "unicredit"]
    static let domini: [String] = [
        "fineco.it", "intesasanpaolo.com", "unicredit.it", "bancobpm.it", "credem.it", "poste.it",
        "bper.it", "mps.it", "ing.it", "n26.com", "revolut.com", "paypal.com",
        // 25/10/2026: web.bbva.it passava (pagine della banca annotate, cancellate a mano). Banche,
        // carte, pagamenti e investimenti in Italia; i nomi con banca/bank li prende paroleHost.
        "bbva.it", "bbva.com", "mediolanum.it", "chebanca.it", "widiba.it", "hype.it", "isybank.com",
        "sella.it", "bnl.it", "credit-agricole.it", "illimity.com", "bancaifis.it", "popso.it",
        "bancagenerali.it", "ibl.it", "deutsche-bank.it", "db.com", "bcc.it",
        "satispay.com", "wise.com", "bunq.com", "tinaba.it", "nexi.it", "americanexpress.com",
        "scalapay.com", "klarna.com", "directa.it", "degiro.it", "degiro.com", "trading212.com",
        "scalable.capital", "etoro.com", "coinbase.com", "binance.com", "kraken.com", "moneyfarm.com",
        "postepay.it", "cartasi.it", "amex.it", "santanderconsumer.it", "findomestic.it", "agos.it",
        "compass.it", "cofidis.it", "younited-credit.com", "isybank.it",
        "agenziaentrate.gov.it", "inps.it", "fascicolosanitario.gov.it", "sistemapiemonte.it",
        "accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "id.atlassian.com",
    ]
    /// Parti dell'host che indicano una banca: relaxbanking.it, inbank.it, webank.it, bancobpm.it.
    static let paroleHost: [String] = ["bank", "banca", "banking"]
    static let pathLogin: [String] = ["/login", "/signin", "/sign-in", "/auth", "/oauth", "/sso", "/password"]
    static let cartelle: [String] = ["Library", ".git", "node_modules", ".Trash", ".ssh", ".gnupg"]
    static let paroleCartelle: [String] = ["secret", "credential", "password"]
    static let segniPrivata: [String] = [
        "navigazione privata", "navigazione anonima", "finestra privata", "private browsing",
        "private window", "incognito", "inprivate",
    ]
    static let segniAttributiPrivata: [String] = ["incognito", "inprivate", "private", "privat"]
    /// Browser: l'URL della scheda attiva decide il dominio. Senza URL letto, nel dubbio no.
    static let browser: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
        "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    /// Browser senza un segno provato della finestra privata (titolo e attributi AX uguali a quelli
    /// di una finestra normale). Finché la sonda della fase 0 non trova un segno affidabile, ogni
    /// loro finestra vale come privata: solo app e durata. Un sensore che prova il contrario
    /// mette attributi["privata"] = "0".
    static let browserPrivataNonRiconoscibile: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.Browser",
    ]
    /// Eccezioni a "Library" per i documenti aperti: allegati di Mail, iCloud Drive e cartelle cloud.
    /// Gli altri segni (.git, .env, secret, .ssh...) valgono anche lì.
    static let libraryAmmesse: [String] = [
        "/Library/Containers/com.apple.mail/", "/Mail Downloads/", "/Library/Mobile Documents/", "/Library/CloudStorage/",
    ]
    /// Parole dell'etichetta di un campo che porta un segreto anche se non è un AXSecureTextField.
    static let segniCampoSensibile: [String] = [
        "password", "passwd", "passcode", "pwd", "pin", "cvv", "cvv2", "cvc", "cid", "otp", "2fa", "mfa",
        "codice di sicurezza", "codice segreto", "codice di verifica", "codice otp", "codice dispositivo",
        "security code", "verification code", "one-time code", "parola d'ordine",
    ]
}

enum RegoleFiltro {
    /// Il cuore dei filtri: funzione pura, testata dal selftest.
    static func decidi(_ o: Osservazione, _ r: Regole) -> Esito {
        #if VELENO
        return .pieno
        #else
        if r.pausaFino > o.ora { return .scarta }
        if o.secureInput { return .protetto }
        if o.ruoloFocus == "AXSecureTextField" || o.subruoloFocus == "AXSecureTextField" { return .protetto }
        if appEsclusa(bundle: o.bundle, nome: o.nomeApp, extra: r.escludiApp) { return .escluso("app") }
        if finestraPrivata(titolo: o.titolo, attributi: o.attributiFinestra) { return .escluso("privata") }
        if o.finestraNota && privataInDubbio(bundle: o.bundle, attributi: o.attributiFinestra) { return .escluso("privata") }
        if let u = o.url, dominioEscluso(u, extra: r.escludiDomini) { return .escluso("dominio") }
        if o.browser && o.url == nil && !(o.titolo ?? "").isEmpty { return .escluso("dubbio") }
        if let d = o.documento, documentoEscluso(d) { return .escluso("cartella") }
        return .pieno
        #endif
    }

    /// Un browser che non distingue la finestra privata da quella normale: privata finché
    /// un sensore non scrive attributi["privata"] = "0".
    static func privataInDubbio(bundle: String?, attributi: [String: String]) -> Bool {
        guard let b = bundle, Esclusioni.browserPrivataNonRiconoscibile.contains(b) else { return false }
        return attributi["privata"] != "0"
    }

    /// Le voci aggiunte valgono come bundle (uguale o prefisso) e come nome dell'app (uguale,
    /// senza maiuscole): la persona scrive "Chrome" o "Slack", non com.google.Chrome.
    static func appEsclusa(bundle: String?, nome: String?, extra: [String]) -> Bool {
        let b = (bundle ?? "").lowercased()
        let n = (nome ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        for p in Esclusioni.app + extra {
            let pl = p.lowercased().trimmingCharacters(in: .whitespaces)
            if pl.isEmpty { continue }
            if b == pl || b.hasPrefix(pl + ".") || b.hasPrefix(pl) { return true }
        }
        for p in extra {
            let pl = p.lowercased().trimmingCharacters(in: .whitespaces)
            if !pl.isEmpty && !n.isEmpty && (n == pl || n.split(separator: " ").contains(Substring(pl))) { return true }
        }
        for parola in Esclusioni.paroleApp where b.contains(parola) || n.contains(parola) {
            return true
        }
        return false
    }

    /// Host per suffisso (esatto o sottodominio) e path con segni di login.
    static func dominioEscluso(_ url: String, extra: [String]) -> Bool {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let conSchema = t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil ? t : "https://" + t
        guard let c = URLComponents(string: conSchema) else {
            // Un URL che non si legge: nel dubbio si esclude.
            return true
        }
        let host = (c.host ?? "").lowercased()
        for d in Esclusioni.domini + extra {
            var dl = d.lowercased().trimmingCharacters(in: .whitespaces)
            if dl.hasPrefix(".") { dl.removeFirst() }
            if dl.isEmpty { continue }
            if host == dl || host.hasSuffix("." + dl) { return true }
        }
        for parola in Esclusioni.paroleHost where host.contains(parola) { return true }
        let path = c.percentEncodedPath.lowercased()
        for p in Esclusioni.pathLogin where path.contains(p) { return true }
        return false
    }

    /// Navigazione privata dai titoli o dagli attributi AX noti. Nel dubbio: privata.
    static func finestraPrivata(titolo: String?, attributi: [String: String]) -> Bool {
        if let t = titolo?.lowercased() {
            for s in Esclusioni.segniPrivata where t.contains(s) { return true }
        }
        for (chiave, valore) in attributi {
            let v = valore.lowercased()
            if chiave == "privata" && (v == "1" || v == "true" || v == "dubbio") { return true }
            for s in Esclusioni.segniAttributiPrivata where v.contains(s) { return true }
        }
        return false
    }

    /// Dominio di provenienza di un download (kMDItemWhereFroms) escluso, di default o aggiunto.
    static func provenienzaEsclusa(_ dominio: String?, extra: [String]) -> Bool {
        #if VELENO
        return false
        #else
        guard let d = dominio?.trimmingCharacters(in: .whitespaces), !d.isEmpty else { return false }
        return dominioEscluso("https://" + d + "/", extra: extra)
        #endif
    }

    /// Documento a fuoco (AXDocument) in una cartella esclusa. Come cartellaEsclusa, ma "Library"
    /// non vale per gli allegati di Mail, iCloud Drive e le cartelle cloud (Esclusioni.libraryAmmesse).
    static func documentoEscluso(_ path: String) -> Bool {
        #if VELENO
        return false
        #else
        let libraryAmmessa = Esclusioni.libraryAmmesse.contains { path.contains($0) }
        for comp in path.split(separator: "/") {
            let c = String(comp)
            if c == "Library" && libraryAmmessa { continue }
            if Esclusioni.cartelle.contains(c) { return true }
            if c == ".env" || c.hasPrefix(".env.") { return true }
            let cl = c.lowercased()
            for p in Esclusioni.paroleCartelle where cl.contains(p) { return true }
        }
        return false
        #endif
    }

    /// Etichetta (o segnaposto) di un campo che chiede un segreto: password, PIN, CVV, OTP.
    /// Il valore di quel campo non si legge e non si salva, anche se il campo non è protetto.
    static func campoSensibile(_ etichetta: String?) -> Bool {
        #if VELENO
        return false
        #else
        guard let e = etichetta?.lowercased(), !e.isEmpty else { return false }
        let parole = e.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        for s in Esclusioni.segniCampoSensibile {
            if s.contains(" ") || s.contains("'") || s.contains("-") {
                if e.contains(s) { return true }
            } else if parole.contains(s) || (s.count >= 6 && e.contains(s)) {
                return true
            }
        }
        return false
        #endif
    }

    /// Cartelle che FSEvents non deve mai annotare.
    static func cartellaEsclusa(_ path: String) -> Bool {
        #if VELENO
        return false
        #else
        for comp in path.split(separator: "/") {
            let c = String(comp)
            if Esclusioni.cartelle.contains(c) { return true }
            if c == ".env" || c.hasPrefix(".env.") { return true }
            let cl = c.lowercased()
            for p in Esclusioni.paroleCartelle where cl.contains(p) { return true }
        }
        return false
        #endif
    }

    /// Classe di cartella per `oggetto.cartella`.
    static func classificaCartella(_ path: String, home: String) -> String {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path.hasPrefix(h + "/Library/Containers/com.apple.mail/") || path.contains("/Mail Downloads/") {
            return "mail_allegati"
        }
        if path.hasPrefix(h + "/Downloads/") { return "download" }
        if path.hasPrefix(h + "/Documents/") { return "documenti" }
        if path.hasPrefix(h + "/Desktop/") { return "scrivania" }
        return "altro"
    }
}

/// Involucro thread-safe delle regole correnti, condiviso da tutti i sensori.
final class Filtri {
    private let lock = NSLock()
    private var regole = Regole()

    init(regole: Regole = Regole()) {
        self.regole = regole
    }

    func aggiorna(_ nuove: Regole) {
        lock.lock()
        regole = nuove
        lock.unlock()
    }

    func attuali() -> Regole {
        lock.lock()
        defer { lock.unlock() }
        return regole
    }

    /// Aggiunge subito un'app alle esclusioni, prima che arrivi la rilettura del file.
    func escludiSubito(bundle: String) {
        lock.lock()
        if !regole.escludiApp.contains(bundle) { regole.escludiApp.append(bundle) }
        lock.unlock()
    }

    func decidi(_ o: Osservazione) -> Esito {
        RegoleFiltro.decidi(o, attuali())
    }

    func inPausa(_ ora: Int64) -> Bool {
        #if VELENO
        return false
        #else
        return attuali().pausaFino > ora
        #endif
    }
}
