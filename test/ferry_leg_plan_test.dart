import 'package:flutter_test/flutter_test.dart';

import 'package:driverroute_eta/logic/ferry_auto.dart';
import 'package:driverroute_eta/logic/ferry_leg_plan.dart';
import 'package:driverroute_eta/logic/truck_speed.dart';
import 'package:driverroute_eta/models/ferry_route.dart';

import 'helpers/fake_directions.dart';

/// Zeichnet auf, wie die Landwege abgefragt wurden.
class _FakeDet extends FerryAutoDetect {
  _FakeDet({this.failSecondLeg = false}) : super('');

  final bool failSecondLeg;
  final calls = <({String origin, String destination, bool avoidFerries})>[];

  @override
  Future<DirectionsFetchResult> fetchDirections({
    required String origin,
    required String destination,
    List<String> waypoints = const [],
    bool optimize = false,
    bool avoidFerries = false,
    bool alternatives = false,
  }) async {
    calls.add((
      origin: origin,
      destination: destination,
      avoidFerries: avoidFerries
    ));
    if (failSecondLeg && origin == 'Igoumenitsa') {
      return DirectionsFetchResult.error('ZERO_RESULTS');
    }
    // Leg A: Mailand → Bari, Leg B: Igoumenitsa → Athen
    final leg = origin == 'Igoumenitsa'
        ? [
            [39.50, 20.27],
            [38.00, 22.00],
            [37.98, 23.73],
          ]
        : [
            [45.46, 9.19],
            [42.50, 14.20],
            [41.12, 16.87],
          ];
    return DirectionsFetchResult.fromResponse(directionsResponse([
      [leg]
    ]));
  }
}

final ferry = FerryRoute(
  id: 'f',
  name: 'Bari–Igoumenitsa',
  from: 'Bari',
  to: 'Igoumenitsa',
  operators: const ['Test'],
  durationHours: 10,
  departuresLocal: const ['10:00'],
  tz: 'Europe/Rome',
  region: 'Test',
  active: true,
  notes: '',
);

void main() {
  test('holt beide Landwege ohne Fähre', () async {
    final det = _FakeDet();
    final plan = await FerryLegPlan.plan(
      origin: 'Mailand, Italien',
      destination: 'Athen, Griechenland',
      ferry: ferry,
      det: det,
    );

    expect(plan, isNotNull);
    expect(det.calls, hasLength(2));
    // Ohne avoid=ferries schmuggelt Google in die Anfahrt eigene Überfahrten.
    expect(det.calls.every((c) => c.avoidFerries), isTrue);
    expect(det.calls.first.destination, 'Bari');
    expect(det.calls.last.origin, 'Igoumenitsa');
  });

  test('Kilometer sind die Summe beider Landwege, ohne Seestrecke', () async {
    final plan = await FerryLegPlan.plan(
      origin: 'Mailand, Italien',
      destination: 'Athen, Griechenland',
      ferry: ferry,
      det: _FakeDet(),
    );
    expect(plan!.roadKm, closeTo(plan.legA.km + plan.legB.km, 0.01));
    // Die Häfen liegen an den Enden der Landwege – eigene Koordinaten
    // braucht es nicht.
    expect(plan.portFrom, plan.legA.points.last);
    expect(plan.portTo, plan.legB.points.first);
  });

  test('Etappen beider Landwege ergeben die LKW-Fahrzeit', () async {
    final plan = await FerryLegPlan.plan(
      origin: 'Mailand, Italien',
      destination: 'Athen, Griechenland',
      ferry: ferry,
      det: _FakeDet(),
    );
    final truck = truckDriveTimeFromSteps(
      steps: plan!.steps,
      totalKm: plan.roadKm,
    );
    expect(plan.steps.length,
        plan.legA.steps.length + plan.legB.steps.length);
    expect(truck.minutes, greaterThan(0));
    expect(truck.isComplete, isTrue);
  });

  test('scheitert ein Landweg, gibt es keinen halben Plan', () async {
    final plan = await FerryLegPlan.plan(
      origin: 'Mailand, Italien',
      destination: 'Athen, Griechenland',
      ferry: ferry,
      det: _FakeDet(failSecondLeg: true),
    );
    expect(plan, isNull);
  });
}
