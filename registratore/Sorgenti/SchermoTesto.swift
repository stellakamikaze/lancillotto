// SchermoTesto.swift: la parte pura del sensore del testo a schermo (SensoreSchermo.swift).
//
// Qui non c'è AX, né ScreenCaptureKit, né Vision: solo funzioni e strutture che il selftest
// prova con alberi finti, orologi finti e numeri fissi. Le usano il sensore vero e lo
// scenario sintetico, così lo scenario passa dalla stessa visita e dalla stessa deduplica.
//
//   albero AX ──VisitaAX.visita (budget: nodi, tempo, caratteri; salta AXSecureTextField;
//               nei browser solo dentro la AXWebArea: mai schede, barra indirizzi, preferiti)──> testi
//   testi AX od OCR ──TestoSchermo.righe (spezza, normalizza, scarta le righe senza lettere
//                      né cifre, deduplica, tetto di righe)──> righe
//   righe ──ElaboraSchermo.nuove (confronto con l'istantanea precedente della stessa finestra)
//          ├─ uguali  -> niente evento
//          └─ diverse -> Annotatore.schermo -> Registro.righe (redazione, riga.h, volte, delta, impronte)
//
// Quando leggere lo decide Pianificatore: 2 s dopo l'ultimo cambio di finestra o titolo,
// poi al massimo ogni 20 s sulla stessa finestra, e solo se nel frattempo c'è stato input.
// L'intervallo si raddoppia quando il peso del giorno supera 40 MB (fattoreRiduzione).

import CoreGraphics
import Foundation

// MARK: - Budget della visita

/// Tetto di nodi, di tempo e di caratteri per una visita dell'albero AX.
struct Budget {
    let nodiMassimi: Int
    let caratteriMassimi: Int
    let scadenza: UInt64
    let ora: () -> UInt64
    private(set) var nodi = 0
    var caratteri = 0
    private(set) var esaurito = false

    static let nodiDefault = 3000
    static let msDefault = 50
    static let caratteriDefault = 200_000

    init(nodi: Int = Budget.nodiDefault, ms: Int = Budget.msDefault, caratteri: Int = Budget.caratteriDefault,
         ora: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.nodiMassimi = nodi
        self.caratteriMassimi = caratteri
        self.ora = ora
        self.scadenza = ora() + UInt64(max(0, ms)) * 1_000_000
    }

    /// true se si può visitare un altro nodo. Il primo tetto raggiunto chiude la visita.
    mutating func entra() -> Bool {
        if esaurito { return false }
        if nodi >= nodiMassimi || caratteri >= caratteriMassimi || ora() >= scadenza {
            esaurito = true
            return false
        }
        nodi += 1
        return true
    }

    var caratteriRestanti: Int { max(0, caratteriMassimi - caratteri) }
}

// MARK: - Visita dell'albero

struct RisultatoVisita: Equatable {
    var testi: [String] = []
    var nodi = 0
    var protetti = 0
    var troncato = false
}

enum VisitaAX {
    /// Ruoli il cui testo si legge (AXValue, poi AXTitle, poi AXDescription).
    static let ruoliTesto: Set<String> = [
        "AXStaticText", "AXTextArea", "AXHeading", "AXCell", "AXLink", "AXButton",
        "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton",
    ]
    /// Campi modificabili: il valore si legge solo se impostazioni.valori_campi è vero.
    static let ruoliCampo: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]
    /// Ruoli in cui non si scende: il testo è già nel nodo, o i figli sono rumore (menu chiusi).
    static let fogli: Set<String> = [
        "AXStaticText", "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXSecureTextField",
        "AXImage", "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXMenuBar", "AXMenu",
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton",
    ]
    static let profonditaMassima = 64
    static let pilaMassima = 20_000
    /// Fuori dalla pagina di un browser non si scende in questi ruoli: schede e barre portano
    /// titoli e indirizzi di altre pagine, anche escluse o private.
    static let corniceBrowser: Set<String> = ["AXTabGroup", "AXToolbar", "AXTabButton"]

    /// Un campo protetto non si legge e non si visita. Build VELENO: nessun campo è protetto.
    static func protetto(ruolo: String?, subruolo: String?) -> Bool {
        #if VELENO
        return false
        #else
        return ruolo == "AXSecureTextField" || subruolo == "AXSecureTextField"
        #endif
    }

    /// Visita in profondità (ordine di lettura: prima il nodo, poi i figli da sinistra).
    /// `struttura` legge solo ruolo e subruolo; `testo` si chiama solo dopo aver escluso
    /// i campi protetti, quindi il valore di un AXSecureTextField non si chiede mai.
    ///
    /// soloWebArea (browser): il testo si legge solo dentro una AXWebArea. Fuori si scende soltanto
    /// per trovarla, senza leggere niente e senza entrare in schede e barre (corniceBrowser).
    /// webArea: chiamata una volta, sulla prima AXWebArea trovata (serve a ritagliare l'OCR).
    static func visita<N>(radice: N, budget: inout Budget, valoriCampi: Bool, soloWebArea: Bool = false,
                          struttura: (N) -> (ruolo: String?, subruolo: String?)?,
                          figli: (N, String) -> [N],
                          testo: (N, String) -> String?,
                          webArea: ((N) -> Void)? = nil) -> RisultatoVisita {
        var r = RisultatoVisita()
        var pila: [(N, Int, Bool)] = [(radice, 0, !soloWebArea)]
        var webAreaTrovata = false
        while let voce = pila.popLast() {
            let (nodo, profondita, dentro) = voce
            guard budget.entra() else {
                r.troncato = true
                break
            }
            guard let s = struttura(nodo) else { continue }
            if protetto(ruolo: s.ruolo, subruolo: s.subruolo) {
                r.protetti += 1
                continue
            }
            let ruolo = s.ruolo ?? ""
            var dentroNodo = dentro
            if ruolo == "AXWebArea" {
                dentroNodo = true
                if !webAreaTrovata {
                    webAreaTrovata = true
                    webArea?(nodo)
                }
            }
            if !dentroNodo {
                #if !VELENO
                if corniceBrowser.contains(ruolo) || corniceBrowser.contains(s.subruolo ?? "") { continue }
                if profondita >= profonditaMassima { continue }
                let f = figli(nodo, ruolo)
                if pila.count + f.count > pilaMassima {
                    r.troncato = true
                    continue
                }
                for c in f.reversed() { pila.append((c, profondita + 1, false)) }
                continue
                #endif
            }
            let leggibile = ruoliTesto.contains(ruolo) || (valoriCampi && ruoliCampo.contains(ruolo))
            if leggibile, let t = testo(nodo, ruolo), !t.isEmpty {
                let pezzo = t.count > budget.caratteriRestanti ? String(t.prefix(budget.caratteriRestanti)) : t
                if pezzo.count < t.count { r.troncato = true }
                budget.caratteri += pezzo.count
                if !pezzo.isEmpty { r.testi.append(pezzo) }
            }
            if fogli.contains(ruolo) || profondita >= profonditaMassima { continue }
            let f = figli(nodo, ruolo)
            if pila.count + f.count > pilaMassima {
                r.troncato = true
                continue
            }
            for c in f.reversed() { pila.append((c, profondita + 1, dentroNodo)) }
        }
        r.nodi = budget.nodi
        if budget.esaurito { r.troncato = true }
        return r
    }
}

// MARK: - Righe

struct RigheSchermo: Equatable {
    var righe: [String] = []
    var troncato = false
}

/// Voce dell'OCR: coordinate normalizzate di Vision (origine in basso a sinistra).
struct VoceOCR: Equatable {
    let testo: String
    let x: Double
    let y: Double
    let altezza: Double
}

/// Finestra dall'elenco di CGWindowListCopyWindowInfo.
struct VoceFinestra: Equatable {
    let id: UInt32
    let pid: Int32
    let livello: Int
    let cornice: CGRect
}

enum TestoSchermo {
    static let massimoRighe = 2000
    static let massimoRiga = 2000
    /// Sotto questo numero di righe utili da AX si prova l'OCR.
    static let righeMinimeAX = 3

    /// Spezza sulle andate a capo, normalizza (Redattore.normalizzaRiga: spazi ridotti, trim,
    /// righe sotto i 2 caratteri scartate), tiene solo le righe con almeno una lettera o cifra,
    /// deduplica tenendo l'ordine della prima comparsa. Oltre massimoRighe: troncato.
    static func righe(_ testi: [String]) -> RigheSchermo {
        var out = RigheSchermo()
        var viste = Set<String>()
        esterno: for t in testi {
            for pezzo in t.split(whereSeparator: { $0.isNewline }) {
                guard let n = Redattore.normalizzaRiga(String(pezzo.prefix(massimoRiga))), utile(n) else { continue }
                if viste.contains(n) { continue }
                if out.righe.count >= massimoRighe {
                    out.troncato = true
                    break esterno
                }
                viste.insert(n)
                out.righe.append(n)
            }
        }
        return out
    }

    /// Una riga è utile se contiene almeno una lettera o una cifra (non "---" o "•").
    static func utile(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }

    /// Ordine di lettura dell'OCR: dall'alto in basso per bande, e da sinistra dentro la banda.
    static func ordinaOCR(_ voci: [VoceOCR]) -> [String] {
        let perAltezza = voci.sorted { ($0.y + $0.altezza / 2) > ($1.y + $1.altezza / 2) }
        var bande: [[VoceOCR]] = []
        for v in perAltezza {
            let centro = v.y + v.altezza / 2
            if let prima = bande.last?.first {
                let centroBanda = prima.y + prima.altezza / 2
                if abs(centroBanda - centro) < 0.5 * min(prima.altezza, v.altezza) {
                    bande[bande.count - 1].append(v)
                    continue
                }
            }
            bande.append([v])
        }
        return bande.flatMap { b in b.sorted { $0.x < $1.x }.map { $0.testo } }
    }

    /// La finestra da catturare: dello stesso processo, al livello normale (0), con la stessa
    /// cornice della finestra AX a fuoco (tolleranza 4 punti). Se nessuna coincide: nil, perché
    /// un'altra finestra della stessa app (per esempio una privata) non si cattura mai.
    static func scegliFinestra(_ voci: [VoceFinestra], pid: Int32, cornice: CGRect) -> UInt32? {
        func vicino(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 4 }
        for v in voci where v.pid == pid && v.livello == 0 {
            if vicino(v.cornice.minX, cornice.minX) && vicino(v.cornice.minY, cornice.minY)
                && vicino(v.cornice.width, cornice.width) && vicino(v.cornice.height, cornice.height) {
                return v.id
            }
        }
        return nil
    }

    /// La cornice della pagina (AXWebArea) dentro l'immagine della finestra, in coordinate
    /// normalizzate di Vision (origine in basso a sinistra). Le cornici AX hanno l'origine in alto.
    /// nil se la pagina non sta dentro la finestra.
    static func ritaglioNormalizzato(finestra: CGRect, area: CGRect) -> CGRect? {
        guard finestra.width > 0, finestra.height > 0 else { return nil }
        let a = area.intersection(finestra)
        guard !a.isNull, a.width > 0, a.height > 0 else { return nil }
        let x = (a.minX - finestra.minX) / finestra.width
        let w = a.width / finestra.width
        let h = a.height / finestra.height
        let y = 1 - (a.maxY - finestra.minY) / finestra.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Le voci dell'OCR con il centro dentro il ritaglio (nil: tutte).
    static func dentroRitaglio(_ voci: [VoceOCR], _ ritaglio: CGRect?) -> [VoceOCR] {
        guard let r = ritaglio else { return voci }
        return voci.filter { v in r.contains(CGPoint(x: v.x + 0.000_1, y: v.y + v.altezza / 2)) }
    }

    /// Soglia del peso del giorno oltre la quale l'intervallo raddoppia.
    static let sogliaPeso: Int64 = 40_000_000

    /// 1 fino a 40 MB, 2 oltre 40, 4 oltre 80, 8 oltre 120 (tetto).
    static func fattoreRiduzione(pesoByte: Int64) -> Int64 {
        if pesoByte <= sogliaPeso { return 1 }
        if pesoByte <= 2 * sogliaPeso { return 2 }
        if pesoByte <= 3 * sogliaPeso { return 4 }
        return 8
    }
}

// MARK: - Delta fra istantanee

struct DeltaSchermo: Equatable {
    var aggiunte: Int
    var tolte: Int
    var invariato: Bool { aggiunte == 0 && tolte == 0 }

    /// prima nil: la finestra non era mai stata letta, tutto è aggiunto.
    static func calcola(prima: Set<Int>?, dopo: Set<Int>) -> DeltaSchermo {
        guard let p = prima else { return DeltaSchermo(aggiunte: dopo.count, tolte: 0) }
        return DeltaSchermo(aggiunte: dopo.subtracting(p).count, tolte: p.subtracting(dopo).count)
    }
}

/// Ricorda l'ultima istantanea di ogni finestra (solo hash in memoria, mai il testo) e dice
/// se quella nuova cambia qualcosa. Non thread-safe: si usa da una sola coda.
final class ElaboraSchermo {
    static let massimoFinestre = 100
    private var precedenti: [String: Set<Int>] = [:]
    private var ordine: [String] = []

    /// nil se le righe sono le stesse dell'istantanea precedente della stessa finestra
    /// (o se non ci sono righe): allora non si scrive nessun evento.
    func nuove(chiave: String, righe: [String]) -> DeltaSchermo? {
        let dopo = Set(righe.map { $0.hashValue })
        let d = DeltaSchermo.calcola(prima: precedenti[chiave], dopo: dopo)
        if precedenti[chiave] == nil {
            ordine.append(chiave)
            if ordine.count > ElaboraSchermo.massimoFinestre {
                precedenti.removeValue(forKey: ordine.removeFirst())
            }
        }
        precedenti[chiave] = dopo
        return d.invariato ? nil : d
    }

    func dimentica() {
        precedenti.removeAll()
        ordine.removeAll()
    }
}

// MARK: - Quando leggere

/// Stato del calendario delle letture. Tempi in ms; nessun orologio dentro, così è testabile.
struct Pianificatore {
    /// Attesa dopo un cambio di finestra, titolo o documento (debounce).
    static let attesa: Int64 = 2_000
    /// Intervallo base fra due letture della stessa finestra, e fra due OCR.
    static let intervalloBase: Int64 = 20_000

    var fattore: Int64 = 1
    private(set) var chiave: String?
    private(set) var cambioTs: Int64 = 0
    private(set) var attesaDa: Int64 = 0
    private(set) var letta = true
    private(set) var ultimaLettura: Int64 = Int64.min / 4
    private(set) var ultimoOCR: Int64 = Int64.min / 4
    /// AX ha dato poche righe e l'OCR era in attesa del suo turno.
    var ocrPendente = false

    var intervallo: Int64 { Pianificatore.intervalloBase * fattore }

    /// La finestra osservata ora (nil: niente da leggere, per filtri o permessi).
    mutating func osserva(_ nuova: String?, ts: Int64) {
        guard nuova != chiave else { return }
        if letta || chiave == nil { attesaDa = ts }
        chiave = nuova
        cambioTs = ts
        letta = false
        ocrPendente = false
    }

    /// true se è il momento di leggere. attivita: c'è stato input nell'ultimo intervallo.
    func daLeggere(ts: Int64, attivita: Bool) -> Bool {
        guard chiave != nil else { return false }
        if !letta {
            // Un titolo che cambia di continuo (un orologio, una percentuale) si legge
            // comunque, una volta per intervallo.
            return ts - cambioTs >= Pianificatore.attesa || ts - attesaDa >= intervallo
        }
        if ocrPendente && ocrAmmesso(ts: ts) { return true }
        return attivita && ts - ultimaLettura >= intervallo
    }

    mutating func letto(ts: Int64) {
        letta = true
        ultimaLettura = ts
        ocrPendente = false
    }

    /// La lettura è stata scartata (la finestra cambiava mentre si leggeva): si riprova dopo l'attesa.
    mutating func rinvia(ts: Int64) {
        letta = false
        cambioTs = ts
        attesaDa = ts
    }

    /// Al massimo un OCR per intervallo, su tutte le finestre.
    func ocrAmmesso(ts: Int64) -> Bool {
        ts - ultimoOCR >= intervallo
    }

    mutating func ocrAvviato(ts: Int64) {
        ultimoOCR = ts
    }
}

// MARK: - Livello dell'OCR

/// accurate finché la media mobile del suo costo resta sotto la soglia; sopra si passa a fast,
/// e una volta ogni 20 OCR si riprova accurate per aggiornare la misura.
/// Soglia 400 ms (25/10/2026): su una finestra Retina piena accurate costa 1,1-2,8 s, fast 0,2 s
/// con lo stesso testo italiano. Con un OCR ogni 20 s al massimo, fast resta sotto il 2% di CPU.
struct LivelloOCR {
    static let sogliaMs: Double = 400
    static let riprova = 20
    private(set) var media: Double?
    private(set) var contatore = 0

    mutating func scegliAccurate() -> Bool {
        contatore += 1
        guard let m = media, m > LivelloOCR.sogliaMs else { return true }
        return contatore % LivelloOCR.riprova == 0
    }

    mutating func misura(ms: Int, accurate: Bool) {
        guard accurate else { return }
        media = media.map { $0 * 0.7 + Double(ms) * 0.3 } ?? Double(ms)
    }
}

// MARK: - Costi

struct MediaCosti: Equatable {
    var sommaAX = 0
    var nAX = 0
    var sommaOCR = 0
    var nOCR = 0

    mutating func aggiungi(fonte: String, ms: Int) {
        if fonte == "ocr" {
            sommaOCR += ms
            nOCR += 1
        } else {
            sommaAX += ms
            nAX += 1
        }
    }

    var mediaAX: Int { nAX == 0 ? 0 : sommaAX / nAX }
    var mediaOCR: Int { nOCR == 0 ? 0 : sommaOCR / nOCR }

    /// Riga per la tabella salute, senza testo osservato.
    func descrizione(intervallo: Int64, pesoByte: Int64?, livelloFast: Bool) -> String {
        var s = "costo medio ax \(mediaAX) ms su \(nAX) letture, ocr \(mediaOCR) ms su \(nOCR)"
        if nOCR > 0 { s += livelloFast ? " (fast)" : " (accurate)" }
        s += ", intervallo \(intervallo / 1000) s"
        if let p = pesoByte { s += ", peso del giorno \(p / 1_000_000) MB" }
        return s
    }
}
