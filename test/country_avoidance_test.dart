import 'package:flutter_test/flutter_test.dart';

import 'package:driverroute_eta/logic/country_avoidance.dart';
import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/services/country_geo.dart';

import 'helpers/fake_directions.dart';

/// Koordinaten der im Test benutzten Orte.
const muenchen = [48.137, 11.575];
const mailand = [45.464, 9.190];
const wien = [48.208, 16.373];
const thessaloniki = [40.640, 22.944];

/// Route München → Zürich → Lugano → Mailand (führt durch die Schweiz).
const durchSchweiz = [
  muenchen,
  [47.55, 9.68],
  [47.37, 8.54],
  [46.00, 8.95],
  mailand,
];

/// Route München → Innsbruck → Bozen → Verona → Mailand (Brenner, ohne CH).
const ueberBrenner = [
  muenchen,
  [47.263, 11.395],
  [46.50, 11.35],
  [45.44, 10.99],
  mailand,
];

List<double> _parse(String wp) {
  final p = wp.split(',');
  return [double.parse(p[0]), double.parse(p[1])];
}

/// Sehr einfacher "Router": verbindet Start, Wegpunkte und Ziel geradlinig.
/// Reicht aus, um die Ländersperre echt gegen die Grenzdaten zu testen.
Map<String, dynamic> _straightLine(
    List<double> origin, List<double> dest, List<String> waypoints) {
  final places = [origin, ...waypoints.map(_parse), dest];
  final legs = <List<List<double>>>[
    for (var i = 0; i < places.length - 1; i++) [places[i], places[i + 1]]
  ];
  return directionsResponse([legs]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CountryGeo.ensureLoaded());

  test('ohne Ländersperre wird genau einmal geroutet', () async {
    var calls = 0;
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async {
      calls++;
      return DirectionsFetchResult.fromResponse(
          directionsResponse([[durchSchweiz]]));
    });

    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {});

    expect(calls, 1);
    expect(plan.isClean, isTrue);
    expect(plan.autoDetours, isEmpty);
    expect(plan.effectiveWaypoints, isEmpty);
  });

  test('nimmt eine saubere Alternativroute ohne jeden Umfahrungspunkt',
      () async {
    var calls = 0;
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async {
      calls++;
      expect(alternatives, isTrue);
      return DirectionsFetchResult.fromResponse(
          directionsResponse([[durchSchweiz], [ueberBrenner]]));
    });

    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {'CH'});

    expect(calls, 1, reason: 'Alternativroute reicht, kein Extra-Routing');
    expect(plan.isClean, isTrue);
    expect(plan.autoDetours, isEmpty);
    expect(plan.countriesOnRoute.containsKey('CH'), isFalse);
  });

  test('erzeugt automatisch einen Umfahrungspunkt, wenn alle Varianten durch '
      'das gesperrte Land führen', () async {
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async {
      if (waypoints.isEmpty) {
        return DirectionsFetchResult.fromResponse(
            directionsResponse([[durchSchweiz]]));
      }
      return DirectionsFetchResult.fromResponse(
          _straightLine(muenchen, mailand, waypoints));
    });

    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {'CH'});

    expect(plan.ok, isTrue);
    expect(plan.stillBlocked, isEmpty);
    expect(plan.autoDetours, hasLength(1));
    expect(plan.effectiveWaypoints, hasLength(1));
    // Der Punkt wurde automatisch gefunden – er liegt auf Land und außerhalb CH.
    final p = plan.autoDetours.single;
    expect(CountryGeo.isOnLand(p), isTrue);
    expect(CountryGeo.countryAt(p), isNot('CH'));
    expect(plan.countriesOnRoute.containsKey('CH'), isFalse);
    // optimize darf mit automatischen Punkten nicht mehr aktiv sein
    expect(plan.optimizeAllowed, isFalse);
  });

  test('Wien → Thessaloniki meidet Serbien automatisch', () async {
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async =>
        DirectionsFetchResult.fromResponse(
            _straightLine(wien, thessaloniki, waypoints)));

    final plan = await planner.plan(
        origin: 'Wien', destination: 'Thessaloniki', avoided: const {'RS'});

    expect(plan.ok, isTrue);
    expect(plan.stillBlocked, isEmpty);
    expect(plan.countriesOnRoute.containsKey('RS'), isFalse);
    expect(plan.autoDetours, isNotEmpty);
    // Umfahrungspunkt muss auf Land und außerhalb Serbiens liegen.
    for (final p in plan.autoDetours) {
      expect(CountryGeo.isOnLand(p), isTrue);
      expect(CountryGeo.countryAt(p), isNot('RS'));
    }
  });

  test('berücksichtigt zwei gesperrte Länder gleichzeitig', () async {
    // Wien → Thessaloniki geradlinig führt durch Serbien und Nordmazedonien.
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async {
      return DirectionsFetchResult.fromResponse(
          _straightLine(wien, thessaloniki, waypoints));
    });

    final plan = await planner.plan(
      origin: 'Wien',
      destination: 'Thessaloniki',
      avoided: const {'RS', 'MK'},
    );

    expect(plan.ok, isTrue);
    expect(plan.stillBlocked, isEmpty,
        reason: 'weder Serbien noch Nordmazedonien dürfen übrig bleiben');
    expect(plan.countriesOnRoute.containsKey('RS'), isFalse);
    expect(plan.countriesOnRoute.containsKey('MK'), isFalse);
    expect(plan.autoDetours, isNotEmpty);
  });

  test('meldet ehrlich, wenn Start oder Ziel im gesperrten Land liegt',
      () async {
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async =>
        DirectionsFetchResult.fromResponse(
            _straightLine(muenchen, mailand, waypoints)));

    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {'IT'});

    expect(plan.status, 'BLOCKED_ENDPOINT');
    expect(plan.stillBlocked, contains('IT'));
    expect(plan.autoDetours, isEmpty);
    expect(plan.log.any((l) => l.contains('kann nicht umfahren werden')), isTrue);
  });

  test('Zwischenstopps des Fahrers bleiben erhalten und in Reihenfolge',
      () async {
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async {
      if (waypoints.length == 1) {
        // nur der Zwischenstopp → weiterhin durch die Schweiz
        return DirectionsFetchResult.fromResponse(directionsResponse([
          [
            [muenchen, [47.55, 9.68], [47.37, 8.54]],
            [[47.37, 8.54], [46.00, 8.95], mailand],
          ]
        ]));
      }
      final places = waypoints.map(_parse).toList();
      final legs = <List<List<double>>>[];
      var prev = muenchen;
      for (final p in places) {
        legs.add([prev, p]);
        prev = p;
      }
      legs.add([prev, mailand]);
      return DirectionsFetchResult.fromResponse(directionsResponse([legs]));
    });

    final plan = await planner.plan(
      origin: 'München',
      destination: 'Mailand',
      stops: const ['47.37,8.54'], // Zwischenstopp Zürich (als Koordinate)
      avoided: const {'CH'},
    );

    // Der Zwischenstopp liegt in der Schweiz → nicht umfahrbar, ehrliche Meldung.
    expect(plan.status, 'BLOCKED_ENDPOINT');
    expect(plan.effectiveWaypoints, contains('47.37,8.54'));
  });
}
