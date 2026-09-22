# CatLab API Control Center – Datenbankschema

Reines Schema. Es ist an keine laufende Anwendung angeschlossen; der
DriveTime-Proxy schreibt noch nichts hierher.

## Aufbau

| Datei | Inhalt |
|---|---|
| `migrations/…0001_cc_foundation.sql` | Einheiten, Pläne, Nutzer, Projekte, Anbieter, Leistungen, Preisliste, Freikontingente |
| `migrations/…0002_cc_usage.sql` | Sitzungen, Arbeitseinheiten, Verbrauchsereignisse (partitioniert), Zähler |
| `migrations/…0003_cc_billing.sql` | Rechnungsimporte, Rechnungsfakten, Abgleichssicht |
| `migrations/…0004_cc_settings.sql` | Projekt- und Leistungseinstellungen |
| `migrations/…0005_cc_seed_drivetime.sql` | Stammdaten DriveTime / Google Maps, bewusst ohne Preise |
| `tests/schema_test.sql` | 20 Prüfungen, läuft in einer Transaktion und macht sie am Ende rückgängig |

## Lokal ausführen

Wegwerfcontainer nur für den eigenen Rechner. Das Passwort unten ist kein
Zugangsdatum, sondern eine Vorgabe ohne Bedeutung; der Container wird danach
wieder entfernt.

```bash
docker run -d --name cc-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine
createdb -h localhost -p 55432 -U postgres controlcenter
for f in supabase/migrations/*.sql; do psql -h localhost -p 55432 -U postgres -d controlcenter -v ON_ERROR_STOP=1 -f "$f"; done
psql -h localhost -p 55432 -U postgres -d controlcenter -v ON_ERROR_STOP=1 -f supabase/tests/schema_test.sql
```

## Zwei Kostenzahlen, die nie addiert werden

* `cc.usage_events.cost_estimate` – eigene Schätzung, beim Buchen festgeschrieben.
* `cc.billing_facts.cost_actual` – was der Anbieter später tatsächlich berechnet hat.

`cc.v_reconciliation` stellt beide nebeneinander und bildet bewusst keine
gemeinsame Summe.

## Offene Entscheidungen

* Aufbewahrungsdauer der Verbrauchsereignisse. `cc.drop_usage_partition(date)`
  steht bereit, wird aber von nichts aufgerufen.
* Preise sind noch nicht eingetragen. Ohne Preis bleibt `cost_estimate` leer;
  Mengen werden trotzdem gezählt.
* Monatspartitionen reichen bis August 2027. `cc.ensure_usage_partition(date)`
  legt weitere an.

## Offene technische Aufgabe vor Produktionsbetrieb

Die Monatspartitionen von `cc.usage_events` sind bis **August 2027** vorbereitet.
Danach landet jede Buchung in der Auffangpartition `usage_events_default`.
Daten gehen dabei nicht verloren, aber die Auffangpartition wüchse unbegrenzt
und der Vorteil der Partitionierung – Abfragen auf einen Monat zu begrenzen und
alte Monate in einem Schritt zu löschen – ginge verloren.

Vor dem Produktionsbetrieb ist deshalb ein automatischer Mechanismus vorzusehen,
der rechtzeitig weitere Monate anlegt, etwa ein monatlicher Lauf von
`cc.ensure_usage_partition(current_date + interval '3 months')`. Ob das ein
Cron-Job, ein Supabase-Zeitplan oder ein Schritt beim Deployment wird, hängt
davon ab, wo die Datenbank am Ende läuft, und ist noch nicht entschieden.

Zur Kontrolle, wie weit die Partitionen reichen:

```sql
select max(c.relname) from pg_class c
  join pg_inherits i on i.inhrelid = c.oid
 where c.relkind = 'r' and i.inhparent = 'cc.usage_events'::regclass
   and c.relname ~ '^usage_events_[0-9]{6}$';
```
