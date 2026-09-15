import 'package:driverroute_eta/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpAtSize(
    WidgetTester tester, {
    required double width,
    required double height,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(const DriverRouteApp());
    await tester.pumpAndSettle();
  }

  testWidgets('Desktop zeigt Eingabe und Ergebnisvorschau nebeneinander',
      (tester) async {
    await pumpAtSize(tester, width: 1280, height: 800);

    expect(find.text('Tour vorbereiten'), findsOneWidget);
    expect(find.text('Deine Tourübersicht'), findsOneWidget);
    expect(find.text('Route planen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Smartphone bleibt bei einer kompakten Spalte', (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);

    expect(find.text('Tour vorbereiten'), findsOneWidget);
    expect(find.text('Deine Tourübersicht'), findsNothing);
    expect(find.text('Route planen'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Querformat nutzt ab 860 Pixeln die Ergebnisfläche',
      (tester) async {
    await pumpAtSize(tester, width: 900, height: 600);

    expect(find.text('Deine Tourübersicht'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
