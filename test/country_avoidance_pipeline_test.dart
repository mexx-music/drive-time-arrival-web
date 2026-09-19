import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:driverroute_eta/logic/country_avoidance.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/logic/tour_export.dart';
import 'package:driverroute_eta/services/country_geo.dart';
import 'package:driverroute_eta/widgets/tour_result_view.dart';

import 'helpers/fake_directions.dart';

const muenchen = [48.137, 11.575];
const mailand = [45.464, 9.190];

/// München → Zürich → Lugano → Mailand (durch die Schweiz).
const durchSchweiz = [
  muenchen,
  [47.55, 9.68],
  [47.37, 8.54],
  [46.00, 8.95],
  mailand,
];

List<double> _parse(String wp) {
  final p = wp.split(',');
  return [double.parse(p[0]), double.parse(p[1])];
}

Map<String, dynamic> _straightLine(List<String> waypoints) {
  final places = [muenchen, ...waypoints.map(_parse), mailand];
  return directionsResponse([
    [for (var i = 0; i < places.length - 1; i++) [places[i], places[i + 1]]]
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('de');
    await CountryGeo.ensureLoaded();
  });

  /// Diese Kette ist der eigentliche Knackpunkt: km der final validierten
  /// Umfahrungsroute müssen bis in ETA, Timeline und Export durchschlagen.
  /// Sonst hieße es "Karte = Umfahrung, ETA = ursprüngliche Route".
  testWidgets('Umfahrungsroute trägt bis in ETA, Timeline und Export',
      (tester) async {
    final planner = CountryAvoidancePlanner(fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) async =>
        DirectionsFetchResult.fromResponse(waypoints.isEmpty
            ? directionsResponse([[durchSchweiz]])
            : _straightLine(waypoints)));

    // 1) Planer: Route ohne Schweiz, mit automatischem Umfahrungspunkt.
    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {'CH'});
    expect(plan.stillBlocked, isEmpty);
    expect(plan.autoDetours, hasLength(1));
    expect(plan.countriesOnRoute.containsKey('CH'), isFalse);

    final detourKm = plan.route!.km;
    expect(detourKm, greaterThan(0));

    // 2) ETA: genau diese km werden als verifiedKm übernommen – ohne erneute,
    //    ungeprüfte Distanzabfrage.
    final eta = await FerryAutoDetect('').computeEtaWithOptionalFerry(
      startTime: DateTime(2026, 5, 4, 6),
      alreadyDrivenMin: 0,
      dutyOffsetMin: 0,
      avgKmh: 80,
      rules: const DriveRulesConfig(
        tenHourDay1: true,
        tenHourDay2: true,
        nineHourRest1: true,
        nineHourRest2: true,
        nineHourRest3: true,
        tankPause: false,
      ),
      startAddress: 'München',
      endAddress: 'Mailand',
      waypoints: plan.effectiveWaypoints,
      verifiedKm: detourKm,
    );
    expect(eta.summary, isNotNull);
    expect(eta.summary!.distanceKm, closeTo(detourKm, 0.01));

    final expectedKm = '${detourKm.toStringAsFixed(0)} km';

    // 3) Text-Export
    final text = TourExport.asText(
      result: eta,
      origin: 'München',
      destination: 'Mailand',
    );
    expect(text, contains(expectedKm));

    // 4) Timeline / Tour-Ansicht (Grundlage auch der Grafik)
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TourResultView(
            result: eta,
            origin: 'München',
            destination: 'Mailand',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining(expectedKm), findsWidgets);
  });

  test('ohne Sperre bleibt die ursprüngliche Route unverändert', () async {
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
      // Ohne Sperre werden keine Alternativrouten angefordert.
      expect(alternatives, isFalse);
      return DirectionsFetchResult.fromResponse(
          directionsResponse([[durchSchweiz]]));
    });

    final plan = await planner.plan(
        origin: 'München', destination: 'Mailand', avoided: const {});
    expect(calls, 1);
    expect(plan.autoDetours, isEmpty);
    expect(plan.effectiveWaypoints, isEmpty);
  });
}
