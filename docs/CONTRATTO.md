# Contratto fra registratore e analisi

Il registratore Swift scrive, l'analisi Python legge. Questo file è l'unica fonte delle regole che li legano. Lo schema SQL sta in `registratore/schema.sql`. Se una regola cambia, cambia qui e in entrambi i lati nello stesso commit, e `meta.schema_versione` sale di uno.

## Percorsi

| Cosa | Dove | Permessi |
|---|---|---|
| Cartella dati | `~/Library/Application Support/Lancillotto/` | 700, `tmutil addexclusion` |
| Registro | `registro.sqlite` (+ `-wal`, `-shm`) | 600 |
| Chiave HMAC | `chiave` (32 byte casuali, creata dal registratore al primo avvio se manca) | 600 |
| Impostazioni | `impostazioni.json` | 600 |
| Analisi | `analisi.sqlite`, rigenerabile, la scrive solo Python | 600 |
| App | `~/Applications/Lancillotto.app` | utente |
| Binario | `~/Applications/Lancillotto.app/Contents/MacOS/Lancillotto` | |
| Bundle id | `org.stellakamikaze.lancillotto` | |

Variabile d'ambiente `LANCILLOTTO_DIR`: se c'è, sostituisce la cartella dati (per i test, in entrambi i lati).

## Tempo e testo

- `ts` in millisecondi Unix, `dur_ms` in millisecondi. Le date di `giorno` sono in ora locale.
- Ogni testo compresso (`campo.valore_z`, `riga.testo_z`) è UTF-8 compresso in **DEFLATE raw** (Apple `COMPRESSION_ZLIB`). Python lo legge con `zlib.decompress(b, -15)`.
- Ogni testo salvato è già passato dal redattore. Il redattore sostituisce un segreto con `[TIPO#abcd]`, dove `abcd` sono i primi 4 caratteri hex dell'HMAC del valore. Tipi: `CARTA` (Luhn valido, 13-19 cifre), `IBAN` (mod-97 valido), `CF` (codice fiscale con carattere di controllo valido), `CHIAVE` (`sk-`, `sk-ant-`, `sk_live_`, `sk_test_`, `rk_live_`, `whsec_`, `ghp_`, `gho_`, `github_pat_`, `AKIA`, `xox[abpr]-`, `AIza`, `GOCSPX-`; e il valore di un'assegnazione `NOME=valore` o `"nome": "valore"` con `secret`, `token`, `api_key`, `access_key`, `private_key` o `_key` nel nome), `JWT` (tre segmenti base64url con header `eyJ`), `PEM` (blocchi `-----BEGIN ... PRIVATE KEY-----`), `OTP` (6-8 cifre da sole su una riga o vicino a "codice", "code", "OTP", "verifica"), `PASSWORD` (valore dopo "password:", "pwd=", "passcode"; la password in una frase, "la tua nuova password è X", "password temporanea X", con un valore che ha una cifra o un simbolo; le cifre dopo "PIN", "CVV", "CVC").
- Prima dei segreti il redattore toglie query e frammento da ogni URL del testo, con schema o senza (`host.tld/percorso?x#y` diventa `host.tld/percorso`), senza segnaposto. Vale per titoli, righe di schermo, valori dei campi ed etichette.
- Normalizzazione delle righe di schermo prima dell'hash: trim, spazi multipli ridotti a uno, righe sotto i 2 caratteri scartate.
- HMAC: HMAC-SHA256 con la chiave del file `chiave`, hex dei primi 16 byte. `oggetto.chiave_h` è l'HMAC di `tipo + "\u0000" + valore` (path completo per file, URL senza query per url, `bundle + "\u0000" + titolo` per finestra).
- `impronta.h` è l'HMAC del solo valore normalizzato, senza prefisso di tipo. Normalizzazione per tipo: `numero` sole cifre, da 6 in su; `iban` maiuscolo senza spazi; `email` minuscolo; `codice` maiuscolo.
- `riga.h` è lo SHA-256 (hex dei primi 16 byte) della riga normalizzata e già redatta, mai di quella grezza.

## Tipi di evento

`dettaglio` è JSON compatto (chiavi corte in italiano). Campi assenti = non noti.

| tipo | app_id | ogg_id | dur_ms | dettaglio | altro |
|---|---|---|---|---|---|
| `finestra` | sì | finestra, NULL finché il titolo non è noto | durata in primo piano, allungata dall'heartbeat (fusione se app e finestra uguali entro 30 s) | `{"pid":n}` | `tasti`, `click` totali del tratto; se il titolo arriva entro 2 s, lo stesso evento riceve `ogg_id` |
| `documento` | sì | file | 0 | `{"fonte":"axdocument"}` | quando cambia il documento della finestra a fuoco, e di nuovo a ogni ritorno sull'app |
| `url` | sì | url | 0 | `{"fonte":"ax"\|"applescript"}` | quando cambia l'URL della scheda attiva, e di nuovo a ogni ritorno sull'app |
| `campo_focus` | sì | finestra | 0 | `{"ruolo":"AXTextField","etichetta":"Importo"}` | etichetta da AXTitle, AXDescription, AXPlaceholderValue o titolo dell'AXTitleUIElement |
| `campo_valore` | sì | finestra | tempo nel campo | `{"ruolo":..,"etichetta":..}` | riga in `campo`; impronte con fonte `campo`. Solo se all'ingresso nel campo l'esito era pieno e titolo, URL e documento sono gli stessi all'uscita. `valore_z` NULL per la barra degli indirizzi e per un'etichetta da segreto (password, PIN, CVV, OTP, codice di sicurezza) |
| `clic` | sì | finestra | 0 | `{"ruolo":"AXButton","etichetta":"Carica"}` | solo AXButton, AXMenuItem, AXCheckBox, AXRadioButton, AXPopUpButton, AXLink dell'app attiva (pid uguale) fuori da AXWebArea; dentro AXWebArea solo `{"ruolo":..,"web":1}`; nei browser e sulle schede (AXTabButton) solo `{"ruolo":..}` |
| `menu` | sì | finestra | 0 | `{"percorso":"Archivio > Esporta come PDF…"}` | sotto Finestra, Window, Cronologia, History, Preferiti, Bookmarks, Segnalibri solo il primo livello (`{"percorso":"Cronologia"}`) |
| `comando` | sì | finestra | 0 | `{"tasti":"cmd+c"}` | solo combinazioni con cmd o ctrl; nome canonico ordinato `ctrl+opt+shift+cmd+<tasto>` |
| `appunti` | sì (sorgente) | finestra | 0 | `{"tipi":["public.utf8-plain-text"],"riservato":0,"len":n}` | `cc` = nuovo changeCount; impronte con fonte `selezione` dal testo di AXSelectedText della sorgente, mai dal pasteboard |
| `file_crea` / `file_mod` / `file_sposta` / `file_elimina` | null | file | 0 | `{"da":"<chiave_h vecchio path>"}` solo per sposta | con provenienza da un dominio escluso: oggetto senza `etichetta` né `provenienza`, nessuna impronta |
| `schermo` | sì | finestra | 0 | `{"fonte":"ax"\|"ocr","ms":costo}` | riga in `schermo` |
| `inattivo` | null | null | durata | `{}` | oltre 180 s senza input |
| `sonno` / `risveglio` / `blocco` / `sblocco` | null | null | 0 | `{}` | |
| `pausa` | null | null | durata | `{"motivo":"menu"\|"cli"\|"fino_a_domani"}` | |
| `protetto` | sì | null | durata | `{}` | secure input o AXSecureTextField a fuoco: nient'altro |
| `escluso` | sì | null | durata | `{"perche":"app"\|"dominio"\|"privata"\|"dubbio"\|"cartella"}` | app o sito esclusi, finestra privata (anche Safari e Arc, che non la distinguono), browser con titolo ma senza URL letto (`dubbio`), documento a fuoco in una cartella esclusa (`cartella`): solo app e durata |
| `servizio` | null | null | 0 | `{"cosa":"avvio"\|"stop"\|"permesso"\|"impostazioni"\|"esclusione_tolta"\|"conservazione","dettaglio":"..."}` | per `esclusione_tolta` il dettaglio è `app:<bundle>` oppure `dominio:<dominio>` |

Come l'analisi legge alcune di queste regole:
- `documento` e `url` ripetuti sullo stesso oggetto nella stessa app entro 10 minuti valgono come ritorno, non come apertura o visita nuova (`episodi.Contesto.ritorno`).
- `schermo`: con lo stesso testo di prima nella stessa finestra non nasce nessun evento. `riga.volte` cresce solo quando una riga ricompare dopo essere sparita.
- Senza Accessibilità non si registra testo a schermo: senza il titolo il registratore non sa se la finestra è privata o di una banca.

## Cosa non entra mai

Nessuna colonna contiene: tasti digitati come caratteri, contenuto del pasteboard, immagini, valori di `AXSecureTextField`, niente scritto mentre `IsSecureEventInputEnabled()` è vero, titoli o testo di app e domini esclusi, query string e frammenti degli URL. I banchi lo provano con il veleno.

Esclusioni di default scritte nel binario (il JSON può solo aggiungere):
- app (bundle id o prefisso): `com.1password`, `com.agilebits`, `com.bitwarden`, `com.dashlane`, `com.apple.keychainaccess`, `com.apple.Passwords`, `com.apple.MobileSMS`, `net.whatsapp.WhatsApp`, `desktop.WhatsApp`, `org.whispersystems.signal-desktop`, `ru.keepcoder.Telegram`, `org.telegram.desktop`, `com.automattic.beeper.desktop`, `com.beeper`, app con "bank", "banca", "trading", "fineco", "intesa", "unicredit" nel bundle id o nel nome;
- domini (suffisso): banche italiane principali (`fineco.it`, `intesasanpaolo.com`, `unicredit.it`, `bancobpm.it`, `credem.it`, `poste.it`, `bper.it`, `mps.it`, `ing.it`, `n26.com`, `revolut.com`, `paypal.com`), `agenziaentrate.gov.it`, `inps.it`, `fascicolosanitario.gov.it`, `sistemapiemonte.it`, `accounts.google.com`, `login.microsoftonline.com`, `appleid.apple.com`, `id.atlassian.com`; path che contiene `/login`, `/signin`, `/sign-in`, `/auth`, `/oauth`, `/sso`, `/password`;
- cartelle per FSEvents e per il documento a fuoco (AXDocument): `Library`, `.git`, `node_modules`, `.Trash`, `.env`, nomi con `secret`, `credential`, `password`, `.ssh`, `.gnupg`. Per il documento a fuoco `Library` non vale negli allegati di Mail, in iCloud Drive (`Library/Mobile Documents`) e in `Library/CloudStorage`;
- browser senza un segno provato della finestra privata: `com.apple.Safari`, `com.apple.SafariTechnologyPreview`, `company.thebrowser.Browser`. Ogni loro finestra vale come privata finché la sonda della fase 0 non trova un segno affidabile; il sensore che lo trova mette l'attributo `privata = "0"`;
- un browser con il titolo noto ma senza URL letto: `escluso` "dubbio", e il sensore rilegge l'URL dopo 1 s (al massimo 3 volte per titolo);
- nei browser il testo a schermo si legge solo dentro la AXWebArea (mai schede, barra indirizzi, barre degli strumenti) e l'OCR tiene solo le righe dentro la cornice della pagina.

## Impostazioni (`impostazioni.json`)

```json
{
  "versione": 1,
  "pausa_fino": 0,
  "conservazione_giorni": 14,
  "ocr": true,
  "valori_campi": true,
  "cartelle": ["~/Downloads", "~/Documents", "~/Desktop"],
  "escludi_app": [],
  "escludi_domini": [],
  "dimentica_richieste": []
}
```

Chiavi facoltative, assenti dal JSON di default:
- `testo_schermo` (default `false`, dal 25/10/2026): se vera, il registratore legge il testo della finestra attiva (AX e, col permesso, OCR). Se falsa non parte nessuna lettura e `Annotatore.schermo` scarta anche un OCR già in volo. In salute il sensore facoltativo `testo` dice `spento`. `installa.sh` la scrive `true` a chi arriva dall'Ancillotto, che la leggeva sempre. `valori_campi` ora ha default `false` per le installazioni nuove.
- `ax_electron` (default `false`): se vera, il registratore accende `AXManualAccessibility` nelle app Electron. Quelle app costruiscono allora il loro albero di Accessibilità, al costo di più CPU nell'app.

- Scrittura sempre atomica (`.tmp` nella stessa cartella e rename). Il registratore sorveglia la **cartella**, non il file, e rilegge entro 2 s.
- `pausa_fino`: ms Unix; 0 = registra. Un valore nel futuro mette in pausa fino a quell'ora.
- "Pausa fino a domani", dal menu o da `lancillotto pausa domani`, dura fino alla mezzanotte locale.
- `dimentica_richieste`: lista di `{"da":ms,"a":ms}`. Il registratore cancella eventi, campi, righe orfane, schermi e impronte nell'intervallo, poi toglie la richiesta. La CLI può anche cancellare da sola se il registratore è fermo.
- Togliere un'esclusione aggiunta scrive un evento `servizio` con `esclusione_tolta`.

## Cancellazioni dalla CLI e id in memoria

Il registratore tiene in memoria gli id di app, oggetti e righe, e assegna da sé gli id degli eventi (contatore da `MAX(id)+1`). Con `PRAGMA foreign_keys = ON`, un id di app o di oggetto che non esiste più fa fallire il lotto: il registratore svuota la sua memoria e riscrive il lotto una volta.
- `dimentica` ed `escludi` dalla CLI cancellano eventi, campi, impronte, schermi e righe orfane. Gli oggetti restano, con l'etichetta tolta. `dimentica` accorcia all'inizio dell'intervallo l'evento che lo attraversa. Se il registratore è acceso (`ultimo_battito` entro 2 minuti), `dimentica` aggiunge anche la richiesta in `dimentica_richieste`: il registratore cancella ciò che ha ancora in RAM, scarta i segnali in ritardo con un ts dentro l'intervallo (un OCR in volo) e svuota la memoria degli id.
- `escludi` scrive PRIMA l'esclusione in impostazioni.json (sempre bundle id per le app, sempre un dominio con un punto per i siti; un nome che non si risolve è un errore e non si scrive). Se il registratore è acceso, la CLI aspetta fino a 6 s `meta.esclusioni_applicate` più recente della scrittura: il registratore, quando rilegge esclusioni nuove, mette su disco il lotto in RAM, cancella lui stesso le app appena escluse e scrive quell'ora. Solo dopo la CLI cancella all'indietro. `escludi sito` cancella anche i file_* il cui oggetto ha quella provenienza, e toglie nome e provenienza a quegli oggetti.
- Ogni cancellazione, del registratore (dimentica, esclusione, conservazione) o della CLI, fa salire `meta.cancellazioni`. L'analisi riparte da zero quando cambia: dopo una cancellazione SQLite riusa gli id di `riga` e `schermo`, e i conteggi fino al cursore possono tornare uguali.
- Il registratore assegna gli id degli eventi da `max(MAX(id) + 1, meta.prossimo_id)` e scrive `meta.prossimo_id` a ogni lotto: un id cancellato non torna in uso nemmeno dopo un riavvio. La cache delle righe controlla l'hash prima di riusare un id.
- `cancella-tutto` cancella ogni tabella e lascia in `app`, `oggetto` e `riga` una lapide vuota (`~cancellato`) con l'id più alto + 1. Così SQLite non riusa gli id vecchi: un id rimasto in memoria non punta mai a una riga nuova di un'altra app. Se il registratore è acceso, la CLI aggiunge la richiesta `{"da": 0, "a": <ora>}`.
- Il registratore, nella sua `dimentica` e nella conservazione, cancella gli oggetti e le righe orfani, lapidi comprese, e poi svuota la sua memoria degli id.

## meta

`schema_versione` (1), `versione_binario`, `ultimo_battito` (ms, ogni 30 s), `persi` (eventi scartati per coda piena, parte da 0), `avvio` (ms), `permesso_ax` (0/1), `permesso_schermo` (0/1, aggiornato dal sensore dello schermo quando il permesso cambia), `prossimo_id` (il prossimo id di evento), `cancellazioni` (contatore, sale a ogni cancellazione), `esclusioni_applicate` (ms dell'ultima rilettura di esclusioni nuove), `avvio_login_saltato` (1 se la persona ha premuto "Salta" al passo dell'avvio al login).

## giorno e salute

- `giorno.byte` è il peso del registro su disco (file e `-wal`) all'ultimo lotto di quel giorno, non il peso del solo giorno. `lancillotto stato` stima il peso di oggi dai dati di oggi (dettagli degli eventi, valori dei campi, righe comparse oggi, delta delle istantanee, impronte): con la conservazione a regime il file cala ogni notte e la crescita da ieri non dice niente.
- Salute: il sensore `input` si riscrive quando il permesso di Accessibilità cambia (controllo ogni 5 s). `stato` tiene a parte i sensori facoltativi spenti per scelta (`ocr` senza Registrazione schermo, `avvio_login` saltato). Al lancio l'app scrive sempre una riga `avvio_login`.
- Il sensore dello schermo tiene una sua stima del peso del giorno, per dosare le letture: testi delle righe nuove, delta delle istantanee e dettagli degli eventi, da mezzanotte. Oltre 40 MB l'intervallo raddoppia, oltre 80 diventa 4 volte, al massimo 8 volte; a mezzanotte torna a 20 s.
- Righe di `salute` del testo a schermo: `schermo` per costi, riduzione e guasti; `ocr` per stato e permesso.

## Consenso L2

1. La CLI inserisce in `consenso` una riga con `id` casuale, `t0`, `t1`, `descrizione` composta da lei (orari, app, numero di righe) e `deciso` NULL.
2. Il registratore controlla `consenso` ogni 2 s. Se c'è una richiesta in attesa, l'icona mostra un punto e il menu una voce "Claude chiede il testo di: <descrizione>" con "Mostra" e "Rifiuta".
3. Al clic scrive `deciso` (1 o 0), `deciso_ts` e `scade_ts = deciso_ts + 600000`.
4. La CLI dà il testo solo se `deciso = 1` e ora < `scade_ts`, e solo dentro `t0..t1`.

È un dosso contro gli errori, non un muro contro un programma malevolo che gira come l'utente: il muro vero è la redazione alla fonte. La documentazione lo dice così.
