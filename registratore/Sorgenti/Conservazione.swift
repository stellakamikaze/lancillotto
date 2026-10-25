// Conservazione.swift: pulizia del registro, all'avvio e una volta al giorno.
// Le cancellazioni girano sulla coda del Registro (asincrone): il main thread non le aspetta.
// A lavoro finito l'Annotatore riceve l'avviso sul main.
//
//   1. DELETE degli eventi più vecchi di conservazione_giorni (e di schermi, salute, righe);
//   2. pulizia di righe, oggetti e impronte orfani; PRAGMA incremental_vacuum;
//   3. evento servizio "conservazione";
//   4. dimentica_richieste di impostazioni.json: cancella ogni intervallo e toglie dal file
//      solo le richieste eseguite (scrittura atomica), così una richiesta nuova della CLI resta.

import Foundation

final class Conservazione: NSObject {
    let registro: Registro
    let impostazioni: Impostazioni?
    /// Chiamata sul main prima di ogni "dimentica" della CLI: (ora, fine dell'intervallo cancellato).
    /// L'Annotatore riapre il tratto e scarta i segnali che arrivano in ritardo.
    var dopoDimentica: ((Int64, Int64) -> Void)?
    private var richiesteInCorso = false
    private var timer: Timer?
    private var ultimoGiorno = ""

    init(registro: Registro, impostazioni: Impostazioni?) {
        self.registro = registro
        self.impostazioni = impostazioni
        super.init()
    }

    func avvia() {
        esegui()
        let t = Timer(timeInterval: 3600, target: self, selector: #selector(controlla), userInfo: nil, repeats: true)
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func ferma() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func controlla() {
        if Registro.giornoDi(oraMs()).data != ultimoGiorno { esegui() }
    }

    /// Conservazione completa, adesso.
    func esegui(ora: Int64 = oraMs()) {
        ultimoGiorno = Registro.giornoDi(ora).data
        let giorni = impostazioni?.attuali.conservazioneGiorni ?? 14
        let registro = self.registro
        registro.conserva(giorni: giorni, ora: ora) { n in
            if n >= 0 {
                registro.evento(tipo: "servizio", ts: ora, dettaglio: ["cosa": "conservazione", "dettaglio": "\(n) eventi oltre \(giorni) giorni"])
            } else {
                registro.salute(sensore: "conservazione", stato: "guasto", dettaglio: registro.statoAttuale().errore)
            }
            DispatchQueue.main.async { self.eseguiRichieste() }
        }
    }

    /// Esegue le richieste "dimentica" scritte dalla CLI e le toglie dal file. Le cancellazioni
    /// girano sulla coda del Registro; il file e l'Annotatore si toccano sul main a lavoro finito.
    func eseguiRichieste() {
        guard let imp = impostazioni, !richiesteInCorso else { return }
        let richieste = imp.attuali.dimenticaRichieste
        if richieste.isEmpty { return }
        richiesteInCorso = true
        // Prima l'Annotatore: riapre il tratto adesso e da qui scarta ogni segnale con un ts
        // dentro gli intervalli (un OCR in volo). Poi le cancellazioni, in coda dopo di lui.
        dopoDimentica?(oraMs(), richieste.map { $0.a }.max() ?? oraMs())
        let gruppo = DispatchGroup()
        let lock = NSLock()
        var fatte: [RichiestaDimentica] = []
        for r in richieste {
            gruppo.enter()
            registro.dimentica(da: r.da, a: r.a) { n in
                if n >= 0 {
                    lock.lock()
                    fatte.append(r)
                    lock.unlock()
                }
                gruppo.leave()
            }
        }
        gruppo.notify(queue: .main) {
            self.richiesteInCorso = false
            if fatte.isEmpty { return }
            imp.modifica { d in
                let elenco = (d["dimentica_richieste"] as? [[String: Any]]) ?? []
                d["dimentica_richieste"] = elenco.filter { voce in
                    guard let da = (voce["da"] as? NSNumber)?.int64Value, let a = (voce["a"] as? NSNumber)?.int64Value else { return false }
                    return !fatte.contains(RichiestaDimentica(da: da, a: a))
                }
            }
        }
    }
}
