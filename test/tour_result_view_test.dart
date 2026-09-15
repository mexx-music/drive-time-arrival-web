import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/speed_profile.dart';
import 'package:driverroute_eta/widgets/tour_result_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
  });

  EtaResult exampleResult() => EtaCalculator.compute(
        start: DateTime(2026, 3, 16, 6),
        alreadyDrivenMin: 0,
        dutyTimeOffsetMin: 0,
        km: 850,
        avgKmh: 80,
        rules: const DriveRulesConfig(
          tenHourDay1: true,
          tenHourDay2: true,
          nineHourRest1: true,
          nineHourRest2: true,
          nineHourRest3: true,
          tankPause: false,
        ),
        startLabel: 'Wien, Österreich',
        destinationLabel: 'Stockholm, Schweden',
      );

  Future<void> pumpAtSize(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: TourResultView(
              result: exampleResult(),
              origin: 'Wien, Österreich',
              destination: 'Stockholm, Schweden',
              roadMix: const RoadMixAnalysis(
                roadKm: 850,
                averageKmh: 70,
                fastShare: 0.6,
                mainRoadShare: 0.3,
                slowShare: 0.1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Timeline passt ohne Overflow auf ein Smartphone',
      (tester) async {
    await pumpAtSize(tester, const Size(390, 844));

    expect(find.text('Tourablauf'), findsOneWidget);
    expect(find.text('Wien  →  Stockholm'), findsOneWidget);
    expect(find.text('Voraussichtliche Ankunft'), findsOneWidget);
    expect(find.text('Nächste Lenkpause'), findsOneWidget);
    expect(find.text('Straßenmix der Route'), findsOneWidget);
    expect(find.text('Ergebnis exportieren'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('E-Mail'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Statuskarten passen ohne Overflow auf Desktop', (tester) async {
    await pumpAtSize(tester, const Size(1200, 900));

    expect(find.text('Noch zu fahren'), findsOneWidget);
    expect(find.text('Reine Fahrzeit'), findsOneWidget);
    expect(find.text('Pausen / Ruhe'), findsOneWidget);
    expect(find.textContaining('Ø 80 km/h'), findsWidgets);
    expect(find.text('ETA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
