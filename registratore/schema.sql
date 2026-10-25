-- Lancillotto: schema del registro, versione 1.
-- Lo crea il registratore Swift al primo avvio. Python lo legge, e scrive solo
-- per cancellare (dimentica, cancella-tutto, escludi retroattivo) e nella tabella consenso
-- (le richieste). Le regole d'uso di ogni colonna stanno in docs/CONTRATTO.md.
-- auto_vacuum va impostato prima di creare le tabelle: dopo non ha effetto.
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS meta(
  chiave TEXT PRIMARY KEY,
  valore TEXT
);

CREATE TABLE IF NOT EXISTS app(
  id INTEGER PRIMARY KEY,
  bundle TEXT UNIQUE NOT NULL,
  nome TEXT,
  esclusa INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS oggetto(
  id INTEGER PRIMARY KEY,
  tipo TEXT NOT NULL,          -- finestra | file | url
  chiave_h TEXT UNIQUE NOT NULL,
  etichetta TEXT,              -- titolo redatto, nome file, dominio+primo segmento
  dominio TEXT,
  ext TEXT,
  inode INTEGER,
  cartella TEXT,               -- download | documenti | scrivania | mail_allegati | altro
  provenienza TEXT             -- dominio da kMDItemWhereFroms
);

CREATE TABLE IF NOT EXISTS evento(
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,         -- millisecondi Unix
  dur_ms INTEGER NOT NULL DEFAULT 0,
  tipo TEXT NOT NULL,
  app_id INTEGER REFERENCES app(id),
  ogg_id INTEGER REFERENCES oggetto(id),
  dettaglio TEXT,              -- JSON compatto, forma per tipo in docs/CONTRATTO.md
  cc INTEGER,                  -- changeCount degli appunti al momento dell'evento
  tasti INTEGER,
  click INTEGER
);
CREATE INDEX IF NOT EXISTS evento_ts ON evento(ts);
CREATE INDEX IF NOT EXISTS evento_ogg ON evento(ogg_id, ts);
CREATE INDEX IF NOT EXISTS evento_tipo ON evento(tipo, ts);
CREATE INDEX IF NOT EXISTS evento_cc ON evento(cc) WHERE cc IS NOT NULL;

CREATE TABLE IF NOT EXISTS campo(
  evento_id INTEGER PRIMARY KEY REFERENCES evento(id) ON DELETE CASCADE,
  ruolo TEXT,
  etichetta TEXT,
  valore_z BLOB,               -- testo redatto, max 500 caratteri, DEFLATE raw
  lunghezza INTEGER,           -- lunghezza del valore originale in caratteri
  redazioni INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS riga(
  id INTEGER PRIMARY KEY,
  h TEXT UNIQUE NOT NULL,      -- primi 16 byte hex di SHA-256 della riga normalizzata
  testo_z BLOB NOT NULL,       -- riga redatta, DEFLATE raw
  lunghezza INTEGER NOT NULL,
  prima_ts INTEGER NOT NULL,
  ultima_ts INTEGER NOT NULL,
  volte INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS schermo(
  id INTEGER PRIMARY KEY,
  evento_id INTEGER REFERENCES evento(id) ON DELETE CASCADE,
  ts INTEGER NOT NULL,
  fonte TEXT NOT NULL,         -- ax | ocr
  finestra_id INTEGER REFERENCES oggetto(id),
  aggiunte TEXT NOT NULL,      -- JSON array di riga.id comparse rispetto allo snapshot precedente
  tolte TEXT NOT NULL,         -- JSON array di riga.id sparite
  n_righe INTEGER NOT NULL,
  troncato INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS schermo_ts ON schermo(ts);
CREATE INDEX IF NOT EXISTS schermo_finestra ON schermo(finestra_id, ts);

CREATE TABLE IF NOT EXISTS impronta(
  h TEXT NOT NULL,             -- HMAC-SHA256 hex (primi 16 byte) con la chiave locale
  tipo TEXT NOT NULL,          -- numero | iban | email | codice | parola_rara
  evento_id INTEGER NOT NULL REFERENCES evento(id) ON DELETE CASCADE,
  fonte TEXT NOT NULL          -- titolo | file | selezione | campo | schermo
);
CREATE INDEX IF NOT EXISTS impronta_h ON impronta(h);
CREATE INDEX IF NOT EXISTS impronta_evento ON impronta(evento_id);

CREATE TABLE IF NOT EXISTS salute(
  ts INTEGER NOT NULL,
  sensore TEXT NOT NULL,
  stato TEXT NOT NULL,         -- ok | degradato | spento | guasto
  dettaglio TEXT
);
CREATE INDEX IF NOT EXISTS salute_ts ON salute(ts);

CREATE TABLE IF NOT EXISTS giorno(
  data TEXT PRIMARY KEY,       -- AAAA-MM-GG ora locale
  eventi INTEGER NOT NULL DEFAULT 0,
  byte INTEGER NOT NULL DEFAULT 0,
  min_attivi INTEGER NOT NULL DEFAULT 0,
  min_pausa INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS consenso(
  id TEXT PRIMARY KEY,
  t0 INTEGER NOT NULL,
  t1 INTEGER NOT NULL,
  descrizione TEXT NOT NULL,   -- la compone la CLI dai dati (orari, app, righe), mai da testo di Claude
  richiesto_ts INTEGER NOT NULL,
  deciso INTEGER,              -- NULL in attesa, 1 sì, 0 no: lo scrive solo il registratore
  deciso_ts INTEGER,
  scade_ts INTEGER
);
