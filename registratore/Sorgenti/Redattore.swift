// Redattore.swift: funzioni pure che tolgono i segreti dal testo prima che tocchi il disco.
//
// Regole in docs/CONTRATTO.md, "Tempo e testo". Ogni segreto diventa [TIPO#abcd], dove abcd
// sono i primi 4 caratteri hex dell'HMAC del valore normalizzato. Ordine di passata:
// URL (via query e frammento), PEM, JWT, CHIAVE, PASSWORD, IBAN, CF, CARTA, OTP. L'IBAN passa
// prima della carta perché un IBAN scritto a gruppi contiene sequenze di cifre che sembrano carte.
//
// URL: ogni indirizzo nel testo (con schema, oppure host.tld/percorso come nella barra di Chrome)
// perde query e frammento, senza segnaposto. CHIAVE copre anche i prefissi sk_live_/rk_live_ e
// le assegnazioni NOME=valore con SECRET, TOKEN, API_KEY, _KEY nel nome. PASSWORD copre anche la
// password in una frase ("la tua nuova password è X", "password temporanea X") e PIN/CVV con cifre.
//
// Impronte (tabella `impronta`): h = HMAC del valore normalizzato, senza prefisso di tipo:
//   numero = sole cifre (da 6 in su), iban = maiuscolo senza spazi, email = minuscolo,
//   codice = maiuscolo (6+ caratteri alfanumerici, con almeno una cifra e una lettera).
// Si estraggono dal testo grezzo dopo aver tolto PEM, JWT, CHIAVE, PASSWORD e CARTA.
//
// Build VELENO (-D VELENO): redigi() e pulisciURL() lasciano passare tutto. Serve solo ai
// banchi per provare che il veleno attacca. Il binario normale non ha nessun interruttore.

import Foundation

enum TipoSegreto: String, CaseIterable {
    case pem = "PEM"
    case jwt = "JWT"
    case chiave = "CHIAVE"
    case password = "PASSWORD"
    case iban = "IBAN"
    case cf = "CF"
    case carta = "CARTA"
    case otp = "OTP"
}

struct Redazione: Equatable {
    let testo: String
    let n: Int
}

struct Impronta: Hashable {
    let h: String
    let tipo: String   // numero | iban | email | codice
}

struct URLPulito: Equatable {
    let completo: String    // schema + host (+ porta) + path redatto
    let dominio: String     // host senza "www."
    let etichetta: String   // dominio + primo segmento del path
}

private func rx(_ modello: String, _ opzioni: NSRegularExpression.Options = []) -> NSRegularExpression {
    // I modelli sono costanti di questo file: un errore qui è un bug da scoprire nel selftest.
    return try! NSRegularExpression(pattern: modello, options: opzioni)
}

private enum Modelli {
    static let pem = rx("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----|[\\s\\S]*)")
    static let jwt = rx("eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}")
    static let chiave = rx("(?<![A-Za-z0-9])(?:sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{16,}|[sr]k_(?:live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{16,}|gh[po]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{30,}|GOCSPX-[A-Za-z0-9_-]{10,})")
    /// NOME=valore (o "nome": "valore") con un nome da segreto: il valore (gruppo 3) diventa CHIAVE.
    static let assegnazione = rx("(?<![A-Za-z0-9_])([A-Za-z0-9_.-]*(?:secret|token|api[_-]?key|apikey|private[_-]?key|access[_-]?key|[_-]key)[A-Za-z0-9_.-]*)([\"']?\\s*[:=]\\s*[\"']?)(?!\\[)([^\\s\"',;]{6,})", [.caseInsensitive])
    static let password = rx("(?<![A-Za-z])(password|passwd|pwd|passcode)\\s*[:=]\\s*(\\S+)", [.caseInsensitive])
    /// Password in una frase: parola chiave, aggettivi, verbo, poi un valore con una cifra o un simbolo (gruppo 2).
    static let passwordFrase = rx("(?<![A-Za-z])(?:password|passwd|passcode|parola d'ordine)((?:\\s+(?:temporanea|provvisoria|nuova|iniziale|monouso|attuale|temporary|new|initial|one-time|current))*)(?:\\s+(?:è|é|e'|is|was|era|sarà))?\\s*:?\\s+(?!\\[)(?=\\S*[0-9!@#$%^&*_+=?~-])(\\S{4,})", [.caseInsensitive])
    /// PIN e CVV seguiti da cifre (gruppo 1).
    static let pin = rx("(?<![A-Za-z])(?:pin|cvv2?|cvc|cid)(?![A-Za-z])\\s*[:=]?\\s*([0-9]{3,6})(?![0-9])", [.caseInsensitive])
    /// Un URL con query o frammento: il gruppo 1 è ciò che resta (schema, host, porta, percorso).
    static let urlConQuery = rx("(?<![A-Za-z0-9@._%+-])((?:[a-z][a-z0-9+.-]*://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}(?::[0-9]{1,5})?(?:/[^\\s?#]*)?)[?#]\\S+", [.caseInsensitive])
    static let iban = rx("(?<![A-Za-z0-9])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,32}", [.caseInsensitive])
    static let cf = rx("(?<![A-Za-z0-9])[A-Z]{6}[0-9LMNPQRSTUV]{2}[ABCDEHLMPRST][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z](?![A-Za-z0-9])", [.caseInsensitive])
    static let carta = rx("(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])")
    static let otp = rx("(?<![0-9A-Za-z])[0-9]{6,8}(?![0-9A-Za-z])")
    static let paroleOTP = rx("codice|code|otp|verifica|verification", [.caseInsensitive])
    static let spazi = rx("\\s+")
    static let email = rx("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    static let numero = rx("(?<![A-Za-z0-9])[0-9][0-9.,']*[0-9](?![A-Za-z0-9])")
    static let codice = rx("(?<![A-Za-z0-9])[A-Za-z0-9][A-Za-z0-9-]{4,}[A-Za-z0-9](?![A-Za-z0-9])")
}

/// Lunghezze IBAN per paese (registro SWIFT): Italia, area SEPA e i paesi più comuni.
let lunghezzeIBAN: [String: Int] = [
    "AD": 24, "AE": 23, "AL": 28, "AT": 20, "AZ": 28, "BA": 20, "BE": 16, "BG": 22, "BH": 22,
    "BR": 29, "CH": 21, "CR": 22, "CY": 28, "CZ": 24, "DE": 22, "DK": 18, "DO": 28, "EE": 20,
    "EG": 29, "ES": 24, "FI": 18, "FO": 18, "FR": 27, "GB": 22, "GE": 22, "GI": 23, "GL": 18,
    "GR": 27, "GT": 28, "HR": 21, "HU": 28, "IE": 22, "IL": 23, "IS": 26, "IT": 27, "JO": 30,
    "KW": 30, "KZ": 20, "LB": 28, "LI": 21, "LT": 20, "LU": 20, "LV": 21, "MC": 27, "MD": 24,
    "ME": 22, "MK": 19, "MR": 27, "MT": 31, "MU": 30, "NL": 18, "NO": 15, "PK": 24, "PL": 28,
    "PS": 29, "PT": 25, "QA": 29, "RO": 24, "RS": 22, "SA": 24, "SE": 24, "SI": 19, "SK": 24,
    "SM": 27, "TN": 24, "TR": 26, "UA": 29, "VA": 22, "VG": 24, "XK": 20,
]

// MARK: - Controlli numerici

enum Controlli {
    static func luhn(_ cifre: String) -> Bool {
        let d = cifre.compactMap { $0.wholeNumberValue }
        guard d.count == cifre.count, d.count >= 2 else { return false }
        var somma = 0
        for (i, c) in d.reversed().enumerated() {
            var x = c
            if i % 2 == 1 {
                x *= 2
                if x > 9 { x -= 9 }
            }
            somma += x
        }
        return somma % 10 == 0
    }

    /// IBAN già normalizzato (maiuscolo, senza spazi): lunghezza del paese e mod-97 == 1.
    static func ibanValido(_ iban: String) -> Bool {
        let s = Array(iban.utf8)
        guard s.count >= 15, s.count <= 34 else { return false }
        let paese = String(decoding: s[0..<2], as: UTF8.self)
        guard let attesa = lunghezzeIBAN[paese], attesa == s.count else { return false }
        let riordinato = Array(s[4...]) + Array(s[0..<4])
        var resto = 0
        for b in riordinato {
            if b >= 48 && b <= 57 {
                resto = (resto * 10 + Int(b - 48)) % 97
            } else if b >= 65 && b <= 90 {
                let v = Int(b - 65) + 10
                resto = (resto * 100 + v) % 97
            } else {
                return false
            }
        }
        return resto == 1
    }

    private static let valoriDispari: [Int] = [1, 0, 5, 7, 9, 13, 15, 17, 19, 21, 2, 4, 18, 20, 11, 3, 6, 8, 12, 14, 16, 10, 22, 25, 24, 23]

    /// Codice fiscale di 16 caratteri, maiuscolo: carattere di controllo valido.
    static func cfValido(_ cf: String) -> Bool {
        let s = Array(cf.utf8)
        guard s.count == 16 else { return false }
        var somma = 0
        for i in 0..<15 {
            let b = s[i]
            let indice: Int
            if b >= 48 && b <= 57 {
                indice = Int(b - 48)
            } else if b >= 65 && b <= 90 {
                indice = Int(b - 65)
            } else {
                return false
            }
            // Posizioni dispari (1ª, 3ª, ...) = indice pari da zero.
            somma += (i % 2 == 0) ? valoriDispari[indice] : indice
        }
        return Int(s[15]) == 65 + somma % 26
    }
}

// MARK: - Redattore

struct Redattore {
    let firma: (String) -> String

    init(hmac: Hmac) {
        self.firma = { hmac.hex($0) }
    }

    init(firma: @escaping (String) -> String) {
        self.firma = firma
    }

    func segnaposto(_ tipo: TipoSegreto, _ valore: String) -> String {
        "[\(tipo.rawValue)#\(firma(valore).prefix(4))]"
    }

    /// Toglie dal testo query e frammenti degli URL e tutti i tipi di segreto del contratto.
    func redigi(_ testo: String) -> Redazione {
        #if VELENO
        return Redazione(testo: testo, n: 0)
        #else
        let (senzaQuery, q) = Redattore.togliQuery(testo)
        let r = redigi(senzaQuery, tipi: TipoSegreto.allCases)
        return Redazione(testo: r.testo, n: r.n + q)
        #endif
    }

    /// Ogni URL del testo perde query e frammento ("portale.it/reset?token=x#y" -> "portale.it/reset").
    static func togliQuery(_ testo: String) -> (String, Int) {
        if !testo.contains("?") && !testo.contains("#") { return (testo, 0) }
        return sostituisci(testo, Modelli.urlConQuery) { m, ns in
            let resta = ns.substring(with: m.range(at: 1))
            return (m.range, resta)
        }
    }

    /// Solo i tipi indicati, nell'ordine fisso del contratto. Uso interno e test.
    func redigi(_ testo: String, tipi: [TipoSegreto]) -> Redazione {
        if testo.isEmpty { return Redazione(testo: testo, n: 0) }
        var s = testo
        var totale = 0
        for tipo in TipoSegreto.allCases where tipi.contains(tipo) {
            let (nuovo, n) = passata(tipo, s)
            s = nuovo
            totale += n
        }
        return Redazione(testo: s, n: totale)
    }

    private func passata(_ tipo: TipoSegreto, _ s: String) -> (String, Int) {
        switch tipo {
        case .pem:
            return sostituisci(s, Modelli.pem) { m, ns in
                (m.range, segnaposto(.pem, ns.substring(with: m.range)))
            }
        case .jwt:
            return sostituisci(s, Modelli.jwt) { m, ns in
                (m.range, segnaposto(.jwt, ns.substring(with: m.range)))
            }
        case .chiave:
            let (a, n1) = sostituisci(s, Modelli.chiave) { m, ns in
                (m.range, segnaposto(.chiave, ns.substring(with: m.range)))
            }
            let (b, n2) = sostituisci(a, Modelli.assegnazione) { m, ns in
                let r = m.range(at: 3)
                return (r, segnaposto(.chiave, ns.substring(with: r)))
            }
            return (b, n1 + n2)
        case .password:
            let (a, n1) = sostituisci(s, Modelli.password) { m, ns in
                let r = m.range(at: 2)
                return (r, segnaposto(.password, ns.substring(with: r)))
            }
            let (b, n2) = sostituisci(a, Modelli.passwordFrase) { m, ns in
                let r = m.range(at: 2)
                return (r, segnaposto(.password, ns.substring(with: r)))
            }
            let (c, n3) = sostituisci(b, Modelli.pin) { m, ns in
                let r = m.range(at: 1)
                return (r, segnaposto(.password, ns.substring(with: r)))
            }
            return (c, n1 + n2 + n3)
        case .iban:
            return sostituisci(s, Modelli.iban) { m, ns in
                guard let (r, valore) = ibanNelMatch(m, ns) else { return nil }
                return (r, segnaposto(.iban, valore))
            }
        case .cf:
            return sostituisci(s, Modelli.cf) { m, ns in
                let v = ns.substring(with: m.range).uppercased()
                guard Controlli.cfValido(v) else { return nil }
                return (m.range, segnaposto(.cf, v))
            }
        case .carta:
            return sostituisci(s, Modelli.carta) { m, ns in
                let cifre = ns.substring(with: m.range).filter { $0.isASCII && $0.isNumber }
                guard cifre.count >= 13, cifre.count <= 19, Controlli.luhn(cifre) else { return nil }
                return (m.range, segnaposto(.carta, cifre))
            }
        case .otp:
            return sostituisci(s, Modelli.otp) { m, ns in
                guard èOTP(m.range, ns) else { return nil }
                return (m.range, segnaposto(.otp, ns.substring(with: m.range)))
            }
        }
    }

    /// Da un match grezzo di IBAN prende i primi N caratteri alfanumerici (N dato dal paese)
    /// e li valida. Restituisce il range da sostituire e il valore normalizzato.
    private func ibanNelMatch(_ m: NSTextCheckingResult, _ ns: NSString) -> (NSRange, String)? {
        let grezzo = ns.substring(with: m.range)
        let maiuscolo = grezzo.uppercased()
        let paese = String(maiuscolo.prefix(2))
        guard let attesa = lunghezzeIBAN[paese] else { return nil }
        var raccolti = ""
        var unitaUsate = 0
        for u in grezzo.utf16 {
            if raccolti.count == attesa { break }
            unitaUsate += 1
            if u != 32 { raccolti.append(Character(UnicodeScalar(u) ?? " ")) }
        }
        guard raccolti.count == attesa else { return nil }
        // Un IBAN valido seguito subito da un altro carattere alfanumerico fa parte di un codice più lungo.
        let fine = m.range.location + unitaUsate
        if fine < ns.length, let c = UnicodeScalar(ns.character(at: fine)),
           CharacterSet.alphanumerics.contains(c) {
            return nil
        }
        let valore = raccolti.uppercased()
        guard Controlli.ibanValido(valore) else { return nil }
        return (NSRange(location: m.range.location, length: unitaUsate), valore)
    }

    /// 6-8 cifre: OTP se stanno da sole sulla riga o se una parola chiave è a 40 caratteri.
    private func èOTP(_ r: NSRange, _ ns: NSString) -> Bool {
        // Parte di un numero con separatori (1.234567 o 123456,78): non è un codice.
        if r.location >= 2 {
            let prima = ns.character(at: r.location - 1)
            let primaAncora = ns.character(at: r.location - 2)
            if (prima == 46 || prima == 44) && primaAncora >= 48 && primaAncora <= 57 { return false }
        }
        let fine = r.location + r.length
        if fine + 1 < ns.length {
            let dopo = ns.character(at: fine)
            let dopoAncora = ns.character(at: fine + 1)
            if (dopo == 46 || dopo == 44) && dopoAncora >= 48 && dopoAncora <= 57 { return false }
        }
        let riga = ns.lineRange(for: r)
        let testoRiga = ns.substring(with: riga).trimmingCharacters(in: .whitespacesAndNewlines)
        if testoRiga == ns.substring(with: r) { return true }
        let inizio = max(riga.location, r.location - 40)
        let termine = min(riga.location + riga.length, fine + 40)
        let intorno = NSRange(location: inizio, length: termine - inizio)
        return Modelli.paroleOTP.firstMatch(in: ns as String, range: intorno) != nil
    }

    // MARK: Normalizzazione, titoli, URL

    /// Riga di schermo: trim, spazi multipli ridotti a uno; nil sotto i 2 caratteri.
    static func normalizzaRiga(_ riga: String) -> String? {
        let ns = riga as NSString
        let compatta = Modelli.spazi.stringByReplacingMatches(
            in: riga, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        let t = compatta.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count < 2 ? nil : t
    }

    /// Titolo di finestra: redatto, spazi compattati, troncato a 200 caratteri.
    func pulisciTitolo(_ titolo: String) -> String {
        let r = redigi(titolo).testo
        let compatto = Redattore.normalizzaRiga(r) ?? r.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compatto.prefix(200))
    }

    /// URL: solo schema, host (con porta) e path redatto. Via query, frammento e credenziali.
    /// Un valore della barra indirizzi senza schema riceve https://. Testo che non è un URL: nil.
    func pulisciURL(_ grezzo: String) -> URLPulito? {
        let t = grezzo.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.contains(" ") { return nil }
        #if VELENO
        if let c = URLComponents(string: t.contains("://") ? t : "https://" + t), let h = c.host {
            return URLPulito(completo: t, dominio: h, etichetta: t)
        }
        return URLPulito(completo: t, dominio: t, etichetta: t)
        #else
        var testo = t
        let haSchema = testo.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        if !haSchema {
            // "portale.esempio.it/ordini": serve almeno un punto nel nome host.
            let host = testo.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard host.contains(".") else { return nil }
            testo = "https://" + testo
        }
        guard let c = URLComponents(string: testo), let schema = c.scheme?.lowercased() else { return nil }
        let host = (c.host ?? "").lowercased()
        var dominio = host
        if dominio.hasPrefix("www.") { dominio = String(dominio.dropFirst(4)) }
        let segmenti = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { seg -> String in
            let s = String(seg)
            return Redattore.segmentoOpaco(s) ? "[ID]" : redigi(s.removingPercentEncoding ?? s).testo
        }
        let path = (c.percentEncodedPath.hasPrefix("/") ? "/" : "") + segmenti.joined(separator: "/")
        var completo = schema + ":"
        if !host.isEmpty {
            completo += "//" + host
            if let p = c.port { completo += ":\(p)" }
        }
        completo += path
        if host.isEmpty {
            // about:blank, chrome://newtab e simili: niente host, si tiene solo lo schema.
            dominio = schema
        }
        let etichetta = segmenti.first.map { dominio + "/" + $0 } ?? dominio
        return URLPulito(completo: completo, dominio: dominio, etichetta: etichetta)
        #endif
    }

    /// Segmento di path che sembra un identificativo opaco (token, hash): 20+ caratteri con lettere e cifre.
    static func segmentoOpaco(_ s: String) -> Bool {
        guard s.count >= 20 else { return false }
        let haCifre = s.contains { $0.isASCII && $0.isNumber }
        let haLettere = s.contains { $0.isASCII && $0.isLetter }
        return haCifre && haLettere
    }

    // MARK: Impronte

    /// Impronte HMAC delle entità del testo grezzo: numeri, IBAN, email, codici. Mai il testo.
    func impronte(_ testo: String, massimo: Int = 50) -> [Impronta] {
        if testo.isEmpty { return [] }
        let s = redigi(testo, tipi: [.pem, .jwt, .chiave, .password, .carta]).testo
        let ns = s as NSString
        let tutto = NSRange(location: 0, length: ns.length)
        var visti = Set<String>()
        var out = [Impronta]()
        func aggiungi(_ valore: String, _ tipo: String) {
            let chiave = tipo + "\u{0}" + valore
            guard out.count < massimo, !visti.contains(chiave) else { return }
            visti.insert(chiave)
            out.append(Impronta(h: firma(valore), tipo: tipo))
        }
        var iban = Set<String>()
        for m in Modelli.iban.matches(in: s, range: tutto) {
            if let (_, v) = ibanNelMatch(m, ns) {
                iban.insert(v)
                aggiungi(v, "iban")
            }
        }
        for m in Modelli.email.matches(in: s, range: tutto) {
            aggiungi(ns.substring(with: m.range).lowercased(), "email")
        }
        for m in Modelli.numero.matches(in: s, range: tutto) {
            let cifre = ns.substring(with: m.range).filter { $0.isASCII && $0.isNumber }
            if cifre.count >= 6 { aggiungi(cifre, "numero") }
        }
        for m in Modelli.codice.matches(in: s, range: tutto) {
            let v = ns.substring(with: m.range).uppercased()
            let alfanumerici = v.filter { $0 != "-" }
            guard alfanumerici.count >= 6,
                  v.contains(where: { $0.isNumber }), v.contains(where: { $0.isLetter }),
                  !iban.contains(alfanumerici) else { continue }
            aggiungi(v, "codice")
        }
        return out
    }
}

// MARK: - Sostituzione

/// Applica `trasforma` a ogni match di `re`. `trasforma` restituisce il range da sostituire
/// (dentro il match) e il testo nuovo, oppure nil per lasciare il match com'è.
private func sostituisci(_ s: String, _ re: NSRegularExpression,
                         _ trasforma: (NSTextCheckingResult, NSString) -> (NSRange, String)?) -> (String, Int) {
    let ns = s as NSString
    let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
    if matches.isEmpty { return (s, 0) }
    var out = ""
    var pos = 0
    var n = 0
    for m in matches {
        guard let (r, nuovo) = trasforma(m, ns), r.location >= pos else { continue }
        out += ns.substring(with: NSRange(location: pos, length: r.location - pos))
        out += nuovo
        pos = r.location + r.length
        n += 1
    }
    out += ns.substring(from: pos)
    return (out, n)
}
