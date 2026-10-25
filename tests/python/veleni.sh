#!/usr/bin/env bash
# tests/python/veleni.sh: per ogni veleno di veleni.md, gate-run.sh prova che il test va rosso
# con il veleno (per il motivo atteso) e verde senza. Elenco e spiegazione in veleni.md.
#
# USO   bash tests/python/veleni.sh [NOME...]     (senza nomi: tutti)
# EXIT  0 tutti i veleni rossi per il motivo giusto e i test veri verdi, 1 altrimenti
set -uo pipefail

QUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RADICE="$(cd "$QUI/../.." && pwd)"
GATE_RUN="${GATE_RUN:-$HOME/.claude/scripts/gate-run.sh}"
PY="${PY:-python3}"
[[ -x "$GATE_RUN" ]] || { echo "manca $GATE_RUN"; exit 1; }

# nome|test|marcatore atteso nell'uscita del veleno
VELENI='
allowlist|test_uscita.TestUscita.test_nome_cliente_non_esce|nome cliente in uscita
domini|test_uscita.TestUscita.test_dominio_non_pubblico_e_app_fuori_elenco|portale-fornitori
app_nomi|test_uscita.TestUscita.test_dominio_non_pubblico_e_app_fuori_elenco|nome di app fuori elenco
appunti_cc|test_legami.TestLegami.test_incolla_senza_copia_nessun_legame_alto|incolla senza copia con legame
sfondo|test_legami.TestLegami.test_cambio_da_app_in_secondo_piano_sotto_mezzo|cambio dallo sfondo
lift|test_routine.TestRoutine.test_rumore_alternato_non_diventa_routine|rumore diventato routine
consenso_scadenza|test_consenso.TestConsenso.test_scaduto_negato|consenso scaduto accettato
consenso_intervallo|test_consenso.TestConsenso.test_fuori_intervallo_negato|consenso fuori intervallo accettato
segreti_l2|test_consenso.TestConsenso.test_con_clic_valido_testo_ripulito|chiave sk-ant uscita in L2
schema_versione|test_registro.TestRegistro.test_schema_piu_nuovo_errore_chiaro|schema 99 senza errore chiaro
registro_crea|test_registro.TestRegistro.test_registro_assente_dati_null_con_causa|la CLI ha creato il registro
authorizer|test_verifica.TestVerifica.test_rifiuta_attach_pragma_scritture_tabelle|SQL accettato e non doveva
dimentica|test_cancellazioni.TestCancellazioni.test_dimentica_cancella_l_intervallo|dimentica non ha cancellato
nota_controlli|test_melchior.TestMelchior.test_nessuna_nota_con_segnaposto_anche_se_lo_passa_claude|segnaposto in
yaml_virgolette|test_melchior.TestMelchior.test_nota_valida_senza_segnaposto|scalare senza virgolette dritte
rifiutate|test_routine.TestRoutine.test_rifiutata_non_torna|la routine rifiutata è tornata
inattivita|test_episodi.TestEpisodi.test_inattivita_taglia|non taglia
involucro|test_uscita.TestUscita.test_involucro_su_ogni_uscita_json|involucro mancante
tetto_token|test_uscita.TestUscita.test_tetto_dichiarato_quando_tronca|catene oltre il tetto
corse|test_cicli.TestCicli.test_ciclo_dentro_routine_resta_intero|ciclo spezzato
corse_sempre|test_cicli.TestCicli.test_due_volte_di_fila_restano_due|ripetizioni di fila contate una
ritorno|test_cicli.TestCicli.test_ritorno_sullo_stesso_documento_non_riapre|ritorno contato come apertura
navigazione|test_rumore.TestRumore.test_navigazione_non_diventa_routine|navigazione diventata routine
barriera|test_rumore.TestRumore.test_app_esclusa_spezza_lo_schema|app esclusa dentro una routine
file_programma|test_rumore.TestRumore.test_file_dei_programmi_fuori_dagli_episodi|file di un programma entrato
scartate|test_giudizio.TestGiudizio.test_non_compito_sparisce_e_torna_col_tempo_raddoppiato|la routine scartata è tornata
'

QUIETA="$(mktemp -d "${TMPDIR:-/tmp}/lancillotto-veleni.XXXXXX")"
export PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$QUI:$RADICE"
export LANCILLOTTO_DIR="$QUIETA/dati-vuoti"   # rete di sicurezza: i test usano comunque le loro cartelle
falliti=0 provati=0
while IFS='|' read -r nome test marcatore; do
  [[ -n "$nome" ]] || continue
  if (($#)) && [[ " $* " != *" $nome "* ]]; then continue; fi
  provati=$((provati + 1))
  ( cd "$QUIETA" && "$GATE_RUN" --poison "LANCILLOTTO_TEST_VELENO=$nome $PY -m unittest $test" \
      --expect "$marcatore" -- "$PY" -m unittest "$test" ) >"$QUIETA/$nome.log" 2>&1 </dev/null
  printf '%s\n' "$?" >"$QUIETA/$nome.rc"
  rc="$(<"$QUIETA/$nome.rc")"
  case "$rc" in
    0) printf '%-20s VERDE  veleno rosso per "%s", test vero verde\n' "$nome" "$marcatore" ;;
    *) printf '%-20s ROSSO  gate-run esce %s (log %s)\n' "$nome" "$rc" "$QUIETA/$nome.log"; falliti=$((falliti + 1)) ;;
  esac
done <<<"$VELENI"
echo "veleni provati: $provati, falliti: $falliti"
((falliti == 0)) && rm -rf "$QUIETA"
((falliti == 0))
