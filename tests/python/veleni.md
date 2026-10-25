# Veleni dei test Python

Un test vale solo se diventa rosso su una versione rotta del codice. Ogni veleno qui sotto è una versione rotta di una funzione, messa al suo posto **solo dai test** con `unittest.mock` (tests/python/veleni.py). Il codice di produzione non legge mai la variabile.

## Come si applicano

- Un veleno: `LANCILLOTTO_TEST_VELENO=allowlist python3 -m unittest test_uscita.TestUscita.test_nome_cliente_non_esce`, con `PYTHONPATH=tests/python:.` dalla radice del repo. Il test deve uscire rosso con il motivo scritto nella colonna "Rosso perché".
- Tutti, con `~/.claude/scripts/gate-run.sh` (veleno prima, poi il test vero): `bash tests/python/veleni.sh`, oppure `bash tests/python/veleni.sh allowlist lift` per alcuni. Esce 0 solo se ogni veleno è rosso per il motivo atteso e ogni test vero è verde. Gira da una cartella temporanea vuota, come chiede gate-run.
- `Base.setUp` applica il veleno a ogni test: con la suite intera (`discover`) il veleno fa rossi anche altri test, e va bene così.

## Elenco

| Veleno | Cosa rompe | Test che diventa rosso | Rosso perché |
|---|---|---|---|
| `allowlist` | `pseudonimi.parola_ammessa` ammette ogni parola | `test_uscita.TestUscita.test_nome_cliente_non_esce` | "Rossi Impianti Srl" esce nei titoli: `nome cliente in uscita` |
| `domini` | `pseudonimi.dominio_pubblico` dichiara pubblico ogni dominio | `test_uscita.TestUscita.test_dominio_non_pubblico_e_app_fuori_elenco` | esce `portale-fornitori-acme.it` |
| `app_nomi` | `Pseudonimi.app` dà il nome dell'app così com'è | stesso test | esce "Gestionale Rossi Impianti": `nome di app fuori elenco` |
| `appunti_cc` | `legami.sorgente_appunti` lega l'incolla all'ultima copia, senza guardare il changeCount | `test_legami.TestLegami.test_incolla_senza_copia_nessun_legame_alto` | `incolla senza copia con legame ad alta confidenza` |
| `sfondo` | `legami.primo_piano` non sa mai quale app è in primo piano | `test_legami.TestLegami.test_cambio_da_app_in_secondo_piano_sotto_mezzo` | `cambio dallo sfondo con confidenza alta` |
| `lift` | `routine.LIFT = 0`: ogni arco del DFG vale | `test_routine.TestRoutine.test_rumore_alternato_non_diventa_routine` | l'alternanza di quattro app diventa routine: `rumore diventato routine` |
| `consenso_scadenza` | `registro.valuta_consenso` ignora `scade_ts` | `test_consenso.TestConsenso.test_scaduto_negato` | `consenso scaduto accettato` |
| `consenso_intervallo` | `registro.valuta_consenso` accetta un consenso valido per un altro intervallo | `test_consenso.TestConsenso.test_fuori_intervallo_negato` | `consenso fuori intervallo accettato` |
| `segreti_l2` | `segreti.redigi` non redige niente | `test_consenso.TestConsenso.test_con_clic_valido_testo_ripulito` | la chiave `sk-ant-` esce nel testo L2 |
| `schema_versione` | `registro.SCHEMA_SUPPORTATA = 999` | `test_registro.TestRegistro.test_schema_piu_nuovo_errore_chiaro` | `schema 99 senza errore chiaro` |
| `registro_crea` | `registro.apri` crea il file se manca | `test_registro.TestRegistro.test_registro_assente_dati_null_con_causa` | `la CLI ha creato il registro` |
| `authorizer` | `verifica.autorizza` ammette tutto | `test_verifica.TestVerifica.test_rifiuta_attach_pragma_scritture_tabelle` | `SQL accettato e non doveva` |
| `dimentica` | `registro.dimentica` non cancella niente | `test_cancellazioni.TestCancellazioni.test_dimentica_cancella_l_intervallo` | `dimentica non ha cancellato l'intervallo` |
| `nota_controlli` | `melchior.problemi_testo` e `melchior._controlla_nota` non controllano | `test_melchior.TestMelchior.test_nessuna_nota_con_segnaposto_anche_se_lo_passa_claude` | `segnaposto in pattern-lancillotto-...` |
| `yaml_virgolette` | `melchior._q` non mette le virgolette | `test_melchior.TestMelchior.test_nota_valida_senza_segnaposto` | `scalare senza virgolette dritte` (la descrizione contiene ": ") |
| `rifiutate` | `analisi.stato_effettivo` riporta ogni routine a proposta | `test_routine.TestRoutine.test_rifiutata_non_torna` | `la routine rifiutata è tornata` |
| `inattivita` | `episodi.INATTIVITA_MS` infinita | `test_episodi.TestEpisodi.test_inattivita_taglia` | `l'inattività oltre 5 minuti non taglia` |
| `involucro` | `uscita.involucro` toglie tipo e avviso | `test_uscita.TestUscita.test_involucro_su_ogni_uscita_json` | `involucro mancante` |
| `tetto_token` | `uscita.limita` non accorcia | `test_uscita.TestUscita.test_tetto_dichiarato_quando_tronca` | `catene oltre il tetto` |
| `corse` | `routine._corse_estese` non unisce mai le ripetizioni attaccate | `test_cicli.TestCicli.test_ciclo_dentro_routine_resta_intero` | la routine Mail > Anteprima > sei copia e incolla esce a pezzi: `ciclo spezzato` |
| `corse_sempre` | `routine._corse_estese` unisce sempre le ripetizioni attaccate, anche senza contorno comune | `test_cicli.TestCicli.test_due_volte_di_fila_restano_due` | una routine fatta due volte di fila conta una: `ripetizioni di fila contate una` |
| `ritorno` | `episodi.Contesto.ritorno` dice sempre di no | `test_cicli.TestCicli.test_ritorno_sullo_stesso_documento_non_riapre` | ogni ritorno su Anteprima diventa "apri allegato": `ritorno contato come apertura` |
| `navigazione` | `routine.e_lavoro` dice che ogni simbolo è lavoro | `test_rumore.TestRumore.test_navigazione_non_diventa_routine` | scheda nuova, Instagram e clic diventano routine: `navigazione diventata routine` |
| `barriera` | `routine.e_barriera` non ferma mai un n-gram | `test_rumore.TestRumore.test_app_esclusa_spezza_lo_schema` | Mail > app esclusa > Chrome diventa routine: `app esclusa dentro una routine` |
| `file_programma` | `episodi.Contesto.gesto_della_persona` dice sempre di sì | `test_rumore.TestRumore.test_file_dei_programmi_fuori_dagli_episodi` | i .pyc scritti dal Terminale prendono un simbolo: `file di un programma entrato` |
| `scartate` | `uscita.routine_righe` esclude solo le rifiutate | `test_giudizio.TestGiudizio.test_non_compito_sparisce_e_torna_col_tempo_raddoppiato` | la routine che Claude ha giudicato non-compito resta in elenco: `la routine scartata è tornata` |

Il test dei hook di Arturo (`test_melchior.TestMelchior.test_hook_di_arturo_non_segnalano`) ha la sua controprova dentro: la stessa nota con un token `ghp_` deve far parlare `memory-write-scanner.py`, altrimenti il silenzio di prima non prova niente.
