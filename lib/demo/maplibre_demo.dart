// EXPERIMENT – eigene Demo-Seite, nicht Teil der App.
//
// Zeigt die Tour-Animation mit einer festen Testroute İpsala → Odense
// (Linie durch echte Städte, keine Google-Route) und einer synthetischen
// Planung – ohne jeden Google-Aufruf. Zum Vergleich 2D / 2.5D:
//
//   flutter build web -t lib/demo/maplibre_demo.dart -o build/demo
//   …/?mode=2d   bzw.   …/?mode=25d
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:latlong2/latlong.dart';

import '../animation/country_borders.dart';
import '../animation/tour_path.dart';
import '../logic/eta_calculator.dart';
import '../ui/tour_animation_view.dart';

/// Grobe Strecke İpsala → Odense über die üblichen Korridore.
const _via = [
  LatLng(40.92, 26.38), // İpsala
  LatLng(41.68, 26.56), // Edirne
  LatLng(42.15, 24.75), // Plowdiw
  LatLng(42.70, 23.32), // Sofia
  LatLng(43.32, 21.90), // Niš
  LatLng(44.82, 20.46), // Belgrad
  LatLng(45.25, 19.84), // Novi Sad
  LatLng(46.25, 20.15), // Szeged
  LatLng(47.50, 19.04), // Budapest
  LatLng(48.15, 17.11), // Bratislava
  LatLng(49.20, 16.61), // Brünn
  LatLng(50.08, 14.44), // Prag
  LatLng(51.05, 13.74), // Dresden
  LatLng(52.52, 13.40), // Berlin
  LatLng(53.55, 9.99), // Hamburg
  LatLng(54.78, 9.44), // Flensburg
  LatLng(55.40, 10.39), // Odense
];

List<LatLng> _densify(List<LatLng> via) {
  const d = Distance(calculator: Haversine());
  final out = <LatLng>[via.first];
  for (var i = 1; i < via.length; i++) {
    final a = via[i - 1], b = via[i];
    final n = (d(a, b) / 2000).ceil();
    for (var k = 1; k <= n; k++) {
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * k / n,
          a.longitude + (b.longitude - a.longitude) * k / n));
    }
  }
  return out;
}

/// Planung wie die ETA sie liefern würde: 4,5 h fahren, Pause, 4,5 h, Ruhe.
EtaResult _plan(double km) {
  final steps = <EtaStep>[const EtaStep('', type: EtaEventType.start)];
  var t = DateTime(2026, 10, 5, 6, 0);
  var left = km;
  var day = 0.0;
  const kmh = 70.0;
  while (left > 0) {
    final chunk = left < 315 ? left : 315.0; // 4,5 h bei 70 km/h
    final end = t.add(Duration(minutes: (chunk / kmh * 60).round()));
    steps.add(EtaStep('', type: EtaEventType.drive, distanceKm: chunk, start: t, end: end));
    t = end;
    left -= chunk;
    day += chunk;
    if (left <= 0) break;
    if (day >= 630) {
      steps.add(EtaStep('', type: EtaEventType.dailyRest, start: t, end: t.add(const Duration(hours: 11))));
      t = t.add(const Duration(hours: 11));
      day = 0;
    } else {
      steps.add(EtaStep('', type: EtaEventType.breakTime, start: t, end: t.add(const Duration(minutes: 45))));
      t = t.add(const Duration(minutes: 45));
    }
  }
  steps.add(const EtaStep('', type: EtaEventType.destination));
  return EtaResult(steps, t);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  final path = TourPath([TourLeg(points: _densify(_via))]);
  final mode = Uri.base.queryParameters['mode'] ?? '25d';
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('de'),
    supportedLocales: const [Locale('de')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(colorSchemeSeed: const Color(0xFF0A6EBD), useMaterial3: true),
    home: TourAnimationView(
      path: path,
      title: 'İpsala → Odense',
      fromName: 'İpsala',
      toName: 'Odense',
      eta: _plan(path.roadMeters / 1000),
      countries: CountryIndex.load(),
      startIn25D: mode != '2d',
    ),
  ));
}
