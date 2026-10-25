---
name: Lancillotto
description: App della barra dei menu, famiglia di Arturo. Eredita il mondo della vista web di Arturo (arturo/bin/web/stile.css).
colors:
  tela: "#fefffc"
  carta: "#ffffff"
  lino: "#f9faf7"
  lino-forte: "#f1f3ef"
  inchiostro: "#171717"
  grafite: "#2c2c2c"
  cenere: "#646464"
  foschia: "#dee2de"
  notte: "#1f1f29"
  crepuscolo: "#282834"
  sera: "#2b6f9e"
  passa: "#2f7a4f"
  blocca: "#b2392b"
  stella: "#f2a24a"
colors-scuro:
  tela: "#1f1f29"
  carta: "#282834"
  lino: "#2c2d3a"
  lino-forte: "#343544"
  inchiostro: "#eef0ec"
  grafite: "#eef0ec"
  cenere: "#a9ada8"
  foschia: "#3b3c4a"
  sera: "#8cc4e6"
  passa: "#7dcca0"
  blocca: "#f0968a"
typography:
  titolo: "Sorts Mill Goudy 30pt, peso 400"
  titolo-sezione: "Sorts Mill Goudy 21pt"
  testo: "Atkinson Hyperlegible Next 14pt, interlinea 1.45"
  lead: "Atkinson Hyperlegible Next 16pt"
  meta: "Atkinson Hyperlegible Next 12pt, cenere"
  numeri: "Atkinson Hyperlegible Next, cifre tabellari"
rounded:
  foglio: 12
  riquadro-stato: 16
  pulsante: 8
  pillola: 50
---

# Lancillotto: il mondo visivo

Lancillotto eredita la vista web di Arturo, non la landing: è uno strumento d'uso (modalità Operate),
non una pagina che convince. Le regole che contano:

- **Carta e notte.** Fondo `tela` caldo e chiaro; in modo scuro la notte blu-viola di Arturo. Il modo
  lo sceglie macOS.
- **Un solo accento.** `sera` per pulsanti principali, collegamenti e focus. La `stella` arancione solo
  nel marchio, mai nell'interfaccia.
- **Esiti con bordo e testo.** Verde `passa`, rosso `blocca`: mai fondo pieno.
- **Titoli serif, testo umanista.** Sorts Mill Goudy per i titoli, Atkinson Hyperlegible Next per tutto
  il resto. Font OFL nel bundle (`registratore/Font/`), copiati da `arturo/bin/web/font/`.
- **Fogli quieti.** Bordo `foschia` sottile, raggio 12, ombra morbida a due strati. Gli elenchi stanno
  su filetti, non in riquadri. Un riquadro dentro un altro mai.
- **Un'azione per blocco.** Ogni sezione ha al più un pulsante pieno; il resto sono pulsanti a bordo o
  collegamenti. Bersagli di almeno 28 pt, focus visibile da tastiera.
- **Icone SF Symbols**, un solo peso. Niente emoji.
