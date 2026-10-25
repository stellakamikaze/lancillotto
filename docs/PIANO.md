# Lancillotto: piano

> Aggiornamento del 25/10/2026: rinomina in Lancillotto, testo delle finestre spento di base (`testo_schermo`), telemetria da un elenco chiuso verso il server di Arturo (`lancillotto/telemetria.py`, l'app resta senza funzioni di rete), finestra SwiftUI e aggancio ad Arturo. Il piano di quella fase è nel README e nei commit del 25/10.

## Contesto

Le persone che usano Arturo non sanno ancora quali parti del loro lavoro quotidiano possono passare per Claude Code. Lancillotto registra per giorni l'uso del Mac in forma testuale, senza video e solo in locale. Poi Claude Code e Arturo interrogano il registro, ricostruiscono le catene di azioni (copia in A, incolla in B; scarica, apri, modifica, carica) e propongono cosa delegare. Le routine confermate dalla persona diventano note Melchior.

Il progetto nasce da un workflow di progettazione (5 ricerche, 3 architetture, 4 giudici avversariali). Le scelte di Federico del 24/10/2026 cambiano tre punti della sintesi:
- **Contenuto**: "Anche il testo a schermo". Si registrano il testo delle finestre e il valore dei campi, redatti alla fonte.
- **Dove**: "Repo separato", `~/Documents/ClaudeCode/lancillotto/`.
- **Firma**: firma locale gratuita (ad-hoc, legata al cdhash). L'Accessibilità va riaccesa solo quando cambia il binario Swift.

## Architettura

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

Principio: il binario Swift raccoglie e filtra, e cambia di rado. Tutta la logica che si corregge sui dati veri (episodi, legami, routine, uscita verso Claude) sta in Python. Così una correzione dell'analisi non fa perdere il permesso di Accessibilità.

## Cosa registra e cosa no

Registra: app in primo piano e durata; titolo della finestra; documento aperto (path, estensione, inode); URL senza query né frammento; ruolo ed etichetta del campo a fuoco; valore del campo all'uscita, redatto e troncato a 500 caratteri; bersaglio dei clic su pulsanti e voci di menu; percorso dei menu; scorciatoie con modificatore e conteggi di tasti e clic (mai i caratteri); cambi degli appunti (`changeCount`, tipi, app sorgente, hash della selezione alla copia); file in Download, Documenti e Scrivania con provenienza dei download; testo della finestra attiva, salvato per righe uniche; inattività, sonno, blocco, pause; salute dei sensori.

Non registra mai: video, screenshot su disco, audio; tasti come testo; contenuto degli appunti; niente durante secure input o su `AXSecureTextField`; appunti marcati riservati; testo e titoli delle app escluse di default (gestori di password, Portachiavi, banche e trading, Messaggi, WhatsApp, Signal, Telegram, Beeper); finestre in incognito; domini esclusi di default (home banking, Agenzia Entrate, INPS, Fascicolo Sanitario, pagine di login); cartelle di sistema e sviluppo (`Library`, `.git`, `node_modules`, `.env`).

Peso atteso: 6-20 MB al giorno su 8 ore, con deduplica per righe e zlib. Conservazione del grezzo 14 giorni (configurabile), aggregati e routine più a lungo.

Permessi macOS: Accessibilità obbligatoria. Registrazione schermo facoltativa, solo per l'OCR: da Sequoia macOS la richiede ogni mese, e senza di essa Lancillotto continua con il testo da AX. Forse "File e cartelle" una volta per la provenienza dei download (da provare). Monitoraggio input e Accesso completo al disco non servono.

## Uscita verso Claude (il punto delicato)

Il registro resta sul Mac, ma ciò che Claude legge va ai server di Anthropic. Per questo l'uscita ha tre livelli:
- **L0 aggregati** (default, circa 400 token): tempo per app, episodi lunghi, routine con punteggio. Nessun testo libero.
- **L1 metadati pseudonimizzati**: sequenze di simboli (`Mail:apri_allegato:pdf > Anteprima:copia > Chrome:incolla:[SITO_2] x6`), legami con prova e confidenza. Nei titoli escono solo le parole di un vocabolario generico it/en; ogni altra parola diventa `[P3]`. Domini pubblici noti in chiaro, gli altri `[SITO_n]`.
- **L2 testo redatto di un intervallo**: solo dopo un clic della persona nella barra dei menu, con un testo composto dall'app (non da Claude). Il permesso vale 10 minuti e solo per quell'intervallo.

Difese contro la prompt injection dal testo a schermo: involucro "dati osservati", lettura L2 in un subagent senza rete, nessuna azione con effetti nella risposta che ha letto il registro, note Melchior scritte da Claude e confermate dalla persona.

## Struttura del repo

`~/Documents/ClaudeCode/lancillotto/` (git, branch `main`; il remote GitHub si decide alla fine, privato di default):
- `registratore/` sorgenti Swift (un solo modulo compilato con `swiftc -O -swift-version 5`), `Info.plist`, `build.sh`, `banco.sh` (assenza di rete con `nm -u`, `otool -L`, `lsof`);
- `lancillotto/` pacchetto Python stdlib: `registro.py` (lettura), `episodi.py`, `legami.py`, `routine.py`, `uscita.py` (allowlist, pseudonimi, livelli), `melchior.py` (ponte), `mostra.py` (pagina HTML locale);
- `bin/lancillotto` CLI con verbi `--json`: persona (`stato`, `pausa`, `riprendi`, `escludi`, `dimentica`, `cancella-tutto`, `mostra`, `rivedi`), L0 (`oggi`, `giorno`, `settimana`, `routine`, `raggiungo`), L1 (`episodi`, `episodio`, `catene`, `cerca`, `conta`, `verifica --sql` su viste `v_*` con `set_authorizer` e tetto 200 righe), L2 (`testo`), Melchior (`conferma`, `rifiuta`, `automatizzata`);
- `skill/SKILL.md`, collegata in `~/.claude/skills/lancillotto/` dall'installatore, sia nella config di Federico sia in Arturo;
- `installa.sh` e `disinstalla.sh`: compilano, firmano ad-hoc, mettono l'app in `~/Applications`, creano la cartella dati, attivano l'avvio al login (`SMAppService`, riserva LaunchAgent; dal 25/10 la riserva è la scelta, perché `SMAppService.mainApp` con firma ad-hoc risponde `.notFound`), aprono la finestra guidata dei permessi;
- `tests/` con banchi lanciati da `~/.claude/scripts/gate-run.sh` (veleno prima sulla versione rotta).

Riuso: scrittura atomica delle impostazioni come in `arturo/bin/memoria.py`; frontmatter delle note come `arturo/hooks/melchior-postwrite.py` lo valida; ricerca dei duplicati con `scripts/melchior_recall.py` prima di proporre; schema delle fasi facoltative di `arturo/commands/setup.md` (7d, 8b) per l'aggancio finale.

## Fasi

Ogni fase si chiude con test verdi letti da file, poi commit. Le fasi 1-5 le costruisco con workflow (ultracode): implementazione, banchi col veleno, review avversariale.

| Fase | Contenuto | Fatto quando |
|---|---|---|
| 0. Sonde | Binario Swift usa e getta sul tuo Mac: URL da AX in Safari, Chrome, Arc, Firefox; `AXDocument` in Anteprima, Pages, Word, TextEdit; testo AX della finestra e costo; OCR Vision della sola finestra (CPU); `AXSelectedText` alla copia; prompt "File e cartelle"; Accessibilità dopo una ricompilazione; `SMAppService` con firma ad-hoc. | Tabella con un esito letto per ogni sonda, ripetuta due volte, e una riserva per ogni esito negativo. |
| 1. Registratore minimo | App, titolo, documento, URL, inattività, filtri alla fonte, esclusioni scritte nel binario, pausa e menu, SQLite WAL, conservazione, salute, `installa.sh`. | Una tua giornata vera sotto i 5 MB senza testo, CPU media sotto l'1%. Veleno: login Safari, 1Password e incognito non lasciano tracce (la versione senza filtro va rossa). Zero rete. Kill -9 e riavvio entro 15 s (25/10: launchd aspetta 10 s fra due avvii, `ThrottleInterval`, e la misura dà 13 s; abbassarlo toglie il freno a un ciclo di crash). |
| 2. Segnali per i legami | Scorciatoie, menu, clic, appunti, FSEvents con inode e provenienza, etichette e valori dei campi redatti. | Scenario guidato (scarica PDF, apri, copia, incolla in un form, salva, rinomina) completo 3 volte su 3. Veleno: una password in un campo protetto non compare in nessun byte del database. |
| 3. Testo a schermo | Testo AX a budget, OCR come riserva, righe uniche zlib, delta, FTS5, redattore completo. | Tre giornate sotto i 20 MB medi. CPU sotto il 3% con OCR. `cerca` trova un numero visto una volta in un PDF scansionato. I 6 veleni del redattore (carta, IBAN, CF, `sk-`, JWT, OTP) escono in chiaro sulla versione senza redattore e mai sulla vera. |
| 4. Analisi e CLI | Episodi, simboli, legami (appunti, vita dei file, riuso di testo, stesso oggetto), n-gram, varianti, punteggio, livelli L0-L2, `verifica`, `mostra`, `raggiungo`, skill. | Registro sintetico con 3 routine piantate: tutte e 3 in testa. Precisione del legame appunti almeno 0,9. Un nome di cliente nel titolo non esce. `oggi --json` sotto 2000 token su una giornata vera. Test verdi con Python 3.8. |
| 5. Ponte Melchior | `conferma`, `rifiuta`, `automatizzata`, nota unica dei rifiuti, recall prima di proporre. | La nota passa `melchior-postwrite` e `memory-write-scanner` senza avvisi; un prompt con due trigger la porta su. Una routine rifiutata non torna dopo 7 giorni. |
| 6. Pilota | Tu per 3 giorni, poi una seconda persona per 3-5 giorni, poi una sessione guidata con la skill. | La seconda persona riconosce come vere almeno 3 routine, con le sue parole registrate. Mette in pausa ed esclude un'app senza aiuto. |
| 7. Aggancio ad Arturo | Fase facoltativa in `/setup` che lancia l'installatore del repo, aggancio in `/sparring`, sezione README. Su `dev` di Arturo, con la sua verifica. | `tests/verifica-allineamento.sh` di Arturo verde, telemetria invariata. |

Dimensione stimata: 2000 righe Swift, 2500 Python, 1500 di test.

## Passi che fai tu

- Fase 0 e 1: accendere l'interruttore Accessibilità (e Registrazione schermo per l'OCR) quando la finestra guidata lo chiede.
- Fase 6: tenere Lancillotto acceso 3 giorni di lavoro, poi installarlo da una seconda persona.

## Rischi e decisioni rinviate

- **Cifratura del registro**: nel pilota il registro è in chiaro, protetto da cartella 700, FileVault (l'installatore lo controlla), redazione alla fonte e conservazione breve. Un infostealer che gira come utente leggerebbe i testi redatti. La cifratura (CryptoKit con chiave nel Portachiavi, oppure SQLCipher) si decide dopo il pilota, quando il peso e l'uso reale sono misurati.
- **Uso in ufficio su dati di clienti e colleghi**: con il testo a schermo l'esenzione domestica del GDPR probabilmente non vale. Proposta: tu sul tuo Mac sì; nessun collega prima di un parere privacy scritto.
- App Electron e web con albero AX povero: lì interviene l'OCR, oppure i legami si fermano ad app e dominio, e l'output lo dichiara.
- Ogni ricompilazione del binario Swift chiede di riaccendere l'Accessibilità (firma ad-hoc).

## Verifica end-to-end

1. `bash tests/run.sh` (banchi Swift e Python, veleni con `gate-run.sh`) e `banco.sh` (zero rete) verdi.
2. Scenario guidato registrato dal vivo sul tuo Mac, poi `lancillotto catene --json` mostra la catena attesa.
3. Una giornata vera: `lancillotto stato` (peso, CPU, sensori sani) e `lancillotto mostra` aperta nel browser e guardata.
4. In una sessione Claude Code: "dove mi puoi aiutare oggi?" con la skill, risposta con routine provate da `conta` o `verifica`.
