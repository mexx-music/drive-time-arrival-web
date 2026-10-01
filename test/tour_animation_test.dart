import 'dart:async';
import 'dart:convert';

import 'package:driverroute_eta/animation/country_borders.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/animation/tour_story.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/main.dart';
import 'package:driverroute_eta/services/maps_proxy.dart';
import 'package:driverroute_eta/tour/tour_scope.dart';
import 'package:driverroute_eta/ui/tour_animation_view.dart';
import 'package:driverroute_eta/ui/tour_story_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fake_directions.dart';

/// Ersatz-Proxy: zählt jeden Aufruf; liefert eine Route Lambach → Hamburg.
class _Proxy {
  final List<http.Request> requests = [];
  bool zeroResults = false;

  int get providerCalls => requests
      .where((r) => const {'/api/directions', '/api/geocode', '/api/autocomplete'}.contains(r.url.path))
      .length;

  http.Response _j(int s, Object? b) =>
      http.Response(jsonEncode(b), s, headers: {'content-type': 'application/json'});

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final p = r.url.path;
    final body = r.body.isEmpty ? <String, Object?>{} : jsonDecode(r.body) as Map<String, Object?>;
    if (p == '/api/geocode') {
      final a = (body['address'] as String? ?? '').toLowerCase();
      final (name, lat, lng) = a.contains('hamburg')
          ? ('Hamburg, Deutschland', 53.55, 9.99)
          : ('Lambach, Österreich', 48.09, 13.87);
      return _j(200, {
        'status': 'OK',
        'results': [
          {'formatted_address': name, 'geometry': {'location': {'lat': lat, 'lng': lng}}}
        ],
      });
    }
    if (p == '/api/autocomplete') return _j(200, {'suggestions': []});
    if (zeroResults) return _j(200, {'status': 'ZERO_RESULTS', 'routes': []});
    final pts = densify([[48.09, 13.87], [49.45, 11.08], [53.55, 9.99]], stepKm: 20);
    final resp = directionsResponse([
      [pts]
    ]);
    final route0 = Map<String, dynamic>.from((resp['routes'] as List).first as Map);
    route0['overview_polyline'] = {'points': encodePolyline(pts)};
    resp['routes'] = [route0];
    return _j(200, resp);
  }
}

List<LatLng> _line(LatLng a, LatLng b, int n) => [
      for (var i = 0; i < n; i++)
        LatLng(a.latitude + (b.latitude - a.latitude) * i / (n - 1),
            a.longitude + (b.longitude - a.longitude) * i / (n - 1)),
    ];


/// Zwei Testländer: AA westlich, BB östlich von Länge 1,0.
CountryIndex _squares() {
  List<int> enc(List<(double, double)> pts) {
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

  return CountryIndex.fromJson({
    'q': 10000,
    'countries': [
      for (final (iso, name, w, e) in [('AT', 'Österreich', 0.0, 1.0), ('DE', 'Deutschland', 1.0, 2.0)])
        {
          'iso': iso,
          'name': name,
          'polygons': [
            [enc([(w, 0.0), (e, 0.0), (e, 1.0), (w, 1.0)])]
          ],
        }
    ],
  });
}

void main() {
  double progressOf(WidgetTester tester) =>
      tester.widget<LinearProgressIndicator>(find.byKey(const Key('tour-progress'))).value!;
  String kmOf(WidgetTester tester) => tester.widget<Text>(find.byKey(const Key('tour-km'))).data!;

  // ========================================================= Ansicht allein
  group('Animationsansicht', () {
    final path = TourPath([
      TourLeg(points: _line(const LatLng(48.09, 13.87), const LatLng(53.55, 9.99), 2000)),
    ]);
    final total = tourAnimationDuration(path.totalMeters);

    Future<void> pumpView(WidgetTester tester,
        {bool autoplay = true, MapController? controller}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'Lambach → Hamburg',
          autoplay: autoplay,
          showTiles: false,
          mapController: controller,
        ),
      ));
      await tester.pump();
    }

    testWidgets('startet bei 0 %, fährt los und endet bei 100 % am Ziel', (tester) async {
      await pumpView(tester);
      expect(find.text('Lambach → Hamburg'), findsOneWidget);
      expect(progressOf(tester), 0);
      expect(kmOf(tester), startsWith('🚛 0 / '));

      await tester.pump(total ~/ 2);
      final mid = progressOf(tester);
      expect(mid, inExclusiveRange(0.2, 0.8));

      await tester.pump(total);
      await tester.pumpAndSettle();
      expect(progressOf(tester), 1);
      final km = (path.roadMeters / 1000).round();
      expect(kmOf(tester), '🚛 $km / $km km');
      expect(find.text('Start'), findsOneWidget); // am Ende wieder startbar
    });

    testWidgets('Pause hält an, Weiter setzt an derselben Stelle fort', (tester) async {
      await pumpView(tester);
      await tester.pump(total ~/ 4);
      await tester.tap(find.text('Pause'));
      await tester.pump();
      final paused = progressOf(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(progressOf(tester), paused);

      await tester.tap(find.text('Weiter'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(progressOf(tester), greaterThan(paused));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    testWidgets('Neustart beginnt wieder am Start', (tester) async {
      await pumpView(tester);
      await tester.pump(total ~/ 2);
      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    testWidgets('ohne Autostart: steht am Start, bis „Start“ gedrückt wird', (tester) async {
      await pumpView(tester, autoplay: false);
      await tester.pump(const Duration(seconds: 3));
      expect(progressOf(tester), 0);
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(progressOf(tester), greaterThan(0));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });

    group('Zoom', () {
      final auto = tourFollowZoom(path.totalMeters);
      bool autoActive(WidgetTester tester) =>
          tester.widget(find.byKey(const Key('tour-zoom-auto'))) is FilledButton;

      testWidgets('Standard: automatische Kameraführung folgt dem LKW', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        expect(autoActive(tester), isTrue);
        await tester.pump(total ~/ 3);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        final pos = path.atFraction(progressOf(tester));
        expect(map.camera.center.latitude, closeTo(pos.point.latitude, 1e-6));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('+ / −: Zoom bleibt beim Folgen erhalten, „Auto“ schaltet zurück', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.pump(total ~/ 5);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump();
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump();
        expect(autoActive(tester), isFalse);
        expect(map.camera.zoom, closeTo(auto + 2, 1e-9));

        // Weiterfahrt: Kamera folgt, Zoom des Nutzers bleibt.
        final before = map.camera.center;
        await tester.pump(total ~/ 5);
        expect(map.camera.zoom, closeTo(auto + 2, 1e-9));
        expect(map.camera.center, isNot(before));
        final pos = path.atFraction(progressOf(tester));
        expect(map.camera.center.latitude, closeTo(pos.point.latitude, 1e-6));

        await tester.tap(find.byTooltip('Weiter weg'));
        await tester.pump();
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9));

        await tester.tap(find.byKey(const Key('tour-zoom-auto')));
        await tester.pump();
        expect(autoActive(tester), isTrue);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        expect(progressOf(tester), lessThan(1)); // Animation lief weiter
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('Zoom per Geste (Mausrad) wird übernommen und beim Folgen beibehalten',
          (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.pump(total ~/ 5);
        final center = tester.getCenter(find.byType(FlutterMap));
        tester.binding.handlePointerEvent(PointerScrollEvent(
            position: center, scrollDelta: const Offset(0, -300)));
        await tester.pump();
        final chosen = map.camera.zoom;
        expect(chosen, greaterThan(auto + 0.1));
        expect(autoActive(tester), isFalse);
        await tester.pump(total ~/ 5);
        expect(map.camera.zoom, closeTo(chosen, 1e-9));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
      });

      testWidgets('Grenzen: weder zu nah noch zu weit, Knöpfe werden inaktiv', (tester) async {
        final map = MapController();
        await pumpView(tester, autoplay: false, controller: map);
        for (var i = 0; i < 20; i++) {
          final plus = tester.widget<IconButton>(
              find.ancestor(of: find.byIcon(Icons.add), matching: find.byType(IconButton)));
          if (plus.onPressed == null) break;
          await tester.tap(find.byTooltip('Näher heran'));
          await tester.pump();
        }
        expect(map.camera.zoom, tourMaxZoom);
        for (var i = 0; i < 20; i++) {
          final minus = tester.widget<IconButton>(
              find.ancestor(of: find.byIcon(Icons.remove), matching: find.byType(IconButton)));
          if (minus.onPressed == null) break;
          await tester.tap(find.byTooltip('Weiter weg'));
          await tester.pump();
        }
        expect(map.camera.zoom, tourMinZoom);
      });

      testWidgets('Pause, Neustart und Tempo bleiben mit manuellem Zoom unberührt', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump(total ~/ 4);
        await tester.tap(find.text('Pause'));
        await tester.pump();
        final paused = progressOf(tester);
        await tester.pump(const Duration(seconds: 3));
        expect(progressOf(tester), paused);
        await tester.tap(find.text('2×'));
        await tester.tap(find.text('Neustart'));
        await tester.pump();
        expect(progressOf(tester), lessThan(0.05));
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9)); // Wahl bleibt
        await tester.pump(total);
        await tester.pumpAndSettle();
        expect(progressOf(tester), 1);
      });

      testWidgets('am Ziel: „Auto“ zeigt wieder die ganze Tour', (tester) async {
        final map = MapController();
        await pumpView(tester, controller: map);
        await tester.tap(find.byTooltip('Näher heran'));
        await tester.pump(total * 2);
        await tester.pumpAndSettle();
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9)); // manuell: kein Übersichtssprung
        await tester.tap(find.byKey(const Key('tour-zoom-auto')));
        await tester.pump();
        // Übersicht über die ganze Tour: Mitte zwischen Start und Ziel.
        expect(autoActive(tester), isTrue);
        expect(map.camera.zoom, lessThan(auto + 0.5));
        final midLat = (path.start.latitude + path.end.latitude) / 2;
        expect(map.camera.center.latitude, closeTo(midLat, 0.3));
      });
    });

    testWidgets('Tempo 4× ist schneller als 1×', (tester) async {
      await pumpView(tester, autoplay: false);
      await tester.tap(find.text('4×'));
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.pump(total ~/ 8);
      final fast = progressOf(tester);
      await tester.tap(find.text('Neustart'));
      await tester.tap(find.text('1×'));
      await tester.pump();
      await tester.pump(total ~/ 8);
      expect(fast, greaterThan(progressOf(tester)));
      await tester.pump(total * 2);
      await tester.pumpAndSettle();
    });
  });


  // ============================================================== Story
  group('Tour-Story', () {
    setUpAll(() => initializeDateFormatting('de'));

    // ~178 km entlang Breite 0,5; Grenze AT→DE bei Länge 1,0 (Mitte).
    final path = TourPath([
      TourLeg(points: _line(const LatLng(0.5, 0.2), const LatLng(0.5, 1.8), 400)),
    ]);
    final t0 = DateTime(2026, 10, 1, 6, 0);
    // Fahrabschnitte mit Dauer (1 km/min), damit die Fahrzeit bekannt ist.
    EtaStep drive(double km) => EtaStep('',
        type: EtaEventType.drive,
        distanceKm: km,
        start: t0,
        end: t0.add(Duration(minutes: km.round())));
    final eta = EtaResult([
      drive(40),
      EtaStep('', type: EtaEventType.breakTime, start: t0, end: t0.add(const Duration(minutes: 45))),
      drive(60),
      EtaStep('',
          type: EtaEventType.dailyRest,
          start: t0.add(const Duration(hours: 9)),
          end: t0.add(const Duration(hours: 20))),
      drive(78),
      const EtaStep('', type: EtaEventType.destination),
    ], null);

    Future<void> pumpStory(WidgetTester tester,
        {MapController? controller, TourStoryMode mode = TourStoryMode.cinematic}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'Lambach → Hamburg',
          showTiles: false,
          eta: eta,
          countries: Future.value(_squares()),
          mapController: controller,
          storyMode: mode,
          fromName: 'Lambach',
          toName: 'Hamburg',
        ),
      ));
      await tester.pump(); // Grenzen „geladen“
      await tester.pump();
    }

    /// Fährt in 50-ms-Schritten, bis [key] sichtbar ist; liefert die Zeit.
    Future<Duration> until(WidgetTester tester, String key, {Duration max = const Duration(seconds: 90)}) async {
      var t = Duration.zero;
      while (find.byKey(Key(key)).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 50));
        t += const Duration(milliseconds: 50);
        if (t > max) fail('$key erscheint nicht');
      }
      return t;
    }

    /// Gefahrene km aus „🚛 40 / 178 km“.
    int kmAt(WidgetTester tester) =>
        int.parse(kmOf(tester).replaceAll('🚛 ', '').split(' / ').first.replaceAll('.', ''));

    double stripOpacity(WidgetTester tester, String key) =>
        tester.widget<Opacity>(find.byKey(Key(key))).opacity;

    /// Alle Texte, die gerade sichtbar sind (außer Bedienleiste unten).
    Set<String> texts(WidgetTester tester) => {
          for (final el in find.byType(Text).evaluate())
            if ((el.widget as Text).data != null) (el.widget as Text).data!,
        };

    /// Fährt in 50-ms-Schritten, bis [f] etwas findet; liefert die Zeit.
    Future<Duration> untilFound(WidgetTester tester, Finder f,
        {Duration max = const Duration(seconds: 90)}) async {
      var t = Duration.zero;
      while (f.evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 50));
        t += const Duration(milliseconds: 50);
        if (t > max) fail('$f erscheint nicht');
      }
      return t;
    }

    final border = find.byType(PolygonLayer); // Länderfläche beim Grenzwechsel

    testWidgets('Cinematic: kompakte Fahrleiste, keine Story-Texte, Abschluss am Ziel',
        (tester) async {
      final map = MapController();
      await pumpStory(tester, controller: map);
      final auto = tourFollowZoom(path.totalMeters);
      final hud = find.byKey(const Key('tour-hud'));
      final hudSize = tester.getSize(hud);
      expect(hudSize.height, lessThan(90)); // niedrige Leiste
      // Feste Texte der Ansicht (Bedienung, Kartenhinweis) – sonst nichts.
      final allowed = {
        'Lambach → Hamburg', 'Tour animieren', 'Pause', 'Weiter', 'Start', 'Neustart',
        '1×', '2×', '4×', 'Auto', '© OpenStreetMap-Mitwirkende', "Made with 'flutter_map'",
      };

      // Start: Österreich aktuell, Deutschland kommend.
      await tester.pump(const Duration(seconds: 1));
      expect(stripOpacity(tester, 'strip-0-AT'), 1);
      expect(stripOpacity(tester, 'strip-1-DE'), closeTo(0.28, 1e-9));

      // Bis kurz vor dem Ziel: nie ein Story-Text, keine Kamerabewegung,
      // Pause (km 40) und Tagesruhe (km 100) laufen unsichtbar mit.
      var sawBorder = false;
      while (progressOf(tester) < 0.97) {
        await tester.pump(const Duration(milliseconds: 50));
        final shown = texts(tester).where((t) => !t.startsWith('🚛') && !allowed.contains(t));
        expect(shown, isEmpty, reason: 'bei ${kmOf(tester)}');
        expect(find.byIcon(Icons.local_cafe), findsNothing);
        expect(find.byIcon(Icons.bedtime_outlined), findsNothing);
        expect(find.byIcon(Icons.wb_sunny_outlined), findsNothing);
        expect(map.camera.zoom, closeTo(auto, 1e-9));
        expect(tester.getSize(hud), hudSize);
        if (border.evaluate().isNotEmpty && !sawBorder) {
          sawBorder = true;
          expect(kmAt(tester), inInclusiveRange(89, 90)); // an der Grenze
        }
      }
      expect(sawBorder, isTrue);
      expect(stripOpacity(tester, 'strip-0-AT'), closeTo(0.5, 1e-9)); // durchfahren
      expect(stripOpacity(tester, 'strip-1-DE'), 1); // aktuell

      // Ziel: große Abschlussdarstellung ersetzt die Leiste.
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      await tester.pump(const Duration(seconds: 6));
      expect(progressOf(tester), 1);
      final card = find.byKey(const Key('story-arrival'));
      Finder inCard(Finder f) => find.descendant(of: card, matching: f);
      expect(inCard(find.text('TOUR ABGESCHLOSSEN')), findsOneWidget);
      expect(inCard(find.text('Lambach')), findsOneWidget);
      expect(inCard(find.text('Hamburg')), findsOneWidget);
      expect(inCard(find.text('178 km')), findsOneWidget);
      expect(inCard(find.text('2:58 h Fahrzeit · 2 Fahrtage')), findsOneWidget);
      expect(inCard(find.text('1 Lenkpause · 1 Tagesruhe')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('arrival-flags')), matching: find.byType(CountryFlag)),
          findsNWidgets(2)); // Länderfolge AT, DE
      expect(
          tester.widget<Opacity>(find.ancestor(of: hud, matching: find.byType(Opacity)).first).opacity,
          0); // Fahrleiste ausgeblendet
      await tester.pump(const Duration(seconds: 10));
      expect(card, findsOneWidget); // bleibt stehen
    });

    testWidgets('Simulation: vollständige Karten wie bisher (unverändert)', (tester) async {
      await pumpStory(tester, mode: TourStoryMode.simulation);

      await until(tester, 'story-break');
      expect(find.text('LENKPAUSE · 45 MIN'), findsOneWidget);
      expect(find.text('40 km gefahren'), findsOneWidget);
      expect(kmAt(tester), inInclusiveRange(40, 41));

      await until(tester, 'story-border');
      expect(find.text('Österreich'), findsOneWidget);
      expect(find.text('DEUTSCHLAND'), findsOneWidget);
      expect(find.byKey(const Key('flag-AT')), findsOneWidget);
      expect(find.byKey(const Key('flag-DE')), findsOneWidget);

      await until(tester, 'story-rest');
      expect(find.text('TAGESRUHE · 11:00 h'), findsOneWidget);
      expect(find.text('Tag 1 · 100 km'), findsOneWidget);
      await until(tester, 'story-next-day');
      expect(find.text('TAG 2'), findsOneWidget);
      expect(find.text('Weiterfahrt 02:00'), findsOneWidget);

      await until(tester, 'story-arrival');
      expect(find.text('ZIEL ERREICHT'), findsOneWidget);
      expect(find.text('178 km'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('Fahrzeug fährt durchgehend (auch an Pause, Grenze und Ruhe)', (tester) async {
      await pumpStory(tester);
      var last = progressOf(tester);
      while (progressOf(tester) < 0.97) {
        await tester.pump(const Duration(milliseconds: 250));
        expect(progressOf(tester), greaterThan(last));
        last = progressOf(tester);
      }
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('Länderfläche nur kurz hervorgehoben', (tester) async {
      await pumpStory(tester);
      await untilFound(tester, border);
      await tester.pump(const Duration(milliseconds: 1700));
      expect(border, findsNothing);
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('Neustart beginnt wieder im Startland', (tester) async {
      await pumpStory(tester);
      await untilFound(tester, border);
      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      expect(border, findsNothing);
      expect(stripOpacity(tester, 'strip-0-AT'), 1);
      expect(stripOpacity(tester, 'strip-1-DE'), closeTo(0.28, 1e-9));
      await untilFound(tester, border); // Grenze erneut
      await tester.pump(const Duration(seconds: 90));
      await tester.pumpAndSettle();
    });

    testWidgets('4× erreicht Grenze und Ziel schneller als 1×', (tester) async {
      await pumpStory(tester);
      final slow = await untilFound(tester, border);
      await tester.tap(find.text('Neustart'));
      await tester.tap(find.text('4×'));
      await tester.pump();
      final fast = await untilFound(tester, border);
      expect(fast.inMilliseconds, lessThan(slow.inMilliseconds / 3));
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      expect(find.text('1 Lenkpause · 1 Tagesruhe'), findsOneWidget); // gleiche Werte
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
    });

    testWidgets('Kamera: nur der LKW bestimmt sie; manueller Zoom bleibt fest', (tester) async {
      final map = MapController();
      await pumpStory(tester, controller: map);
      final auto = tourFollowZoom(path.totalMeters);
      await tester.tap(find.byTooltip('Näher heran'));
      await tester.pump();
      while (progressOf(tester) < 0.9) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(map.camera.zoom, closeTo(auto + 1, 1e-9));
      }
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
    });

    testWidgets('ohne Ländergrenzen (Datei fehlt): Fahrt und Abschluss trotzdem', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final load = Completer<CountryIndex>();
      await tester.pumpWidget(MaterialApp(
        home: TourAnimationView(
          path: path,
          title: 'x',
          showTiles: false,
          eta: eta,
          countries: load.future,
        ),
      ));
      load.completeError(StateError('weg'));
      await tester.pump();
      await tester.pump();
      await untilFound(tester, find.byKey(const Key('story-arrival')));
      expect(find.text('1 Lenkpause · 1 Tagesruhe'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    test('Story-Modus: nur das Ziel verlängert die Animation', () {
      final drive = tourAnimationDuration(path.totalMeters);
      final t = TourTimeline(path: path, drive: drive, events: storyFromEta(eta, path));
      final expected = drive + storyTiming(TourStoryKind.arrival).hold;
      expect(t.total.inMicroseconds, closeTo(expected.inMicroseconds, 1000)); // Rundung
    });
  });

  // ============================================================= in der App
  group('in der App', () {
    late _Proxy proxy;

    setUp(() {
      proxy = _Proxy();
      debugMapsDirectCallsAllowed = false;
      debugMapsProxyBase = 'https://proxy.test';
      debugMapsProxyClient = MockClient(proxy.handle);
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() {
      TourScope.exit();
      debugMapsDirectCallsAllowed = null;
      debugMapsProxyBase = null;
      debugMapsProxyClient = null;
    });

    Finder field(String label) =>
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);
    final animateButton = find.ancestor(
      of: find.text('Tour animieren'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const DriverRouteApp());
      await tester.pumpAndSettle();
      await tester.enterText(field('Start eingeben'), 'Lambach');
      await tester.enterText(field('Ziel eingeben'), 'Hamburg');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
    }

    Future<void> calculate(WidgetTester tester) async {
      final b = find.text('Route berechnen');
      await tester.ensureVisible(b);
      await tester.tap(b);
      await tester.pumpAndSettle();
    }

    testWidgets('vor der Berechnung: „Tour animieren“ ist aus', (tester) async {
      await pumpApp(tester);
      expect(tester.widget<OutlinedButton>(animateButton).onPressed, isNull);
    });

    testWidgets('komplette Animation samt Neustart: 0 zusätzliche Provider-Aufrufe', (tester) async {
      await pumpApp(tester);
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      expect(proxy.providerCalls, greaterThan(0));

      // Ländergrenzen vorab real laden (Datei-Lesen braucht echte Zeit);
      // die App bekommt beim Öffnen dieselbe, schon geladene Datei.
      await tester.runAsync(() => CountryIndex.load());

      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16)); // Seitenübergang
      final view = tester.widget<TourAnimationView>(find.byType(TourAnimationView));
      expect(view.title, 'Lambach → Hamburg');
      expect(view.path.legs.single.kind, TourLegKind.road);
      expect(view.eta, isNotNull); // Planung der Berechnung, nicht neu gerechnet

      // Die (schon geladene) Datei meldet sich in echter Zeit zurück.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Tour wird vorbereitet …'), findsNothing);

      // Bis zum Ziel fahren und dabei mitschreiben, welche Ereignisse kommen.
      final seen = <String>[];
      for (var i = 0; i < 2000 && progressOf(tester) < 1; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final now = [
          if (find.byType(PolygonLayer).evaluate().isNotEmpty) 'border',
          if (find.byKey(const Key('story-arrival')).evaluate().isNotEmpty) 'story-arrival',
        ];
        for (final k in now) {
          if (seen.isEmpty || seen.last != k) seen.add(k);
        }
      }
      await tester.pump(const Duration(seconds: 5));
      expect(progressOf(tester), 1);
      expect(seen, contains('border')); // Österreich → Deutschland
      expect(seen.last, 'story-arrival');
      expect(find.byType(PolygonLayer), findsNothing); // Hervorhebung vorbei
      expect(find.byKey(const Key('story-arrival')), findsOneWidget); // Ziel bleibt stehen

      await tester.tap(find.text('Neustart'));
      await tester.pump();
      expect(progressOf(tester), lessThan(0.05));
      expect(find.byKey(const Key('story-arrival')), findsNothing);
      await tester.tap(find.text('Pause'));
      await tester.pump();

      await tester.tap(find.byTooltip('Schließen'));
      await tester.pumpAndSettle();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(proxy.requests.length, afterCalc); // weder Maps noch sonst etwas
    });

    testWidgets('ohne Streckenführung (manuelle km): Hinweis statt Animation, kein Aufruf',
        (tester) async {
      await pumpApp(tester);
      proxy.zeroResults = true;
      await calculate(tester);
      final afterCalc = proxy.requests.length;
      await tester.ensureVisible(animateButton);
      await tester.tap(animateButton);
      await tester.pump();
      expect(find.byType(TourAnimationView), findsNothing);
      expect(find.textContaining('nicht animieren'), findsOneWidget);
      expect(proxy.requests.length, afterCalc);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
