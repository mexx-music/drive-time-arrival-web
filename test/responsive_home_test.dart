import 'package:driverroute_eta/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('Mehrere Zwischenstopps lassen sich hinzufügen und sortieren',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.ensureVisible(find.text('Zwischenstopps'));
    await tester.tap(find.text('Zwischenstopps'));
    await tester.pumpAndSettle();

    final stopField = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Adresse oder Ort eingeben');
    final addButton = find.text('Zwischenstopp hinzufügen');

    await tester.enterText(stopField, 'Sofia, Bulgarien');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('1. Sofia, Bulgarien'), findsOneWidget);

    await tester.enterText(stopField, 'Sibiu, Rumänien');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(find.text('2. Sibiu, Rumänien'), findsOneWidget);

    await tester.ensureVisible(find.text('2. Sibiu, Rumänien'));
    await tester.tap(find.byTooltip('Nach oben').last);
    await tester.pumpAndSettle();
    expect(find.text('1. Sibiu, Rumänien'), findsOneWidget);
    expect(find.text('2. Sofia, Bulgarien'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ländersperre ist kompakt, optional und mehrfach wählbar',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('Länder vermeiden · Keine'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Länder vermeiden · Keine'));
    await tester.pumpAndSettle();

    // Zugeklappt: keine Länderliste, kein Eingabefeld für Umfahrungspunkte.
    expect(find.text('Schweiz 🇨🇭'), findsNothing);

    await tester.tap(find.text('Länder vermeiden · Keine'));
    await tester.pumpAndSettle();
    expect(find.text('Schweiz 🇨🇭'), findsOneWidget);
    expect(find.text('Serbien 🇷🇸'), findsOneWidget);

    await tester.tap(find.text('Schweiz 🇨🇭'));
    await tester.pumpAndSettle();
    expect(find.text('Länder vermeiden · Schweiz'), findsOneWidget);

    // Mehrfachauswahl
    await tester.tap(find.text('Serbien 🇷🇸'));
    await tester.pumpAndSettle();
    expect(find.text('Länder vermeiden · 2 aktiv'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Zeitbudget ist sichtbar und Abfahrt erst bei Aktivierung editierbar',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('Abfahrt und verbleibende Zeit'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Abfahrt und verbleibende Zeit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abfahrt und verbleibende Zeit'));
    await tester.pumpAndSettle();

    expect(find.text('Verbleibende Fahrzeit'), findsOneWidget);
    expect(find.text('Verbleibende Einsatzzeit'), findsOneWidget);
    expect(find.textContaining('Abfahrtszeit '), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Manuelle Abfahrt'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Manuelle Abfahrt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manuelle Abfahrt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Abfahrtszeit '), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Fähre ist automatisch aktiv und Uhrzeit hat keinen Zahlenrad-Picker',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('Fähre'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fähre'));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(find.text('Fähre wählen (Test)'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Uhrzeit wählen'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Uhrzeit wählen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uhrzeit wählen'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dänemark-Alternative schaltet automatische Fähre aus',
      (tester) async {
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('Fähre'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fähre'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Alternative über Dänemark: 2 Fähren'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester
        .ensureVisible(find.text('Alternative über Dänemark: 2 Fähren'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alternative über Dänemark: 2 Fähren'));
    await tester.pumpAndSettle();

    final automatic = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    final denmark = find.ancestor(
      of: find.text('Alternative über Dänemark: 2 Fähren'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.widget<SwitchListTile>(denmark).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fährsuche wählt eine Verbindung und übersteuert Automatik',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'ferries_json_cache_v2':
          '{"routes":[{"id":"igou_bari_grimaldi","name":"Igoumenitsa–Bari (Grimaldi)","from":"Igoumenitsa","to":"Bari","operators":["Grimaldi"],"duration_hours":10,"departures_local":[],"tz":"Europe/Athens","region":"Griechenland/Italien","active":true}]}',
    });
    await pumpAtSize(tester, width: 390, height: 844);
    await tester.scrollUntilVisible(
      find.text('Fähre'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Fähre'));
    await tester.pumpAndSettle();

    final search = find.byWidgetPredicate((widget) =>
        widget is TextField &&
        widget.decoration?.labelText == 'Fähre manuell suchen');
    await tester.ensureVisible(search);
    await tester.enterText(search, 'Igoumenitsa Bari');
    await tester.pumpAndSettle();
    final route = find.text('Igoumenitsa–Bari (Grimaldi)');
    await tester.ensureVisible(route);
    await tester.tap(route);
    await tester.pumpAndSettle();

    expect(find.text('Manuell gewählt – statt automatischem Vorschlag'),
        findsOneWidget);
    final automatic = find.ancestor(
      of: find.text('Fähre automatisch vorschlagen'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(automatic).value, isFalse);
    expect(tester.takeException(), isNull);
  });
}
