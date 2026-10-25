# Lancillotto

## Cos'è

Un'app per macOS che sta nella barra dei menu e annota in locale come una persona lavora al Mac:
app, finestre, siti, file, legami di copia e incolla. Non registra video né tasti. Dopo qualche giorno
la persona chiede ad Arturo (Claude Code in italiano) "dove mi puoi aiutare?": Claude legge i riassunti,
capisce che lavoro fa e propone quali compiti può fare lui, provati con i numeri.

## Per chi

- Persone che conoscono l'IA ma non hanno mai usato un terminale, con qualunque lavoro d'ufficio.
- Primo pilota: una persona che non programma, sul suo Mac, durante la sua giornata di lavoro (Federico, 25/10/2026).
- Chi la installa non deve chiedere aiuto: una guida porta dai permessi alla prima domanda ad Arturo.

## Obiettivo

Recuperare informazioni sui flussi di lavoro quotidiani, per ottimizzare l'uso di Arturo e indicare
quali compiti si possono automatizzare (Federico, 25/10/2026). Lancillotto deve adattarsi a qualunque
lavoro: la taratura la fa Arturo leggendo i dati, non una configurazione.

## Vincoli che restano

- Il registro resta sul Mac. L'app nella barra dei menu non ha funzioni di rete.
- Il testo delle finestre è spento di base: lo accende la persona, con una scelta chiara.
- Fuori escono solo dati d'uso da un elenco chiuso, se la persona dice sì (telemetria).
- Italiano semplice, frasi corte, nessun gergo. Ogni controllo dice cosa fa.
- Uso quotidiano e discreto: l'app si apre poche volte, la guida una sola.

## Platform

macOS 13 o successivo, app nativa (SwiftUI dentro AppKit, barra dei menu). Firma locale ad-hoc.

## Brand

Famiglia di Arturo ("la stella dei naviganti"): Lancillotto ne prende la vista web come riferimento
visivo (`arturo/bin/web/stile.css`). Firma: Federico Nejrotti.
