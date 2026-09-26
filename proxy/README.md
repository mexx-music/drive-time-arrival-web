# DriveTimeArrival - Local Maps Proxy

This minimal Express proxy lets your Flutter Web app call Google Maps REST APIs from the browser by forwarding requests server-side. Use for local testing only.

## Requirements
- Node 16+ (or compatible)
- Set environment variable `GOOGLE_MAPS_API_KEY` before running

## Install

```bash
cd proxy
npm install
```

## Run

```bash
# set API key (bash)
export GOOGLE_MAPS_API_KEY="YOUR_SERVER_SIDE_KEY"
# start
node server.js
# or with nodemon for dev
npm run start:dev
```

## Endpoints
- POST /api/geocode
  - body: { "address": "Rotterdam, NL" }
  - forwards to Google Geocoding API and returns the JSON

- POST /api/directions
  - body: { "origin": "A", "destination": "B", "waypoints": ["X","Y"] }
  - forwards to Google Directions API and returns the JSON

- POST /api/autocomplete
  - body: { "input": "Rot" }
  - forwards server-side to Places API (New) Autocomplete

- GET /health
  - returns { ok: true }

## CORS allowlist
This proxy allows requests from:
- http://localhost
- http://127.0.0.1
- https://mexx-music.github.io

If you serve your web app at a different origin, update `allowedOrigins` in `server.js`.

## Telemetrie fuer das CatLab Control Center

Jeder tatsaechlich ausgefuehrte Google-Aufruf wird zusaetzlich als Ereignis in
der Control-Center-Datenbank vermerkt. Gespeichert wird ausschliesslich, DASS
ein Aufruf stattfand - nie, worum es ging. Keine Adressen, keine Suchtexte,
keine Koordinaten, keine IP.

Eingeschaltet wird sie allein ueber die Umgebungsvariable
`CONTROL_CENTER_DATABASE_URL` (Session-Pooler-Adresse des Supabase-Projekts).
Ist sie nicht gesetzt, verhaelt sich der Proxy exakt wie vorher. Optional:
`CONTROL_CENTER_POOL_MAX` (Vorgabe 2).

Die Kennung einer Routenberechnung (`cc_work_unit`) kommt von der App im
Anfragekoerper mit und wird hier gegen ein UUID-Muster geprueft. Sie wird
nicht an Google weitergereicht.

Tests:

```bash
docker run -d --name cc-test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=cc -p 55433:5432 postgres:17-alpine
# auth_stub.sql, alle Migrationen und die SQL-Tests einspielen:
PSQL="docker exec -i cc-test psql -U postgres -d cc" ../supabase/tests/run_local.sh
CONTROL_CENTER_TEST_URL="postgresql://postgres:test@127.0.0.1:55433/cc?sslmode=disable" npm test
```

Ohne `CONTROL_CENTER_TEST_URL` werden die Tests uebersprungen statt rot.

### Offene Architekturaufgabe: Telemetrie ist keine Abrechnungsgrundlage

Die Telemetrie ist bewusst best-effort gebaut. Sie darf die Routenberechnung
unter keinen Umstaenden stoeren, also wartet niemand auf den Schreibvorgang
und jeder Fehler endet still. Der Preis dafuer: **Ereignisse koennen verloren
gehen** - wenn Render den Prozess beendet, waehrend ein Schreibvorgang laeuft,
wenn die Datenbank kurz weg ist, oder waehrend der 60-Sekunden-Sperre nach
einem Fehler.

Fuer Beobachtung und Kostenschaetzung ist das richtig so: ein paar fehlende
Zeilen verfaelschen eine Groessenordnung nicht.

Fuer **Abrechnung und harte Kontingente** (Free / Pro / Business) reicht es
nicht. Wer auf diesen Zahlen abrechnet, rechnet zu wenig ab; wer darauf ein
Limit stuetzt, laesst mehr durch als erlaubt. Eine spaetere Limit-Schicht muss
deshalb anders gebaut sein:

* Sie prueft und bucht **bevor** der kostenpflichtige Anbieteraufruf freigegeben
  wird, nicht danach.
* Zaehlerstand und Freigabe muessen zusammen gelten - atomar, sonst laesst sich
  das Limit durch gleichzeitige Anfragen umgehen.
* Ein Fehler beim Buchen muss die Freigabe verweigern statt sie stillschweigend
  durchzulassen. Genau umgekehrt zur heutigen Telemetrie.

Die beiden Schichten koennen nebeneinander bestehen: die Telemetrie beobachtet
weiter, die Limit-Schicht entscheidet.

## Notes
- This is intended for local development and minimal testing. For production, deploy behind HTTPS, add proper auth, restrict your Google API key and add monitoring/rate limits as needed.
