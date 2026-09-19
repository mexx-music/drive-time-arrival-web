// ignore_for_file: avoid_print
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:driverroute_eta/logic/country_avoidance.dart';
import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/logic/ferry_route_suggester.dart';
import 'package:driverroute_eta/logic/tour_export.dart';
import 'package:driverroute_eta/models/ferry_route.dart';
import 'package:driverroute_eta/secrets.dart';
import 'package:driverroute_eta/services/country_geo.dart';
import 'package:driverroute_eta/services/distance_service.dart';
import 'package:driverroute_eta/services/ferry_schedule_loader.dart';
import 'package:driverroute_eta/utils/polyline.dart';

/// Praxistest gegen die echte Google-Directions-API.
///
/// Braucht einen Schlüssel und Netz, läuft deshalb NICHT im normalen
/// `flutter test` mit, sondern nur mit:
///   flutter test --dart-define=GOOGLE_MAPS_API_KEY=... test/live_country_avoidance_test.dart
const _live = Timeout(Duration(minutes: 5));

CountryAvoidancePlanner _planner() {
  final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
  return CountryAvoidancePlanner(
    fetch: ({
      required String origin,
      required String destination,
      List<String> waypoints = const [],
      bool optimize = false,
      bool avoidFerries = false,
      bool alternatives = false,
    }) =>
        det.fetchDirections(
          origin: origin,
          destination: destination,
          waypoints: waypoints,
          optimize: optimize,
          avoidFerries: avoidFerries,
          alternatives: alternatives,
        ),
  );
}

const _rules = DriveRulesConfig(
  tenHourDay1: true,
  tenHourDay2: true,
  nineHourRest1: true,
  nineHourRest2: true,
  nineHourRest3: true,
  tankPause: false,
);

String _countries(Map<String, double> km) {
  final e = km.entries.where((x) => x.value >= 4).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return e
      .map((x) => '${CountryGeo.nameOf(x.key)} ${x.value.toStringAsFixed(0)}km')
      .join(', ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test blockt echte HTTP-Aufrufe per HttpOverrides – für den
  // Live-Test aufheben.
  HttpOverrides.global = null;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('de');
    await CountryGeo.ensureLoaded();
  });

  test('LIVE Wien → Athen, Serbien gesperrt', () async {
    const origin = 'Wien, Österreich';
    const destination = 'Athen, Griechenland';

    // 1) Referenz OHNE Sperre
    final plain = await _planner()
        .plan(origin: origin, destination: destination, avoided: const {});
    expect(plain.ok, isTrue, reason: 'Referenzroute muss abrufbar sein');
    print('[ohne Sperre]  ${plain.route!.km.toStringAsFixed(0)} km · '
        '${(plain.route!.sec / 3600).toStringAsFixed(1)} h');
    print('[ohne Sperre]  Länder: ${_countries(plain.countriesOnRoute)}');

    // 2) Mit RS-Sperre
    final plan = await _planner()
        .plan(origin: origin, destination: destination, avoided: const {'RS'});
    for (final l in plan.log) {
      print('[log] $l');
    }
    expect(plan.ok, isTrue);
    expect(plan.stillBlocked, isEmpty, reason: 'RS muss aufgelöst sein');
    expect(plan.countriesOnRoute.containsKey('RS'), isFalse,
        reason: 'finale Route darf Serbien nicht berühren');
    print('[RS gesperrt]  ${plan.route!.km.toStringAsFixed(0)} km · '
        '${(plan.route!.sec / 3600).toStringAsFixed(1)} h');
    print('[RS gesperrt]  Länder: ${_countries(plan.countriesOnRoute)}');
    print('[RS gesperrt]  Wegpunkte: ${plan.effectiveWaypoints}');
    print('[RS gesperrt]  Umweg: '
        '+${(plan.route!.km - plain.route!.km).toStringAsFixed(0)} km');

    // 2b) Karte: main.dart übergibt overview_polyline GENAU dieser Route an
    //     die Kartenansicht – also muss auch sie serbienfrei sein.
    final mapPoints = decodePolyline(
        plan.route!.raw['overview_polyline']['points'] as String);
    expect(mapPoints.length, greaterThan(50));
    expect(CountryGeo.blockedCountriesOnPath(mapPoints, const {'RS'}), isEmpty,
        reason: 'gezeichnete Karte darf Serbien nicht berühren');
    print('[Karte] ${mapPoints.length} Punkte · '
        '${_countries(CountryGeo.kmPerCountry(mapPoints))}');

    // 3) Fährenlogik: greift diese Relation überhaupt?
    final supports = FerryRouteSuggester.supportsTrip(origin, destination);
    print('[Fähre] supportsTrip(Wien→Athen) = $supports');
    final (_, routes) = await FerryScheduleLoader.load();
    final suggestion = await FerryRouteSuggester.suggest(
      origin: origin,
      destination: destination,
      routes: routes,
      roadDistance: (a, b) =>
          const DistanceService().fetchKmDistance(origin: a, destination: b),
    );
    print('[Fähre] Vorschlag = ${suggestion?.route.name ?? 'keiner'}');
    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
    final ferryOnRoad = det.candidateHasFerry(plan.route!);
    print('[Fähre] Fähre in der Straßenroute erkannt = $ferryOnRoad');

    // 4) ETA aus GENAU dieser Route
    final eta = await det.computeEtaWithOptionalFerry(
      startTime: DateTime(2026, 5, 4, 6),
      alreadyDrivenMin: 0,
      dutyOffsetMin: 0,
      avgKmh: 80,
      rules: _rules,
      startAddress: origin,
      endAddress: destination,
      autoOrManualFerry: suggestion?.route,
      waypoints: plan.effectiveWaypoints,
      verifiedKm: plan.route!.km,
      ferryRoadKmBefore: suggestion?.kmBefore,
      ferryRoadKmAfter: suggestion?.kmAfter,
    );
    final s = eta.summary!;
    expect(s.distanceKm, closeTo(plan.route!.km, 0.01),
        reason: 'ETA muss die km der validierten Route benutzen');
    print('[ETA] ${s.distanceKm.toStringAsFixed(0)} km · '
        'Fahrt ${(s.drivingMinutes / 60).toStringAsFixed(1)} h · '
        'Pause ${s.breakMinutes} min · Ruhe ${s.restMinutes} min · '
        'Fähre ${s.ferryMinutes} min');
    print('[ETA] Ankunft ${eta.arrival}');

    // Fähren-km dürfen nicht als Straßen-km auftauchen
    expect(s.ferryMinutes, 0, reason: 'ohne Fähre keine Fährminuten');
    expect(s.distanceKm, lessThan(plan.route!.km + 1));

    // 5) Export benutzt dieselben Zahlen
    final text = TourExport.asText(
        result: eta, origin: origin, destination: destination);
    expect(text, contains('${s.distanceKm.toStringAsFixed(0)} km'));
    print('[Timeline] ${eta.steps.where((e) => !e.technical).length} Schritte');
    for (final step in eta.steps.where((e) => !e.technical).take(40)) {
      print('   • ${step.start} ${step.title ?? step.text}');
    }
  }, timeout: _live, skip: GOOGLE_MAPS_API_KEY.isEmpty);

  test('LIVE München → Mailand, Schweiz gesperrt', () async {
    const origin = 'München, Deutschland';
    const destination = 'Mailand, Italien';

    final plain = await _planner()
        .plan(origin: origin, destination: destination, avoided: const {});
    print('[ohne Sperre]  ${plain.route!.km.toStringAsFixed(0)} km · '
        'Länder: ${_countries(plain.countriesOnRoute)}');

    final plan = await _planner()
        .plan(origin: origin, destination: destination, avoided: const {'CH'});
    for (final l in plan.log) {
      print('[log] $l');
    }
    expect(plan.ok, isTrue);
    expect(plan.stillBlocked, isEmpty);
    expect(plan.countriesOnRoute.containsKey('CH'), isFalse,
        reason: 'finale Route darf die Schweiz nicht berühren');
    print('[CH gesperrt]  ${plan.route!.km.toStringAsFixed(0)} km · '
        'Länder: ${_countries(plan.countriesOnRoute)}');
    print('[CH gesperrt]  Wegpunkte: ${plan.effectiveWaypoints}');
    print('[CH gesperrt]  Umweg: '
        '+${(plan.route!.km - plain.route!.km).toStringAsFixed(0)} km');

    final mapPoints = decodePolyline(
        plan.route!.raw['overview_polyline']['points'] as String);
    expect(CountryGeo.blockedCountriesOnPath(mapPoints, const {'CH'}), isEmpty,
        reason: 'gezeichnete Karte darf die Schweiz nicht berühren');
    print('[Karte] ${mapPoints.length} Punkte · '
        '${_countries(CountryGeo.kmPerCountry(mapPoints))}');
  }, timeout: _live, skip: GOOGLE_MAPS_API_KEY.isEmpty);

  test('LIVE Fähre + Ländersperre: Mailand → Athen, Serbien gesperrt',
      () async {
    const origin = 'Mailand, Italien';
    const destination = 'Athen, Griechenland';
    const avoided = {'RS'};

    expect(FerryRouteSuggester.supportsTrip(origin, destination), isTrue,
        reason: 'diese Relation muss die Fährensuche auslösen');

    final (_, routes) = await FerryScheduleLoader.load();
    final suggestion = await FerryRouteSuggester.suggest(
      origin: origin,
      destination: destination,
      routes: routes,
      roadDistance: (a, b) =>
          const DistanceService().fetchKmDistance(origin: a, destination: b),
    );
    expect(suggestion, isNotNull, reason: 'Fähre muss vorgeschlagen werden');
    final FerryRoute ferry = suggestion!.route;
    print('[Fähre] ${ferry.name} (${ferry.from} → ${ferry.to}, '
        '${ferry.durationHours} h)');
    print('[Fähre] ungeprüft: vor ${suggestion.kmBefore.toStringAsFixed(0)} km, '
        'nach ${suggestion.kmAfter.toStringAsFixed(0)} km');

    // Genau das, was main.dart bei aktiver Sperre tut: beide Straßenabschnitte
    // einzeln gegen die Sperre prüfen.
    final before =
        await _planner().plan(origin: origin, destination: ferry.from, avoided: avoided);
    final after = await _planner()
        .plan(origin: ferry.to, destination: destination, avoided: avoided);
    expect(before.ok, isTrue);
    expect(after.ok, isTrue);
    expect(before.stillBlocked, isEmpty);
    expect(after.stillBlocked, isEmpty);
    expect(before.countriesOnRoute.containsKey('RS'), isFalse);
    expect(after.countriesOnRoute.containsKey('RS'), isFalse);
    print('[vor Fähre]  $origin → ${ferry.from}: '
        '${before.route!.km.toStringAsFixed(0)} km · '
        '${_countries(before.countriesOnRoute)}');
    print('[nach Fähre] ${ferry.to} → $destination: '
        '${after.route!.km.toStringAsFixed(0)} km · '
        '${_countries(after.countriesOnRoute)}');

    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
    final eta = await det.computeEtaWithOptionalFerry(
      startTime: DateTime(2026, 5, 4, 6),
      alreadyDrivenMin: 0,
      dutyOffsetMin: 0,
      avgKmh: 80,
      rules: _rules,
      startAddress: origin,
      endAddress: destination,
      autoOrManualFerry: ferry,
      ferryRoadKmBefore: before.route!.km,
      ferryRoadKmAfter: after.route!.km,
    );
    final s = eta.summary!;
    final roadKm = before.route!.km + after.route!.km;
    print('[ETA] Straße ${s.distanceKm.toStringAsFixed(0)} km · '
        'Fahrt ${(s.drivingMinutes / 60).toStringAsFixed(1)} h · '
        'Fähre ${s.ferryMinutes} min · Pause ${s.breakMinutes} min · '
        'Ruhe ${s.restMinutes} min · Warten ${s.waitingMinutes} min');
    print('[ETA] Ankunft ${eta.arrival}');

    // Die Seemeilen der Fähre dürfen NICHT als Straßen-km zählen.
    expect(s.distanceKm, closeTo(roadKm, 1.0),
        reason: 'Gesamt-km = nur die beiden geprüften Straßenabschnitte');
    expect(s.ferryMinutes, (ferry.durationHours * 60).round(),
        reason: 'Fährdauer als Zeit, nicht als Strecke');
    // Fahrzeit darf nur aus den Straßen-km stammen.
    expect(s.drivingMinutes, closeTo(roadKm / 80 * 60, 2.0));

    final text = TourExport.asText(
        result: eta, origin: origin, destination: destination);
    expect(text, contains('${s.distanceKm.toStringAsFixed(0)} km'));
    print('[Timeline]');
    for (final step in eta.steps.where((e) => !e.technical).take(40)) {
      print('   • ${step.start} ${step.title ?? step.text}');
    }
  }, timeout: _live, skip: GOOGLE_MAPS_API_KEY.isEmpty);
}
