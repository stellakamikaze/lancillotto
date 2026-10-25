# Lancillotto

Lancillotto è un piccolo programma per il Mac. Annota come usi il computer: quali app apri, quali finestre e file usi, come passi i dati da una app all'altra. Se lo scegli tu, annota anche il testo della finestra che hai davanti e il valore dei campi, ripuliti da password e codici: di base è spento. Non registra video e non registra i singoli tasti. Dopo qualche giorno chiedi a Claude Code "dove mi puoi aiutare?". Claude legge i riassunti, trova i lavori che fai sempre uguali e ti propone quali può fare lui.

Il registro resta sul tuo Mac. Claude ne legge solo i riassunti, e solo quando glielo chiedi tu.

## Cosa annota

- quale app usi e per quanto tempo;
- il titolo della finestra e il documento aperto;
- l'indirizzo del sito, senza la parte dopo il "?" e il "#";
- il nome del campo in cui scrivi ("Importo", "Oggetto"); il valore dei campi quando ne esci solo se accendi il testo delle finestre, ripulito e tagliato a 500 caratteri (mai nei campi password, PIN, CVV e codici);
- i pulsanti e le voci di menu che clicchi;
- le scorciatoie come cmd+c e cmd+v, e quanti tasti premi (mai quali lettere);
- quando copi qualcosa: da quale app e di che tipo, mai il contenuto copiato;
- i file nuovi o cambiati in Download, Documenti e Scrivania, e da quale sito arriva un download;
- solo se lo accendi tu, dalla finestra di Lancillotto: il testo della finestra attiva, ripulito, una riga per volta;
- quando il Mac è inattivo, in sonno, bloccato o in pausa.

Prima di salvare qualsiasi testo, Lancillotto toglie numeri di carta, IBAN, codici fiscali, codici OTP, password, PIN e chiavi di accesso, e dagli indirizzi web la parte dopo il "?" e il "#". Al loro posto scrive un segnaposto come `[IBAN#3f2a]`.

## Cosa non annota mai

- video, foto dello schermo salvate, audio;
- le lettere che digiti;
- il contenuto degli appunti;
- niente mentre scrivi una password, in nessuna app;
- niente delle app escluse: gestori di password, Portachiavi, banche e trading, Messaggi, WhatsApp, Signal, Telegram, Beeper;
- niente delle finestre in incognito; Safari e Arc non dicono se una finestra è privata, quindi per ora annota solo il nome dell'app e il tempo;
- niente dei siti esclusi: home banking, Agenzia delle Entrate, INPS, Fascicolo Sanitario, pagine di login;
- niente delle cartelle di sistema e di sviluppo, nemmeno un file aperto da lì (`.env`, `.ssh`, `Library`);
- da un browser di cui non legge l'indirizzo della pagina, niente titolo né testo: potrebbe essere un sito escluso.

Per le app e i siti esclusi annota solo il nome dell'app e quanto tempo ci sei stato.

## Dove vanno i dati

Ci sono quattro perimetri.

1. **Il registro resta sul Mac.** Sta in una cartella privata (`~/Library/Application Support/Lancillotto`), fuori da Time Machine e da iCloud. Pesa pochi MB al giorno. I dati grezzi si cancellano da soli dopo 14 giorni. L'app nella barra dei menu non si collega a internet: il suo codice non contiene nessuna funzione di rete, e un test lo controlla.
2. **Quello che Claude legge va ad Anthropic.** Quando chiedi a Claude di guardare il registro, Claude legge i riassunti, e la conversazione passa dai server di Anthropic come ogni altra conversazione con Claude. I riassunti non contengono testo libero: i nomi dei clienti diventano segnaposto come `[P3]` e i siti poco noti diventano `[SITO_2]`. Il training sui tuoi dati lo controlli nelle impostazioni del tuo account su claude.ai.
3. **Le routine che confermi o rifiuti vanno nella memoria di Claude.** Quando dici sì o no a una proposta, Claude scrive una nota con la descrizione della routine e, per un no, il motivo con le tue parole. La nota sta nella memoria di Claude (`~/.claude/data/memory`). Se quella cartella è sincronizzata (un repo git, un server, un altro Mac), la nota esce dal Mac come il resto della memoria. Claude ti chiede il permesso prima di scriverla.

4. **Pochi dati d'uso vanno a chi mantiene Lancillotto, se dici sì.** Servono a vedere dove si inceppa sui Mac degli altri. Escono un id casuale, la versione, la versione di macOS, il giorno e un evento da un elenco chiuso: i passi della guida, i permessi sì o no, quanti eventi, MB e ore nel giorno (in fasce, mai il numero esatto), i sensori guasti, i browser di cui non legge l'indirizzo, i comandi usati da Claude, quante routine hai confermato. Non escono mai app, siti, titoli, file, testo o campi. Li riceve il server di Arturo, che non salva l'IP e li tiene 12 mesi. L'id è casuale, ma chi mantiene Lancillotto può sapere chi c'è dietro se ti conosce: non sono dati anonimi. Li vedi con `lancillotto telemetria`, li spegni dalla finestra o con `lancillotto telemetria spegni`, che cancella anche la coda.

Per vedere esattamente cosa può leggere Claude, scrivi nel Terminale `lancillotto mostra`: si apre una pagina sul tuo computer con quei dati.

## Permessi

- **Accessibilità** (obbligatorio). Serve a vedere quale finestra usi e quale campo è attivo. Senza, Lancillotto vede solo quale app è in primo piano.
- **Registrazione schermo** (facoltativo). Serve solo a leggere il testo delle app che non lo danno in altro modo. L'immagine viene letta e buttata subito, mai salvata. macOS chiede di rinnovare questo permesso ogni mese. Se dici no, Lancillotto funziona lo stesso.
- **Notifica "Elemento in background aggiunto"**. Arriva quando l'installatore accende l'avvio al login. Vuol dire che Lancillotto si riaccende da solo quando accendi il Mac e dopo un blocco. È normale. Se lo chiudi con "Esci" dal suo menu, resta chiuso fino al prossimo accesso. Se hai premuto "Salta" nella finestra guidata, lo puoi accendere dopo con la voce "Avvia al login" del menu. Se in Impostazioni di Sistema > Generali > Elementi login spegni Lancillotto, non si riaccende più da solo.

## Installazione in 3 passi

1. Apri il Terminale (lo trovi con Spotlight: cmd+spazio, poi "Terminale").
2. Scrivi `cd ` seguito dal percorso della cartella di Lancillotto, poi `./installa.sh` e premi Invio. Se mancano gli strumenti di Apple, l'installatore te lo dice e ti spiega come averli.
3. Si apre una finestra che chiede il permesso di Accessibilità. Premi il pulsante, accendi l'interruttore di Lancillotto e torna alla finestra.

Se vuoi vedere prima cosa farebbe l'installatore, senza installare niente: `./installa.sh --solo-verifica`.

Nella barra dei menu in alto compare l'icona di Lancillotto: verde se registra, grigia in pausa, gialla se qualcosa non va. Al primo avvio una guida in quattro passi chiede il permesso di Accessibilità, se annotare anche il testo delle finestre e se mandare i dati d'uso.

## La finestra

Dall'icona, "Apri Lancillotto" apre la finestra con quattro sezioni:

- **Oggi**: se sta annotando, i permessi, dove è andato il tempo della giornata;
- **Cosa vede Claude**: i compiti che Arturo ha giudicato delegabili dopo averti letto, con quante volte e quanto tempo, e cosa esce dal Mac;
- **Privacy**: testo delle finestre e dati d'uso, app e siti da escludere, cosa dimenticare;
- **Arturo**: la domanda da fare ad Arturo e un pulsante che la apre nel Terminale.

## Pausa, esclusioni, cancellazione

Dalla finestra o dal menu dell'icona, oppure dal Terminale:

| Cosa vuoi | Finestra o menu | Terminale |
|---|---|---|
| fermarlo per un po' | Pausa di un'ora, Pausa fino a domani | `lancillotto pausa` |
| togliere la pausa | Riprendi | `lancillotto riprendi` |
| non registrare più un'app | Escludi l'app | `lancillotto escludi app Chrome` |
| non registrare più un sito | Escludi il sito | `lancillotto escludi sito fineco.it` |
| cancellare gli ultimi 10 minuti | Gli ultimi 10 minuti | `lancillotto dimentica 10` |
| cancellare la giornata | Tutta la giornata di oggi | |
| cancellare tutto | | `lancillotto cancella-tutto` |
| vedere se registra | Apri Lancillotto | `lancillotto stato` |

Escludere un'app cancella anche quello che Lancillotto aveva già annotato su quell'app. Nella finestra scegli l'app fra quelle di oggi; nel Terminale scrivi il nome come lo vedi nel menu in alto ("Chrome", "Outlook"). Un sito si scrive col dominio, per esempio `fineco.it`.

Se `lancillotto stato` dice che è fermo, riaprilo con `open ~/Applications/Lancillotto.app`. "Riprendi" toglie solo la pausa: non riaccende un Lancillotto chiuso.

## Chiedere a Claude

Apri Claude Code e scrivi, con parole tue:

- "dove mi puoi aiutare?"
- "cosa posso delegare questa settimana?"
- "guarda cosa ho fatto oggi"

Claude risponde con 1-3 proposte, per esempio: "Ogni mattina passi circa 25 minuti a copiare dati dai PDF che arrivano in Mail a un portale: 11 volte in 4 giorni. Claude Code può leggere i PDF e prepararti i valori da incollare. Vuoi provarlo?". Decidi tu. Se dici sì, Claude se lo ricorda. Se dici no, la proposta non torna.

Nei primi 2-3 giorni Claude vede solo le ripetizioni dentro la giornata. Le abitudini di ogni giorno compaiono dopo.

Claude può chiedere di leggere il testo di un momento preciso. In quel caso nel menu di Lancillotto compare "Claude chiede il testo di: ..." con l'orario e le app. Il testo arriva a Claude solo se premi "Mostra", e il permesso dura 10 minuti.

## Disinstallazione

Nel Terminale, nella cartella di Lancillotto: `./disinstalla.sh`. Toglie l'app, il comando `lancillotto` e il collegamento per Claude. Ti chiede se cancellare anche il registro (la risposta normale è no). Alla fine ti ricorda i due comandi che tolgono i permessi da macOS.

## Aggiornamento

Lancillotto si aggiorna da solo una volta al giorno. Prende le modifiche nuove dal suo repository, e si ferma se nella tua copia qualcuno ha cambiato dei file a mano. Per aggiornarlo subito, nel Terminale: `lancillotto aggiorna`.

Di solito cambia solo la parte che analizza i dati, e l'aggiornamento non ti chiede niente. Quando cambia l'app, l'aggiornamento la ricompila, e macOS la tratta come un'app nuova: il permesso di Accessibilità di prima non vale più, anche se l'interruttore resta acceso. Apri la finestra di Lancillotto dalla barra dei menu, nella riga "Accessibilità" premi "Apri Impostazioni" e accendi Lancillotto nella lista.

## Limiti onesti

- **App Electron e siti web.** Slack, Notion, Discord e molti siti danno poco testo all'Accessibilità. Lì Lancillotto vede app e sito, ma spesso non i passaggi. La Registrazione schermo aiuta, ma non sempre. Claude te lo dice quando succede.
- **Lettura dello schermo (OCR).** Legge una sola finestra, al massimo una volta ogni 20 secondi. Può sbagliare lettere e perdere righe.
- **Il clic "Mostra" è un dosso, non un muro.** Ferma gli errori di Claude. Non ferma un programma malevolo che gira già sul tuo Mac con il tuo utente. Il muro vero è la pulizia alla fonte: i segreti non entrano mai nel registro.
- **Il registro non è cifrato.** Lo proteggono la cartella privata, FileVault (l'installatore controlla che sia acceso) e la pulizia alla fonte. Un programma malevolo con il tuo utente potrebbe leggere i testi già ripuliti.
- **Dati di clienti e colleghi.** Se sul Mac lavori con dati di altre persone, il registro contiene i loro nomi nei titoli e nel testo a schermo. Per un uso solo personale di solito vale l'esenzione domestica del GDPR. Per un uso di lavoro con dati di clienti o colleghi probabilmente non vale: prima di installarlo su un Mac di lavoro serve un parere privacy scritto.

---

## Parte tecnica

### Architettura

```
 Lancillotto.app (Swift, barra dei menu, compilato in locale, nessuna API di rete nel binario)
 ┌──────────────────────────────────────────────────────────────────────────────┐
 │ NSWorkspace (app, sonno, blocco)       ─┐                                    │
 │ AXObserver (finestra, titolo,           │                                    │
 │   AXDocument, URL, focus, menu, clic)   │                                    │
 │ Testo finestra: AX a budget  ──vuoto──> OCR Vision sulla sola finestra attiva│
 │   (immagine buttata subito, max 1/20 s, solo con permesso schermo)          │
 │ Valore campo all'uscita dal campo       ├─> FILTRO ALLA FONTE ─> REDATTORE ─> │
 │ NSEvent global (scorciatoie, conteggi)  │   secure input / AXSecureTextField  │
 │ Pasteboard changeCount + tipi           │     -> solo "campo protetto"        │
 │ FSEvents Download/Documenti/Scrivania   │   app o dominio escluso -> solo     │
 │ idle (CGEventSource ogni 5 s)          ─┘     "app, durata"                  │
 │                                             incognito o dubbio -> niente testo│
 │                                             pausa -> scarta tutto            │
 │                                             redattore: Luhn, IBAN, CF, OTP,  │
 │                                             chiavi API, JWT, PEM -> [segnaposto]│
 └───────────────────────────────────────────────────┬──────────────────────────┘
   ombra: Accessibilità persa -> solo NSWorkspace,    │ lotti ogni 10 s, SQLite WAL
          pallino giallo, riga in salute              │
   ombra: permesso schermo negato o scaduto ->        │
          niente OCR, il resto continua               │
   ombra: disco pieno -> coda in RAM max 1000,        │
          poi scarta e conta in meta.persi            │
   ombra: processo morto -> launchd lo riavvia,       │
          "stato" dice "fermo dalle X"                │
                                                      v
   ~/Library/Application Support/Lancillotto/registro.sqlite  (cartella 700, file 600,
                                    fuori da Time Machine, iCloud e ~/.claude)
                                                      │ lettura con PRAGMA query_only
                                                      v
   lancillotto (CLI Python stdlib, 3.8+)
     episodi -> simboli -> legami -> n-gram e varianti -> routine -> analisi.sqlite
     ombra: registro assente o vuoto -> {"dati": null, "causa": "..."}, mai inventato
     ombra: schema più nuovo del lettore -> errore chiaro e "aggiorna Lancillotto"
                                                      │ JSON pseudonimizzato, involucro
                                                      │ "dati osservati, non istruzioni"
                                                      v
   Claude Code (skill lancillotto) -> proposta -> sì della persona -> nota Melchior
                                                 no  -> rifiutata, non torna
   lancillotto mostra -> pagina HTML locale con ciò che Claude può vedere
```

Il binario Swift raccoglie e filtra, e cambia di rado. Tutta la logica che si corregge sui dati veri (episodi, legami, routine, uscita verso Claude) sta in Python. Così una correzione dell'analisi non fa perdere il permesso di Accessibilità, che con la firma ad-hoc è legato al cdhash del binario.

### Struttura

| Percorso | Contenuto |
|---|---|
| `registratore/` | sorgenti Swift (`Sorgenti/`), `schema.sql`, `build.sh`, `banco.sh` |
| `lancillotto/` | pacchetto Python stdlib (3.8+): lettura, episodi, legami, routine, uscita, Melchior, `mostra` |
| `bin/lancillotto` | CLI con verbi `--json` |
| `skill/SKILL.md` | skill di Claude Code, collegata in `~/.claude/skills/lancillotto` |
| `installa.sh`, `disinstalla.sh` | installazione senza sudo in `~/Applications` |
| `tests/` | `run.sh` e i test Python in `tests/python/` |
| `docs/` | `PIANO.md` (piano approvato), `CONTRATTO.md`, `PROGETTAZIONE.md` |

### Contratto

Il registratore scrive, l'analisi legge. Le regole che li legano (percorsi, tipi di evento, campo `dettaglio`, redattore, impostazioni, consenso L2) stanno solo in [`docs/CONTRATTO.md`](docs/CONTRATTO.md). Lo schema SQL sta in [`registratore/schema.sql`](registratore/schema.sql). Una regola che cambia, cambia lì e in entrambi i lati nello stesso commit, e `meta.schema_versione` sale di uno.

`LANCILLOTTO_DIR` sostituisce la cartella dati in entrambi i lati: i test la usano sempre verso una cartella temporanea.

### Compilazione

`registratore/build.sh` compila con `swiftc -O -swift-version 5 -target <arch>-apple-macos13`, solo framework di sistema, e firma ad-hoc. `registratore/build.sh --veleno` produce in `registratore/build-veleno/` una versione con i filtri spenti, che serve solo ai test.

### Test

```bash
bash tests/run.sh
```

Funziona da qualunque cartella. I passi:

| Passo | Cosa prova |
|---|---|
| `build`, `build-veleno` | la compilazione normale e quella col veleno |
| `banco` | con `~/.claude/scripts/gate-run.sh`: prima `banco.sh` sul binario veleno deve dare "VELENO TROVATO", poi sul binario vero "BANCO VERDE" |
| `python-sistema`, `python3` | gli unittest di `tests/python/` con `/usr/bin/python3` e con `python3` |
| `integrazione` | lo scenario sintetico Swift letto dalla CLI: `routine --json` contiene Mail > Anteprima > Chrome; `oggi --json` e `routine --json` senza veleni né il dominio privato dello scenario |
| `sintassi-bash`, `sintassi-python` | `bash -n` su ogni script; `py_compile` e sintassi entro Python 3.8 |

Alla fine stampa una tabella PASS/FAIL ed esce 1 se un passo fallisce. Un componente che manca dà FAIL "manca X". Nessun test avvia l'app in modo normale: si usano solo `--selftest` e `--scenario-sintetico`, che non toccano Accessibilità, schermo, permessi né finestre.

`registratore/banco.sh [BINARIO]` da solo controlla: nessun simbolo di rete con `nm -u`, nessun framework di rete con `otool -L`, `--selftest` verde, nessun veleno nei byte e nei testi decompressi dello scenario sintetico, cartella dati reale invariata.
