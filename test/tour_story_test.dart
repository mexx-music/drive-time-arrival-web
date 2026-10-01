import 'dart:convert';
import 'dart:io';

import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/ui/tour_story_overlay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

const _hav = Distance(calculator: Haversine());

/// Linie durch [via] mit Punkten etwa alle [stepKm] (wie eine Polyline).
List<LatLng> _route(List<LatLng> via, {double stepKm = 0.5}) {
  final out = <LatLng>[via.first];
  for (var i = 1; i < via.length; i++) {
    final a = via[i - 1], b = via[i];
    final n = (_hav(a, b) / 1000 / stepKm).ceil().clamp(1, 100000);
    for (var k = 1; k <= n; k++) {
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * k / n,
          a.longitude + (b.longitude - a.longitude) * k / n));
    }
  }
  return out;
}

TourPath _path(List<LatLng> via) => TourPath([TourLeg(points: _route(via))]);

/// Zwei Testländer: A westlich, B östlich von Länge 1,0.
CountryIndex _squares() => CountryIndex.fromJson({
      'q': 10000,
      'countries': [
        for (final (iso, w, e) in [('AA', 0.0, 1.0), ('BB', 1.0, 2.0)])
          {
            'iso': iso,
            'name': iso == 'AA' ? 'Land A' : 'Land B',
            'polygons': [
              [
                _enc([(w, 0.0), (e, 0.0), (e, 1.0), (w, 1.0)])
              ]
            ],
          }
      ],
    });

List<int> _enc(List<(double, double)> pts) {
  final out = <int>[];
  var lx = 0, ly = 0;
  for (final (x, y) in pts) {
    final qx = (x * 10000).round(), qy = (y * 10000).round();
    out
      ..add(qx - lx)
      ..add(qy - ly);
    lx = qx;
    ly = qy;
  }
  return out;
}

EtaStep _drive(double km) => EtaStep('', type: EtaEventType.drive, distanceKm: km);
EtaStep _rest(EtaEventType type, int minutes, DateTime start) => EtaStep('',
    type: type, start: start, end: start.add(Duration(minutes: minutes)));

void main() {
  late CountryIndex europe;

  setUpAll(() {
    europe = CountryIndex.fromJson(
        jsonDecode(File(CountryIndex.assetPath).readAsStringSync()) as Map<String, dynamic>);
  });

  // ============================================================ Länder
  group('Ländergrenzen (Natural Earth, deutsche Sicht)', () {
    test('bekannte Orte', () {
      expect(europe.countryAt(const LatLng(48.09, 13.87)), 'AT'); // Lambach
      expect(europe.countryAt(const LatLng(48.57, 13.43)), 'DE'); // Passau
      expect(europe.countryAt(const LatLng(47.14, 9.52)), 'LI'); // Vaduz
      expect(europe.countryAt(const LatLng(42.66, 21.16)), 'XK'); // Pristina
      expect(europe.countryAt(const LatLng(41.01, 28.98)), 'TR'); // Istanbul
      expect(europe.countryAt(const LatLng(51.13, 1.31)), 'GB'); // Dover
      expect(europe.countryAt(const LatLng(44.95, 34.10)), 'UA'); // Simferopol
      expect(europe.countryAt(const LatLng(42.5, 16.0)), isNull); // Adria
      expect(europe.byIso('DE')!.name, 'Deutschland');
      expect(europe.byIso('AT')!.name, 'Österreich');
    });
  });

  group('Grenzübertritte', () {
    test('AT → DE (Lambach → Passau → Nürnberg)', () {
      final path = _path(const [LatLng(48.09, 13.87), LatLng(48.57, 13.43), LatLng(49.45, 11.08)]);
      final c = detectBorderCrossings(path, europe);
      expect(c.map((x) => '${x.fromIso}→${x.toIso}'), ['AT→DE']);
      // Die Grenze (Inn bei Passau) liegt kurz vor Passau.
      final at = path.at(c.single.meters).point;
      expect(_hav(at, const LatLng(48.57, 13.43)) / 1000, lessThan(15));
    });

    test('mehrere Länder: Wien → Bratislava → Budapest → Belgrad', () {
      final path = _path(const [
        LatLng(48.21, 16.37), LatLng(48.15, 17.11), LatLng(47.50, 19.04), LatLng(44.79, 20.45)
      ]);
      expect(detectBorderCrossings(path, europe).map((x) => '${x.fromIso}→${x.toIso}'),
          ['AT→SK', 'SK→HU', 'HU→RS']);
    });

    test('kurze Durchfahrt: Salzburg → Bad Reichenhall → Lofer (Deutsches Eck)', () {
      final path = _path(const [LatLng(47.80, 13.04), LatLng(47.72, 12.88), LatLng(47.58, 12.69)]);
      expect(detectBorderCrossings(path, europe).map((x) => '${x.fromIso}→${x.toIso}'),
          ['AT→DE', 'DE→AT']);
    });

    test('Straße entlang der Grenze: kein Flattern', () {
      // Straße entlang der Grenze bei Länge 1,0: wechselt alle ~700 m die
      // Seite, je höchstens ~800 m in B – insgesamt 40 km an der Grenze.
      final via = <LatLng>[const LatLng(0.1, 0.995)];
      for (var i = 1; i <= 60; i++) {
        via.add(LatLng(0.1 + i * 0.006, i.isOdd ? 1.003 : 0.997));
      }
      final c = detectBorderCrossings(_path(via), _squares());
      expect(c, isEmpty);
    });

    test('echter Übertritt nach einem Grenzabschnitt wird erkannt', () {
      final via = <LatLng>[const LatLng(0.1, 0.995)];
      for (var i = 1; i <= 30; i++) {
        via.add(LatLng(0.1 + i * 0.006, i.isOdd ? 1.003 : 0.997));
      }
      via.add(const LatLng(0.5, 1.5)); // jetzt wirklich nach B
      final c = detectBorderCrossings(_path(via), _squares());
      expect(c.map((x) => '${x.fromIso}→${x.toIso}'), ['AA→BB']);
    });

    test('Ziel knapp hinter der Grenze zählt trotzdem', () {
      final c = detectBorderCrossings(
          _path(const [LatLng(0.5, 0.5), LatLng(0.5, 1.005)]), _squares());
      expect(c.single.toIso, 'BB');
    });

    test('Fähre: kein Land auf See, Übertritt erst im Ankunftsland', () {
      const igou = LatLng(39.50, 20.26);
      const bari = LatLng(41.13, 16.87);
      final path = TourPath([
        TourLeg(points: _route(const [LatLng(40.64, 22.94), igou])),
        const TourLeg(points: [igou, bari], kind: TourLegKind.ferry),
        TourLeg(points: _route(const [bari, LatLng(41.90, 12.50)])),
      ]);
      final c = detectBorderCrossings(path, europe);
      expect(c.map((x) => '${x.fromIso}→${x.toIso}'), ['GR→IT']);
      // Nicht schon über Apulien (die Seelinie streift Land), sondern in Bari.
      expect(_hav(path.at(c.single.meters).point, bari) / 1000, lessThan(10));
    });

    test('genau auf ~25 m bestimmt', () {
      final path = _path(const [LatLng(0.5, 0.2), LatLng(0.5, 1.8)]);
      final c = detectBorderCrossings(path, _squares()).single;
      expect(path.at(c.meters).point.longitude, closeTo(1.0, 0.0005));
    });
  });

  // =============================================================== ETA
  group('Story aus der ETA-Planung', () {
    final t0 = DateTime(2026, 10, 1, 6, 0);
    // 600 km: 270 km, Pause, 230 km, Tagesruhe 11 h, 100 km, Ziel.
    final eta = EtaResult([
      const EtaStep('', type: EtaEventType.start),
      _drive(270),
      _rest(EtaEventType.breakTime, 45, t0.add(const Duration(hours: 4, minutes: 30))),
      _drive(230),
      _rest(EtaEventType.dailyRest, 660, t0.add(const Duration(hours: 10))),
      _drive(100),
      const EtaStep('', type: EtaEventType.destination),
    ], null);
    final path = _path(const [LatLng(48.0, 10.0), LatLng(48.0, 18.06)]); // ~600 km

    test('Pause, Ruhe und Ziel an der richtigen Stelle und Reihenfolge', () {
      final s = storyFromEta(eta, path);
      expect(s.map((e) => e.kind),
          [TourStoryKind.break45, TourStoryKind.dailyRest, TourStoryKind.arrival]);
      expect(s[0].km, 270);
      expect(s[0].meters / path.totalMeters, closeTo(270 / 600, 1e-6));
      expect(s[0].duration, const Duration(minutes: 45));
      expect(s[1].km, 500);
      expect(s[1].meters / path.totalMeters, closeTo(500 / 600, 1e-6));
      expect(s[1].duration, const Duration(hours: 11));
      expect(s[1].day, 1);
      expect(s[1].dayKm, 500);
      expect(s[1].resumeAt, t0.add(const Duration(hours: 21)));
      expect(s[2].km, 600);
      expect(s[2].meters, path.totalMeters);
      expect(s[2].day, 2);
    });

    test('verkürzte Ruhe (9 h) und Wochenruhe: tatsächliche Dauer aus der Planung', () {
      final e = EtaResult([
        _drive(400),
        _rest(EtaEventType.dailyRest, 540, t0),
        _drive(300),
        _rest(EtaEventType.weeklyRest, 45 * 60, t0),
        _drive(100),
        const EtaStep('', type: EtaEventType.destination),
      ], null);
      final s = storyFromEta(e, path);
      expect(s[0].duration, const Duration(hours: 9));
      expect(s[1].duration, const Duration(hours: 45));
      expect(s[1].weekly, isTrue);
      expect(s[1].day, 2);
      expect(s[1].dayKm, 300);
    });

    test('Zusammenfassung: nur gezählte Planungsdaten', () {
      final e = EtaResult([
        EtaStep('', type: EtaEventType.drive, distanceKm: 300, start: t0,
            end: t0.add(const Duration(hours: 4, minutes: 30))),
        _rest(EtaEventType.breakTime, 45, t0),
        EtaStep('', type: EtaEventType.drive, distanceKm: 200, start: t0,
            end: t0.add(const Duration(hours: 3))),
        _rest(EtaEventType.dailyRest, 540, t0),
        EtaStep('', type: EtaEventType.drive, distanceKm: 100, start: t0,
            end: t0.add(const Duration(hours: 1, minutes: 14))),
        _rest(EtaEventType.weeklyRest, 45 * 60, t0),
        EtaStep('', type: EtaEventType.drive, distanceKm: 0, start: t0, end: t0),
        const EtaStep('', type: EtaEventType.destination),
      ], null);
      final story = storyFromEta(e, path);
      final sum = TourSummary.from(e, story, startIso: 'AT', endIso: 'DE');
      expect(sum.km, 600);
      expect(sum.driving, const Duration(hours: 8, minutes: 44));
      expect(sum.days, 3);
      expect(sum.breaks, 1);
      expect(sum.dailyRests, 1);
      expect(sum.weeklyRests, 1);
      expect((sum.startIso, sum.endIso), ('AT', 'DE'));
    });

    test('Fähre: Planungs-Kilometer überspringen die Seestrecke', () {
      final ferryPath = TourPath([
        TourLeg(points: _route(const [LatLng(48.0, 10.0), LatLng(48.0, 12.0)])), // ~149 km
        const TourLeg(points: [LatLng(48.0, 12.0), LatLng(48.0, 14.0)], kind: TourLegKind.ferry),
        TourLeg(points: _route(const [LatLng(48.0, 14.0), LatLng(48.0, 16.0)])),
      ]);
      final e = EtaResult([
        _drive(100),
        _rest(EtaEventType.breakTime, 45, t0),
        _drive(50),
        _drive(150),
        _rest(EtaEventType.breakTime, 45, t0),
        _drive(0),
        const EtaStep('', type: EtaEventType.destination),
      ], null);
      final s = storyFromEta(e, ferryPath);
      // Pause nach 100 von 300 Straßen-km: ein Drittel der Straße, vor der Fähre.
      expect(ferryPath.at(s[0].meters).roadMeters / ferryPath.roadMeters, closeTo(1 / 3, 1e-6));
      expect(ferryPath.at(s[0].meters).kind, TourLegKind.road);
      // Pause nach 300 km: am Ende, also nach der Seestrecke.
      expect(s[1].meters, greaterThan(ferryPath.totalMeters * 0.9));
    });

    test('Grenzen und ETA zusammen in Fahrtreihenfolge', () {
      final p = _path(const [LatLng(48.09, 13.87), LatLng(48.57, 13.43), LatLng(49.45, 11.08)]);
      final total = p.roadMeters / 1000;
      final e = EtaResult([
        _drive(total * 0.8),
        _rest(EtaEventType.breakTime, 45, t0),
        _drive(total * 0.2),
        const EtaStep('', type: EtaEventType.destination),
      ], null);
      final borders = storyFromBorders(detectBorderCrossings(p, europe), europe, p, etaDriveKm(e));
      final story = sortStory([...storyFromEta(e, p), ...borders]);
      expect(story.map((x) => x.kind),
          [TourStoryKind.borderCrossing, TourStoryKind.break45, TourStoryKind.arrival]);
      expect(story.first.fromName, 'Österreich');
      expect(story.first.toName, 'Deutschland');
      expect(story.first.km, inExclusiveRange(0, total));
    });
  });

  // ========================================================= Zeitleiste
  group('Zeitleiste', () {
    final path = _path(const [LatLng(48.0, 10.0), LatLng(48.0, 18.06)]);
    const drive = Duration(seconds: 20);
    TourStoryEvent ev(TourStoryKind k, double f) =>
        TourStoryEvent(kind: k, meters: f * path.totalMeters, km: f * 600);

    test('ohne Ereignisse: genau die bisherige Animation', () {
      final t = TourTimeline(path: path, drive: drive);
      expect(t.total, drive);
      for (var i = 0; i <= 20; i++) {
        final at = Duration(seconds: i);
        expect(t.frameAt(at).meters,
            closeTo(tourEase(i / 20) * path.totalMeters, 1e-6));
      }
    });

    test('Simulationsmodus: Fahrzeug hält an der Pause, danach geht es weiter', () {
      final pause = ev(TourStoryKind.break45, 0.5);
      const sim = TourStoryMode.simulation;
      final t = TourTimeline(path: path, drive: drive, events: [pause], mode: sim);
      final hold = storyTiming(TourStoryKind.break45, mode: sim).hold;
      expect(t.total, drive + hold);
      // Zeitpunkt des Erreichens suchen
      var reach = Duration.zero;
      while (t.frameAt(reach).meters < pause.meters - 1) {
        reach += const Duration(milliseconds: 10);
      }
      final a = t.frameAt(reach + const Duration(milliseconds: 100));
      final b = t.frameAt(reach + hold - const Duration(milliseconds: 100));
      expect(a.holding, isTrue);
      expect(a.event, same(pause));
      expect(a.meters, closeTo(pause.meters, 1e-6));
      expect(b.meters, closeTo(pause.meters, 1e-6)); // steht
      final c = t.frameAt(reach + hold + const Duration(seconds: 1));
      expect(c.holding, isFalse);
      expect(c.meters, greaterThan(pause.meters));
    });

    test('Simulationsmodus: Grenze mit kurzem Halt, Einblendung bleibt danach sichtbar', () {
      final border = ev(TourStoryKind.borderCrossing, 0.3);
      const sim = TourStoryMode.simulation;
      final t = TourTimeline(path: path, drive: drive, events: [border], mode: sim);
      final timing = storyTiming(TourStoryKind.borderCrossing, mode: sim);
      var reach = Duration.zero;
      while (t.frameAt(reach).meters < border.meters - 1) {
        reach += const Duration(milliseconds: 10);
      }
      final after = t.frameAt(reach + timing.hold + const Duration(milliseconds: 500));
      expect(after.holding, isFalse);
      expect(after.event, same(border));
      expect(after.meters, greaterThan(border.meters));
      expect(t.frameAt(reach + timing.show + const Duration(milliseconds: 50)).event, isNull);
    });

    test('mehrere Ereignisse nacheinander, Ziel bleibt am Ende stehen', () {
      final events = [
        ev(TourStoryKind.dailyRest, 0.8),
        ev(TourStoryKind.borderCrossing, 0.2),
        ev(TourStoryKind.break45, 0.45),
        TourStoryEvent(kind: TourStoryKind.arrival, meters: path.totalMeters, km: 600),
      ];
      List<TourStoryKind> seenIn(TourTimeline t) {
        final seen = <TourStoryKind>[];
        for (var ms = 0; ms <= t.total.inMilliseconds + 2000; ms += 50) {
          final k = t.frameAt(Duration(milliseconds: ms)).event?.kind;
          if (k != null && (seen.isEmpty || seen.last != k)) seen.add(k);
        }
        return seen;
      }

      // Simulation: alle Ereignisse.
      expect(
          seenIn(TourTimeline(
              path: path, drive: drive, events: events, mode: TourStoryMode.simulation)),
          [
            TourStoryKind.borderCrossing,
            TourStoryKind.break45,
            TourStoryKind.dailyRest,
            TourStoryKind.arrival,
          ]);
      // Cinematic: unterwegs nur der Länderwechsel, dann das Ziel.
      final t = TourTimeline(path: path, drive: drive, events: events);
      expect(seenIn(t), [TourStoryKind.borderCrossing, TourStoryKind.arrival]);
      final end = t.frameAt(t.total + const Duration(seconds: 10));
      expect(end.meters, path.totalMeters);
      expect(end.event!.kind, TourStoryKind.arrival);
    });

    test('Story-Modus (Standard): kein Halt; unterwegs nur der Länderwechsel', () {
      final events = [
        ev(TourStoryKind.borderCrossing, 0.2),
        ev(TourStoryKind.break45, 0.45),
        ev(TourStoryKind.dailyRest, 0.7),
        TourStoryEvent(kind: TourStoryKind.arrival, meters: path.totalMeters, km: 600),
      ];
      final t = TourTimeline(path: path, drive: drive, events: events);
      expect(t.mode, TourStoryMode.cinematic);
      // Nur das Ziel verlängert die Animation; unterwegs keine Haltezeit.
      expect(t.total, drive + storyTiming(TourStoryKind.arrival).hold);
      var last = -1.0;
      final seen = <TourStoryKind>{};
      for (var ms = 0; ms < drive.inMilliseconds - 100; ms += 50) {
        final f = t.frameAt(Duration(milliseconds: ms));
        expect(f.holding, isFalse);
        if (ms > 0) expect(f.meters, greaterThan(last)); // fährt ununterbrochen
        last = f.meters;
        if (f.event != null) seen.add(f.event!.kind);
      }
      expect(seen, {TourStoryKind.borderCrossing}); // Pause und Ruhe nicht im Bild …
      expect(t.events.where((e) => e.kind == TourStoryKind.break45), hasLength(1)); // … aber in den Daten
      expect(t.events.where((e) => e.kind == TourStoryKind.dailyRest), hasLength(1));
      // Fahrt identisch zur Animation ohne Story.
      final plain = TourTimeline(path: path, drive: drive);
      for (var s = 0; s < 20; s++) {
        expect(t.frameAt(Duration(seconds: s)).meters,
            closeTo(plain.frameAt(Duration(seconds: s)).meters, 1e-6));
      }
    });

    test('Story-Modus: Einblendung beginnt genau an der Ereignisstelle', () {
      final pause = ev(TourStoryKind.borderCrossing, 0.5);
      final t = TourTimeline(path: path, drive: drive, events: [pause]);
      var first = -1.0;
      for (var ms = 0; ms <= drive.inMilliseconds; ms += 10) {
        final f = t.frameAt(Duration(milliseconds: ms));
        if (f.event != null) {
          first = f.meters;
          break;
        }
      }
      expect(first, greaterThanOrEqualTo(pause.meters - 1));
      expect(first - pause.meters, lessThan(path.totalMeters * 0.002)); // < 1 Bild
    });

    test('Story-Modus: am Ziel endet die Bewegung, die Abschlusskarte bleibt', () {
      final t = TourTimeline(path: path, drive: drive, events: [
        TourStoryEvent(kind: TourStoryKind.arrival, meters: path.totalMeters, km: 600),
      ]);
      final atEnd = t.frameAt(drive + const Duration(milliseconds: 500));
      expect(atEnd.meters, path.totalMeters);
      expect(atEnd.event!.kind, TourStoryKind.arrival);
      expect(t.frameAt(t.total + const Duration(minutes: 1)).event!.kind, TourStoryKind.arrival);
    });

    test('Fahrt ist monoton – nie rückwärts (beide Modi)', () {
      for (final mode in TourStoryMode.values) {
        final t = TourTimeline(path: path, drive: drive, mode: mode, events: [
          ev(TourStoryKind.borderCrossing, 0.1),
          ev(TourStoryKind.break45, 0.4),
          ev(TourStoryKind.dailyRest, 0.7),
        ]);
        var last = -1.0;
        for (var ms = 0; ms <= t.total.inMilliseconds; ms += 20) {
          final m = t.frameAt(Duration(milliseconds: ms)).meters;
          expect(m, greaterThanOrEqualTo(last));
          last = m;
        }
      }
    });

    test('Fahrt ist monoton – nie rückwärts', () {
      final t = TourTimeline(path: path, drive: drive, events: [
        ev(TourStoryKind.borderCrossing, 0.1),
        ev(TourStoryKind.break45, 0.4),
        ev(TourStoryKind.dailyRest, 0.7),
      ]);
      var last = -1.0;
      for (var ms = 0; ms <= t.total.inMilliseconds; ms += 20) {
        final m = t.frameAt(Duration(milliseconds: ms)).meters;
        expect(m, greaterThanOrEqualTo(last));
        last = m;
      }
    });
  });

  group('Statusleiste (Cinematic)', () {
    TourStoryEvent border(double m, String from, String to) => TourStoryEvent(
        kind: TourStoryKind.borderCrossing, meters: m, km: m / 1000, fromIso: from, toIso: to);
    TourStoryEvent rest(double m, int day) =>
        TourStoryEvent(kind: TourStoryKind.dailyRest, meters: m, km: m / 1000, day: day);
    final events = [
      border(1000, 'TR', 'GR'),
      const TourStoryEvent(kind: TourStoryKind.break45, meters: 1500, km: 1.5),
      rest(2000, 1),
      border(3000, 'GR', 'BG'),
    ];

    test('Länderfolge: Start an der Küste (unbekannt) → erstes Herkunftsland', () {
      expect(storyCountrySequence(events, null), ['TR', 'GR', 'BG']);
      expect(storyCountrySequence(events, 'TR'), ['TR', 'GR', 'BG']);
      expect(storyCountrySequence(const [], null), isEmpty);
    });

    test('aktuelles Land nach Strecke', () {
      expect(storyCountryIndexAt(events, 500), 0);
      expect(storyCountryIndexAt(events, 1000), 1);
      expect(storyCountryIndexAt(events, 5000), 2);
    });

    test('Cinematic: Pause und Ruhe erscheinen nie, Kamera ohne Story-Bewegung', () {
      final path = _path(const [LatLng(48.0, 10.0), LatLng(48.0, 18.06)]);
      final t = TourTimeline(path: path, drive: const Duration(seconds: 20), events: [
        TourStoryEvent(kind: TourStoryKind.break45, meters: path.totalMeters * 0.3, km: 1),
        TourStoryEvent(kind: TourStoryKind.dailyRest, meters: path.totalMeters * 0.6, km: 2, day: 1),
      ]);
      for (var ms = 0; ms <= t.total.inMilliseconds; ms += 20) {
        final f = t.frameAt(Duration(milliseconds: ms));
        expect(f.event, isNull);
        expect(storyZoomOffset(f), 0);
      }
      // Simulation zeigt beide und bewegt die Kamera wie bisher.
      final sim = TourTimeline(
          path: path,
          drive: const Duration(seconds: 20),
          mode: TourStoryMode.simulation,
          events: t.events);
      final kinds = <TourStoryKind>{};
      var moved = false;
      for (var ms = 0; ms <= sim.total.inMilliseconds; ms += 20) {
        final f = sim.frameAt(Duration(milliseconds: ms));
        if (f.event != null) kinds.add(f.event!.kind);
        if (storyZoomOffset(f, mode: TourStoryMode.simulation) != 0) moved = true;
      }
      expect(kinds, {TourStoryKind.break45, TourStoryKind.dailyRest});
      expect(moved, isTrue);
    });
  });
}
