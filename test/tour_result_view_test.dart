import 'dart:convert';
import 'dart:typed_data';

import 'package:driverroute_eta/logic/eta_calculator.dart';
import 'package:driverroute_eta/logic/speed_profile.dart';
import 'package:driverroute_eta/services/tour_image_export.dart';
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
    expect(find.text('Tour exportieren'), findsOneWidget);
    expect(find.text('Grafik teilen'), findsOneWidget);
    expect(find.text('Text teilen'), findsOneWidget);
    expect(find.byTooltip('Tourgrafik teilen'), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);
    expect(find.text('E-Mail'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Grafik teilen bietet klare Zielauswahl', (tester) async {
    await pumpAtSize(tester, const Size(390, 844));
    final button = find.text('Grafik teilen');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('E-Mail'), findsOneWidget);
    expect(find.text('Weitere Apps'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Text teilen bietet WhatsApp und E-Mail direkt an',
      (tester) async {
    await pumpAtSize(tester, const Size(390, 844));
    final button = find.text('Text teilen');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('E-Mail'), findsOneWidget);
    expect(find.text('Weitere Apps'), findsOneWidget);
    expect(find.text('Text kopieren'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WhatsApp-Dialog zeigt PNG-Vorschau statt sendbaren Hinweistext',
      (tester) async {
    var continued = false;
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/dYkAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsAppImageReadyDialog(
            filename: 'driverroute-test.png',
            png: png,
            onContinue: () => continued = true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Grafik kopieren'), findsNWidgets(2));
    expect(find.text('Weiter zu WhatsApp'), findsOneWidget);
    expect(find.textContaining('Chat auswählen, Bild mit'), findsOneWidget);
    await tester.tap(find.text('Weiter zu WhatsApp'));
    expect(continued, isTrue);
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

  testWidgets('Vollständige Tourgrafik wird in Exportbreite gerendert',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final result = exampleResult();
    final fallbackKey = GlobalKey();
    late BuildContext exportContext;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          exportContext = context;
          return RepaintBoundary(
            key: fallbackKey,
            child: const SizedBox(width: 100, height: 100),
          );
        }),
      ),
    ));

    final png = await tester.runAsync(
      () => TourImageExport.captureForSharing(
        context: exportContext,
        graphic: TourResultView(
          result: result,
          origin: 'Wien, Österreich',
          destination: 'Stockholm, Schweden',
          exportOnly: true,
        ),
        estimatedEvents: result.steps.length,
        fallbackBoundaryKey: fallbackKey,
      ),
    );

    expect(png, isNotNull);
    final data = ByteData.sublistView(png!);
    expect(data.getUint32(16), 1200);
    expect(data.getUint32(20), greaterThan(1200));
    expect(tester.takeException(), isNull);
  });
}
