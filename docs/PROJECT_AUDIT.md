# DriveTimeArrival / DriverRoute ETA – Projektprüfung

Stand: 15. September 2026

## 1. Was bereits gut funktioniert

- Flutter-Anwendung mit Web-/PWA- und Desktop-/Mobile-Zielplattformen.
- Google-Directions-Anbindung mit Proxy-Fallback für Web, OSM-Kartenansicht und Adressauflösung.
- Lokaler Fährfahrplan mit automatischer Erkennung, manueller Auswahl und Abfahrtszeiten.
- Eingaben für Zwischenziel, Durchschnittsgeschwindigkeit, bereits gefahrene Zeit und bisherige Einsatzzeit.
- Geschwindigkeitsprofile für 80 km/h, 70 km/h bei viel Bundes-/Landstraße
  und 60 km/h für Norwegen sowie eine automatische Routenauswertung.
- Grundlegende Berücksichtigung von 9-/10-Stunden-Lenktagen und 9-/11-Stunden-Tagesruhe.
- Responsive Eingabekomponenten und ein Debugmodus für technische Hinweise.

## 2. Gefundene und behobene Probleme

- `alreadyDrivenMin` wurde zur noch zu fahrenden Zeit addiert. Dadurch wurde die ETA zu spät. Der Wert reduziert jetzt die noch verfügbare ununterbrochene und tägliche Lenkzeit, verlängert aber nicht die Reststrecke.
- `dutyTimeOffsetMin` verschob den Startzeitpunkt rückwärts. Der reale Tourstart bleibt jetzt unverändert; die bisherige Einsatzzeit begrenzt stattdessen das verbleibende Tagesfenster.
- Lenkpausen wurden gesammelt am Ende eines großen Fahrblocks addiert. Jetzt entstehen einzelne Fahrt- und Pausenereignisse an der tatsächlichen 4,5-Stunden-Grenze.
- Bei exakt erreichter Zielzeit wurde teilweise noch eine unnötige Pause addiert. Am Ziel wird keine nachträgliche Pause mehr geplant.
- Eine Fährabfahrt in der Vergangenheit konnte die Rechenuhr zurücksetzen. Sie wird jetzt auf die Hafenankunft begrenzt und als Hinweis markiert.
- Eine lange Fährfahrt setzte 10-Stunden- und 9-Stunden-Wochenkontingente zurück. Qualifizierende Ruhe setzt jetzt nur den Tageszustand zurück.
- Fährzeit wurde allein anhand ihrer Dauer als Ruhe anerkannt. Sie zählt jetzt nur, wenn Schlafkabine/Liegeplatz bestätigt ist.
- Fehlende Fährsegment-Distanzen wurden pauschal mit 500 km ersetzt. Die App zeigt nun einen verständlichen Fehler, statt eine scheinpräzise ETA zu erfinden.
- Die manuell eingegebene Ersatzdistanz ging in einem zweiten Distanzabruf verloren. Sie wird jetzt tatsächlich als Fallback verwendet.
- Der Standard-Zählertest aus dem Flutter-Template prüfte die App nicht und schlug zwangsläufig fehl. Er wurde durch fachliche ETA-Tests ersetzt.
- Ein echter Google-Maps-API-Schlüssel war in `lib/secrets.dart`, im
  Android-Manifest und in der iOS-Info.plist und damit in der Git-Historie
  gespeichert. Web, Android und iOS lesen ihn jetzt nur noch aus lokaler
  Build-Konfiguration; der offengelegte Schlüssel muss in der Google Cloud
  Console rotiert werden.

## 3. Noch fehlende oder fachlich offene Funktionen

- Vollständiger Wochen-/Zweiwochenzustand (56 Stunden pro Woche, 90 Stunden in zwei Wochen), reduzierte Wochenruhe und Ausgleichsruhe brauchen gespeicherte historische Daten und einen Kalenderbezug. Aktuell kann nur eine bereits fällige reguläre 45-Stunden-Wochenruhe eingeplant werden.
- Eine geteilte tägliche Ruhezeit (3 + 9 Stunden) ist noch nicht modelliert.
- Mehrfahrerbetrieb, Nachtarbeitsgrenzen, Arbeitszeitrecht, nationale Abweichungen und Sonderfälle nach Artikel 12 sind nicht Bestandteil der ETA-Engine.
- Der Fährsonderfall mit bis zu zwei Unterbrechungen, zusammen höchstens einer Stunde, braucht Eingaben für Einschiffung/Ausschiffung und Ruheart. Die jetzige Berechnung erkennt nur eine ununterbrochene Zeit an Bord mit bestätigter Schlafmöglichkeit an.
- Fährdaten enthalten derzeit nur eine Zeitzone pro Route. Abfahrts- und Ankunftshafen brauchen getrennte IANA-Zeitzonen, damit lokale Uhrzeiten und Sommerzeitwechsel zuverlässig dargestellt werden.
- Zwischenstopps beeinflussen die Routendistanz, haben aber noch keine eigene Aufenthaltsdauer und deshalb kein eigenes Timeline-Ereignis.
- Persistenz mit `shared_preferences` ist als Abhängigkeit vorhanden, wird für Tour- und Wochenzustand aber noch nicht konsequent eingesetzt.

## 4. UI-/UX-Verbesserungen

- Die Eingabeseite verwendet jetzt dieselbe moderne Kartenoptik, Farbwelt und
  visuelle Hierarchie wie die Ergebnisdarstellung.
- Auf Desktop und im Querformat stehen Planung und Tourübersicht in zwei
  unabhängig scrollbaren Spalten nebeneinander; vor der ersten Berechnung
  erklärt eine kompakte Vorschau, welche Ergebnisse dort erscheinen.
- Auf Smartphone und schmalen Fenstern bleibt die Bedienung einspaltig und wird
  auf eine gut lesbare maximale Breite begrenzt.
- Eigenes DriverRoute-App-Icon für PWA/Homescreen, Android, iOS, macOS und
  Windows statt der Flutter-Standardgrafik.
- Start und Ziel stapeln sich auf Smartphones und stehen auf breiten Ansichten nebeneinander.
- Die Ortsvorschläge laufen im Web über den geschützten Karten-Proxy; technische
  HTTP-Fehler werden nicht mehr als Meldung in der Fahreransicht gezeigt.
- Der Startort kann über `Meine Position` aus der Browser-/Geräteposition
  übernommen werden; die Zielsuche wird anschließend auf diesen Bereich
  gewichtet.
- Selten benötigte Eingaben sind eingeklappt; technische Fahrplanquellen erscheinen nur im Debugmodus.
- Nach der Berechnung steht zuerst eine Tourzusammenfassung mit Distanz, reiner Fahrzeit, Pausen/Ruhe und ETA.
- Der Tourablauf wird als typisierte Timeline mit Start, Fahrblöcken, Lenkpausen, Tankstopp, Tages-/Wochenruhe, Hafen, Wartezeit, Fähre und Ziel dargestellt.
- Fähren zeigen explizit, ob eine tägliche Ruhezeit erfüllt wurde.
- Der Berechnen-Button hat einen Ladezustand und verhindert Doppelberechnungen.
- Fehler werden als verständliche Meldungen ausgegeben; technische Details bleiben im Debugmodus.
- Tourergebnisse lassen sich als strukturierter Text über das System-Menü,
  WhatsApp, E-Mail oder die Zwischenablage exportieren.
- Debug-Schalter und technische Fahrplanprotokolle sind nur in
  Entwicklungs-Builds sichtbar und fehlen in der offiziellen Release-Version.

## 5. Überarbeitete Berechnungslogik

- Kontinuierliche Lenkzeit, tägliche Lenkzeit und bisherige Einsatzzeit sind getrennte Zustände.
- Die 45-Minuten-Pause wird nach spätestens 4,5 Stunden eingeplant; optional ist 15 + 30 Minuten in dieser Reihenfolge möglich.
- Ein 10-Stunden-Tag wird erst dann als verbraucht gezählt, wenn mehr als 9 Stunden gefahren werden.
- Tagesruhe setzt die Tageswerte zurück, nicht die wöchentlichen Ausnahme-Kontingente.
- Tankzeit wird konservativ als sonstige Arbeit behandelt und nicht automatisch als Lenkpause angerechnet.
- Alle sichtbaren Statuskarten werden aus derselben strukturierten Ereignisliste berechnet wie die Timeline.
- Im Automatikprofil wird jeder Google-Routenabschnitt anhand Distanz und
  Fahrtdauer ausgewertet. Daraus entstehen ein distanzgewichteter
  Planungsschnitt und eine sichtbare Schätzung des Anteils schneller,
  Haupt-/Bundesstraßen- und langsamer Abschnitte. Das funktioniert
  routenspezifisch auch in Norwegen, Bulgarien, Rumänien und Deutschland; eine
  Norwegen-Pauschale von 60 km/h greift nur ohne Routendaten. Der automatische
  Schnitt bleibt für die LKW-Planung auf höchstens 80 km/h begrenzt.
  Alternativ sind 80/70/60 km/h oder ein individueller Wert direkt wählbar.

## Fachliche Grundlage und Hinweis

Die implementierten Grundgrenzen orientieren sich an der Verordnung (EG) Nr. 561/2006 und den Erläuterungen der Europäischen Kommission:

- <https://eur-lex.europa.eu/eli/reg/2006/561/oj?locale=de>
- <https://transport.ec.europa.eu/transport-modes/road/social-provisions/driving-time-and-rest-periods_en>
- <https://transport.ec.europa.eu/transport-modes/road/mobility-package-i/driving-rest-times_en>

Die Anwendung ist eine Planungshilfe. Sie ersetzt keine Tachographenauswertung und keine rechtliche Prüfung des konkreten Einsatzes.
