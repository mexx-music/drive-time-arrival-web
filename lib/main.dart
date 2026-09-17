// lib/main.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'services/maps_proxy.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'models/ferry_route.dart';
import 'services/ferry_schedule_loader.dart';
import 'logic/eta_calculator.dart';
import 'logic/ferry_auto.dart';
import 'logic/ferry_route_suggester.dart';
import 'logic/denmark_ferry_route.dart';
import 'logic/port_aliases.dart';
import 'logic/speed_profile.dart';
import 'logic/time_budget.dart';
import 'logic/serbia_avoidance.dart';
import 'package:driverroute_eta/secrets.dart';
import 'widgets/places_autocomplete.dart' as places_auto;
import 'services/geocoding_service.dart';
import 'services/distance_service.dart';
import 'widgets/place_input.dart';
import 'widgets/duration_input.dart';
import 'widgets/tour_result_view.dart';
import 'ui/map_osm_view.dart';
import 'utils/open_in_tab.dart';
import 'services/map_launcher.dart' as map_launcher;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  await initializeDateFormatting('en');
  // Debug: print presence/length of Google Maps API key (never the key itself)
  // This helps confirm the web build reads the key from lib/secrets.dart
  // and avoids leaking the key.
  // ignore: avoid_print
  if (const bool.fromEnvironment('dart.vm.product') == false) {
    // not in production
    // ignore: avoid_print
    print(googleMapsApiKeyInfo());
    // show proxy config in debug
    if (kDebugMode) logMapsProxyConfig();
  }
  runApp(const DriverRouteApp());
}

class DriverRouteApp extends StatelessWidget {
  const DriverRouteApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'DriverRoute ETA',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A6EBD),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF2F5F9),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF102A43),
          foregroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD9E2EC)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFD9E2EC)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF0A6EBD), width: 2),
          ),
        ),
        expansionTileTheme: const ExpansionTileThemeData(
          backgroundColor: Colors.white,
          collapsedBackgroundColor: Colors.white,
          iconColor: Color(0xFF0A6EBD),
          collapsedIconColor: Color(0xFF486581),
          textColor: Color(0xFF102A43),
          collapsedTextColor: Color(0xFF102A43),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFFD9E2EC)),
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
            side: BorderSide(color: Color(0xFFD9E2EC)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        useMaterial3: true,
      ),
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _startCtl = TextEditingController();
  final _destCtl = TextEditingController();
  final _kmCtl = TextEditingController(text: '850');

  // Waypoints
  final _stopCtl = TextEditingController();
  final List<String> _stops = [];
  final List<LatLng?> _stopCoords =
      []; // parallel storage for resolved stop coordinates
  bool _addingStop = false;
  final bool _optimizeStops = false;
  bool _avoidSerbia = false;
  List<String> _resultRouteStops = [];
  String? _resultRoutePolyline;
  String? _countryRouteNote;
  String? _ferryRouteNote;
  FerryRoute? _resultFerry;
  bool _resultViaDenmark = false;

  double _avgKmh = 80;
  SpeedProfile _speedProfile = SpeedProfile.automatic;
  int _remainingDrivingMin = 600;
  int _continuousDrivenMin = 0;
  int _remainingDutyMin = 900;

  // Lenk-/Ruhezeit & Tankpause
  bool _ten1 = true; // 10h-Tag #1 verfügbar?
  bool _ten2 = true; // 10h-Tag #2 verfügbar?
  bool _nine1 = true; // 9h-Ruheverkürzung #1 verfügbar?
  bool _nine2 = true; // 9h-Ruheverkürzung #2 verfügbar?
  bool _nine3 = true; // 9h-Ruheverkürzung #3 verfügbar?
  bool _tankpause = false; // ⛽ +30 min
  bool _splitBreak = false;
  bool _weeklyRestDue = false;

  int get _dailyDrivingLimit => _ten1 || _ten2 ? 600 : 540;
  int get _dailyDutyLimit => _nine1 || _nine2 || _nine3 ? 900 : 780;
  int get _drivenMin => TimeBudget.elapsedFromRemaining(
        _remainingDrivingMin,
        _dailyDrivingLimit,
      );
  int get _dutyOffsetMin => TimeBudget.elapsedFromRemaining(
        _remainingDutyMin,
        _dailyDutyLimit,
      );

  bool _autoFerry = true;
  bool _viaDenmarkFerries = false;
  bool _showDetails = false;
  FerryRoute? _manualFerry;
  DateTime? _manualFerryDeparture;
  bool _ferryRestEligible = false;

  List<FerryRoute> _routes = [];
  String _source = '…';

  List<String> _log = [];
  EtaResult? _etaResult;
  String _resultOrigin = '';
  String _resultDestination = '';
  RoadMixAnalysis? _resultRoadMix;
  bool _calculating = false;

  double? _startLat, _startLng, _destLat, _destLng;

  // Manuelle Abfahrt (UI & state)
  DateTime _manualDepartureDate = DateTime.now();
  int _manualDepartureHour = DateTime.now().hour;
  int _manualDepartureMinute = DateTime.now().minute;
  bool _manualDepartureActive = false;

  // Visible resolved previews provided by PlaceInput via onConfirmed
  String? _resolvedStart;
  String? _resolvedDestination;

  @override
  void initState() {
    super.initState();
    _loadFerries();
  }

  @override
  void dispose() {
    _startCtl.dispose();
    _destCtl.dispose();
    _kmCtl.dispose();
    _stopCtl.dispose();
    super.dispose();
  }

  Future<void> _addStop() async {
    final raw = _stopCtl.text.trim();
    if (raw.isEmpty || _addingStop) return;
    if (_stops.length >= 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Höchstens 10 Zwischenstopps sind möglich.')),
      );
      return;
    }
    setState(() => _addingStop = true);
    String label = raw;
    LatLng? coordinate;
    try {
      final resolved = await GeocodingService.resolve(raw);
      label = resolved.description;
      coordinate = LatLng(resolved.lat, resolved.lng);
    } catch (error) {
      debugPrint('Zwischenstopp konnte nicht vorab aufgelöst werden: $error');
    }
    if (!mounted) return;
    setState(() {
      _stops.add(label);
      _stopCoords.add(coordinate);
      _stopCtl.clear();
      _addingStop = false;
      _etaResult = null;
    });
  }

  void _moveStop(int from, int to) {
    if (to < 0 || to >= _stops.length) return;
    setState(() {
      final stop = _stops.removeAt(from);
      final coordinate = _stopCoords.removeAt(from);
      _stops.insert(to, stop);
      _stopCoords.insert(to, coordinate);
      _etaResult = null;
    });
  }

  void _removeStop(int index) {
    setState(() {
      _stops.removeAt(index);
      _stopCoords.removeAt(index);
      _etaResult = null;
    });
  }

  void _changeDrivingLimit(void Function() updateRule) {
    final elapsed = _drivenMin;
    setState(() {
      updateRule();
      _remainingDrivingMin = (_dailyDrivingLimit - elapsed).clamp(
        0,
        _dailyDrivingLimit,
      );
    });
  }

  void _changeDutyLimit(void Function() updateRule) {
    final elapsed = _dutyOffsetMin;
    setState(() {
      updateRule();
      _remainingDutyMin = (_dailyDutyLimit - elapsed).clamp(
        0,
        _dailyDutyLimit,
      );
    });
  }

  Future<void> _loadFerries() async {
    final (source, routes) = await FerryScheduleLoader.load();
    setState(() {
      _routes = routes.where((r) => r.active).toList();
      _source = source;
    });
  }

  // ---- Google Directions: Distanz in km holen ----
  Future<double?> _getDistanceKm(String origin, String destination) async {
    // Block direct Google Directions REST calls from web—CORS prevents them.
    if (!mapsDirectCallsAllowed()) {
      _log.add(
          '⚠️ Web routing via direct Google REST request is blocked in browser');
      final mapUrl =
          'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route='
          '${Uri.encodeComponent(origin)};${Uri.encodeComponent(destination)}';
      // debug: final map URL
      // ignore: avoid_print
      print('[openMapOsm] final map URL (names): $mapUrl');
      try {
        openInNewTabWithName(mapUrl, 'driverroute_map');
      } catch (e) {
        // ignore, will show snack instead
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Öffne Karte in neuem Tab...'),
        ));
      }
      setState(() {});
      return null;
    }
    if (GOOGLE_MAPS_API_KEY.isEmpty ||
        GOOGLE_MAPS_API_KEY == 'DEIN_API_KEY_HIER') {
      _log.add('⚠️ Kein API-Key hinterlegt (lib/secrets.dart).');
      setState(() {});
      return null;
    }
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${Uri.encodeComponent(origin)}'
      '&destination=${Uri.encodeComponent(destination)}'
      '&mode=driving&units=metric&departure_time=now'
      '&key=$GOOGLE_MAPS_API_KEY',
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body);
    if (data['status'] != 'OK') {
      _dbg('Directions Status: ${data['status']}');
      setState(() {});
      return null;
    }
    final legs = data['routes'][0]['legs'][0];
    final meters = (legs['distance']['value'] as num).toDouble();
    return meters / 1000.0;
  }

  String _stripHtml(String s) => s
      .replaceAll(RegExp('<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  bool _stepsIndicateFerry(List<Map<String, dynamic>> steps) {
    for (final st in steps) {
      final inst =
          _stripHtml((st['html_instructions'] ?? '').toString()).toLowerCase();
      if (inst.contains('ferry') ||
          inst.contains('fähre') ||
          inst.contains('fähren') ||
          inst.contains('fahre') ||
          inst.contains('port') ||
          inst.contains('harbor') ||
          inst.contains('terminal')) {
        return true;
      }
    }
    return false;
  }

  int _aliasScore(String hay, List<String> aliases) {
    int score = 0;
    for (final a in aliases) {
      if (a.isEmpty) continue;
      if (hay.contains(' $a ')) {
        score += 3; // exakter Token-Treffer
      } else if (hay.contains(a)) {
        score += 1; // Teiltreffer
      }
    }
    return score;
  }

  FerryRoute? _matchFerryFromText(List<Map<String, dynamic>> steps) {
    final hay = (' ' +
        steps
            .map((s) => _stripHtml((s['html_instructions'] ?? '').toString())
                .toLowerCase())
            .join(' | ') +
        ' ');
    FerryRoute? best;
    int bestScore = 0;
    for (final r in _routes) {
      final a = PortAliases.allFor(r.from);
      final b = PortAliases.allFor(r.to);
      final s = _aliasScore(hay, a) + _aliasScore(hay, b);
      if (s > bestScore) {
        bestScore = s;
        best = r;
      }
    }
    return bestScore >= 3 ? best : null;
  }

  // --- PATCH START: waypoint-aware ferry helpers ---
  // kleines firstWhereOrNull ohne extra Packages
  T? _firstWhereOrNull<T>(Iterable<T> it, bool Function(T) test) {
    for (final x in it) {
      if (test(x)) return x;
    }
    return null;
  }

  // prüft, ob irgendein Alias als Token im Text vorkommt
  bool _containsAliasToken(String hay, List<String> aliases) {
    final h = ' ${hay.toLowerCase()} ';
    for (final a in aliases) {
      final aa = a.toLowerCase().trim();
      if (aa.isEmpty) continue;
      if (h.contains(' $aa ')) return true;
    }
    return false;
  }

  // Liefert eine Fährroute, wenn ein Waypoint klar auf FROM/TO eines Eintrags hindeutet.
  FerryRoute? _matchFerryByWaypoints(List<String> wps) {
    if (wps.isEmpty || _routes.isEmpty) return null;

    FerryRoute? best;
    int bestScore = -999;

    final wpsLower = wps.map((w) => ' ${w.toLowerCase()} ').toList();

    bool _hasToken(List<String> haystacks, List<String> aliases) {
      for (final h in haystacks) {
        for (final a in aliases) {
          final aa = a.toLowerCase().trim();
          if (aa.isEmpty) continue;
          if (h.contains(' $aa ')) return true;
        }
      }
      return false;
    }

    final containsBrindisi = wpsLower.any((w) => w.contains(' brindisi '));
    final containsBari = wpsLower.any((w) => w.contains(' bari '));

    for (final r in _routes) {
      final fromAliases = PortAliases.allFor(r.from);
      final toAliases = PortAliases.allFor(r.to);

      final hitFrom = _hasToken(wpsLower, fromAliases);
      final hitTo = _hasToken(wpsLower, toAliases);

      int score = 0;
      if (hitFrom) score += 4;
      if (hitTo) score += 4;
      if (hitFrom && hitTo) score += 2; // Bonus: beide Enden erkannt

      // Harter Präferenzfilter: Wenn explizit Brindisi in Waypoints steht,
      // bevorzuge Routen mit Brindisi und bestrafe andere.
      final routeHasBrindisi =
          fromAliases.any((a) => a.toLowerCase() == 'brindisi') ||
              toAliases.any((a) => a.toLowerCase() == 'brindisi');
      final routeHasBari = fromAliases.any((a) => a.toLowerCase() == 'bari') ||
          toAliases.any((a) => a.toLowerCase() == 'bari');

      if (containsBrindisi) {
        if (routeHasBrindisi) score += 5;
        if (routeHasBari && !routeHasBrindisi) score -= 6; // verdränge Bari
      } else if (containsBari) {
        if (routeHasBari) score += 5;
      }

      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }

    // nur akzeptieren, wenn wir wenigstens ein Ende sicher getroffen haben
    return (bestScore >= 4) ? best : null;
  }
  // --- PATCH END ---

  // Prüft, ob origin/destination eher auf TO/FROM deuten (Richtung flippen)
  FerryRoute? _maybeFlipByEnds({
    required FerryRoute matched,
    required String origin,
    required String destination,
  }) {
    final o = origin.toLowerCase();
    final d = destination.toLowerCase();

    final fromAliases =
        PortAliases.allFor(matched.from).map((e) => e.toLowerCase()).toList();
    final toAliases =
        PortAliases.allFor(matched.to).map((e) => e.toLowerCase()).toList();

    final originLooksLikeFrom = fromAliases.any((a) => o.contains(a));
    final originLooksLikeTo = toAliases.any((a) => o.contains(a));
    final destLooksLikeFrom = fromAliases.any((a) => d.contains(a));
    final destLooksLikeTo = toAliases.any((a) => d.contains(a));

    // Falls Start eher "TO" und Ziel eher "FROM" ist -> invertieren
    final needFlip = originLooksLikeTo &&
        destLooksLikeFrom &&
        !(originLooksLikeFrom && destLooksLikeTo);

    if (needFlip) {
      final flipped = _firstWhereOrNull<FerryRoute>(
        _routes,
        (r) => r.from == matched.to && r.to == matched.from,
      );
      if (flipped != null) return flipped;
      return matched;
    }
    return matched;
  }

  Future<
      (
        double km,
        RoadMixAnalysis? roadMix,
        FerryRoute? ferry,
        String note,
        List<String> routedWaypoints,
        String? encodedPolyline,
        FerryRouteSuggestion? ferrySuggestion,
        DenmarkFerryRoute? denmarkRoute,
      )> _planDistanceAndFerryAuto(
    String origin,
    String destination,
    List<String> wps,
    bool optimize,
  ) async {
    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);

    if (_viaDenmarkFerries) {
      if (_avoidSerbia || wps.isNotEmpty) {
        throw const FerryRouteException(
          'Die Dänemark-Variante ist derzeit nur ohne Serbien-Sperre und eigene Zwischenstopps verfügbar.',
        );
      }
      final route = await DenmarkFerryRoute.plan(
        origin: origin,
        destination: destination,
        roadDistance: (from, to) => const DistanceService()
            .fetchKmDistance(origin: from, destination: to),
      );
      if (route == null) {
        throw const FerryRouteException(
          'Die zwei Fährstrecken über Dänemark konnten für diese Route nicht geprüft werden. Bitte Start und Ziel in Schweden bzw. Deutschland wählen.',
        );
      }
      return (
        route.roadKm,
        null,
        null,
        'Über Dänemark mit zwei kurzen Fähren; Wartezeiten noch nicht enthalten.',
        <String>[],
        null,
        null,
        route,
      );
    }

    if (_autoFerry && _manualFerry == null && !_avoidSerbia && wps.isEmpty) {
      final suggestion = await FerryRouteSuggester.suggest(
        origin: origin,
        destination: destination,
        routes: _routes,
        roadDistance: (from, to) => const DistanceService()
            .fetchKmDistance(origin: from, destination: to),
      );
      if (suggestion != null) {
        return (
          suggestion.roadKm,
          null,
          suggestion.route,
          'Fähre automatisch vorgeschlagen: ${suggestion.route.name}. Fahrplan vor Buchung prüfen.',
          <String>[],
          null,
          suggestion,
          null,
        );
      }
      if (FerryRouteSuggester.supportsTrip(origin, destination)) {
        throw const FerryRouteException(
          'Für diese Strecke konnte keine erreichbare Fähre geprüft werden. Bitte Verbindung prüfen oder eine Fähre manuell wählen.',
        );
      }
    }

    var normal = await det.fetchDirections(
      origin: origin,
      destination: destination,
      waypoints: wps,
      optimize: optimize,
    );
    var routedWaypoints = List<String>.of(wps);
    var countryNote = '';
    if (_avoidSerbia) {
      if (!normal.ok) {
        throw const CountryRouteException(
          'Die Route konnte nicht auf Serbien geprüft werden. Bitte später erneut versuchen.',
        );
      }
      final crossesSerbia = SerbiaAvoidance.routeCrossesSerbia(normal.raw);
      if (crossesSerbia == null) {
        throw const CountryRouteException(
          'Die Kartenroute enthält keine prüfbare Streckenlinie. Serbien kann nicht sicher ausgeschlossen werden.',
        );
      }
      if (crossesSerbia) {
        if (wps.isNotEmpty) {
          throw const CountryRouteException(
            'Diese Zwischenstopps führen durch Serbien. Bitte Stopps anpassen oder für die automatische Umfahrung entfernen.',
          );
        }
        final corridor = SerbiaAvoidance.corridorFor(origin, destination);
        if (corridor == null) {
          throw const CountryRouteException(
            'Eine automatische Serbien-Umfahrung ist derzeit für Griechenland–Österreich verfügbar. Für diese Strecke bitte eigene Zwischenstopps wählen.',
          );
        }
        routedWaypoints = corridor;
        normal = await det.fetchDirections(
          origin: origin,
          destination: destination,
          waypoints: routedWaypoints,
        );
        if (!normal.ok ||
            SerbiaAvoidance.routeCrossesSerbia(normal.raw) != false) {
          throw const CountryRouteException(
            'Google konnte keine überprüfte Route ohne Serbien liefern. Es wird keine ETA aus einer Strecke durch Serbien berechnet.',
          );
        }
        countryNote =
            'Serbien gemieden · automatisch über Bulgarien, Rumänien und Ungarn';
      } else {
        countryNote = 'Serbien gemieden · Route geprüft';
      }
    }
    if (!normal.ok) {
      final errMsg = (normal.raw['error_message'] ?? '').toString();
      final note = errMsg.isNotEmpty
          ? '⚠️ Directions(${normal.status}): ${errMsg}; nutze manuelle km'
          : '⚠️ Directions(${normal.status}); nutze manuelle km';
      // debug
      // ignore: avoid_print
      print(
          '[planDistanceAndFerryAuto] Directions failed: ${normal.status} ${errMsg}');
      return (
        double.tryParse(_kmCtl.text.trim()) ?? 0.0,
        null,
        null,
        note,
        routedWaypoints,
        null,
        null,
        null,
      );
    }

    // Vergleichsroute ohne Fähren
    final avoid = await det.fetchDirections(
      origin: origin,
      destination: destination,
      waypoints: routedWaypoints,
      optimize: optimize,
      avoidFerries: true,
    );

    bool hasFerry = FerryAutoDetect(GOOGLE_MAPS_API_KEY).routeHasFerry(normal);
    double km = normal.km;
    String why = hasFerry ? 'warnings/steps' : '';

    if (avoid.ok) {
      final ratio = avoid.km / (km == 0 ? 1 : km);
      final thr = km < 700 ? 1.30 : 1.45;
      if (ratio > thr) {
        hasFerry = true;
        if (why.isEmpty) why = 'asymmetry ${ratio.toStringAsFixed(2)}x';
      }
      _dbg(
          'Avoid-ferries: ${avoid.km.toStringAsFixed(1)} km vs normal ${km.toStringAsFixed(1)} km (ratio ${ratio.toStringAsFixed(2)}x, thr ${thr.toStringAsFixed(2)})');
    } else if (avoid.status == 'ZERO_RESULTS') {
      hasFerry = true;
      if (why.isEmpty) why = 'no-land-route';
      _dbg('Avoid-ferries ZERO_RESULTS → Fähre erforderlich');
    } else {
      _dbg('Avoid-ferries fetch status: ${avoid.status}');
    }

    FerryRoute? matched;
    if (hasFerry) {
      matched = _matchFerryFromText(normal.steps);

      // --- PATCH START: use waypoints as strong hint & maybe flip direction ---
      final wpHint = _matchFerryByWaypoints(wps);
      if (wpHint != null) {
        if (matched == null) {
          matched = wpHint;
          _dbg('Fähre per Zwischenziel erkannt: ${matched.name}');
        } else if (matched != wpHint) {
          // Wenn Waypoint-Hinweis eine andere Strecke nahelegt, ersetze
          matched = wpHint;
          _dbg('Fähre per Zwischenziel überschrieben: ${matched.name}');
        }
      }

      // Richtung ggf. anhand Start/Ziel drehen (besonders wichtig bei Italien↔Griechenland)
      if (matched != null) {
        final flipped = _maybeFlipByEnds(
            matched: matched, origin: origin, destination: destination);
        if (flipped != null && flipped != matched) {
          _dbg(
              'Fährrichtung invertiert (Endpunkte/Waypoints): ${flipped.from} → ${flipped.to}');
          matched = flipped;
        }
      }
      // --- PATCH END ---

      if (matched != null) {
        if (_showDetails) {
          _log.add('🔎 Auto-Fähre: ${matched.name} (reason: $why)');
        }
      } else {
        if (_showDetails) {
          _log.add(
              '🧭 Fähre erkannt ($why), aber kein Routen-Match – manuell auswählbar.');
        }
      }
    }

    // Distanzgewichtete Auswertung der einzelnen Straßenabschnitte. Fähren
    // werden entfernt, weil ihre Dauer separat in der ETA geplant wird.
    var roadMix = RoadMixAnalysis.fromDirectionsSteps(normal.steps);
    if (roadMix == null && !hasFerry && normal.sec > 0) {
      roadMix = RoadMixAnalysis(
        roadKm: normal.km,
        averageKmh: normal.km / (normal.sec / 3600),
        fastShare: 0,
        mainRoadShare: 0,
        slowShare: 0,
      );
    }
    return (
      km,
      roadMix,
      matched,
      [
        if (countryNote.isNotEmpty) countryNote,
        if (hasFerry) '🛳️ Fähre erkannt ($why)'
      ].join(' · '),
      routedWaypoints,
      ((normal.raw['routes'] as List?)?.firstOrNull
          as Map<String, dynamic>?)?['overview_polyline']?['points'] as String?,
      null,
      null,
    );
  }

  Future<void> _compute() async {
    if (_calculating) return;
    if (_startCtl.text.trim().isEmpty || _destCtl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bitte Startort und Zielort vollständig eingeben.'),
        ),
      );
      return;
    }
    if (_avgKmh <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Bitte eine gültige Geschwindigkeit wählen.')),
      );
      return;
    }
    if (_drivenMin > 600 ||
        _continuousDrivenMin > 270 ||
        _continuousDrivenMin > _drivenMin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Bitte Lenkzeiten prüfen: heute höchstens 10 h, seit der letzten Pause höchstens 4 h 30 min.',
          ),
        ),
      );
      return;
    }
    if (_dutyOffsetMin < _drivenMin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Die bereits verbrauchte Einsatzzeit muss mindestens der heute gefahrenen Zeit entsprechen. Bitte verbleibende Zeiten prüfen.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _calculating = true;
      _log.clear();
      _etaResult = null;
      _countryRouteNote = null;
      _ferryRouteNote = null;
    });

    try {
      final now = DateTime.now();
      DateTime start = now;

      // Manuelle Abfahrt verwenden?
      if (_manualDepartureActive) {
        try {
          start = DateTime(
            _manualDepartureDate.year,
            _manualDepartureDate.month,
            _manualDepartureDate.day,
            _manualDepartureHour,
            _manualDepartureMinute,
          );
          _log.add(
              '🕓 Manuelle Abfahrt gesetzt: ${DateFormat('yyyy-MM-dd HH:mm').format(start)}');
        } catch (e) {
          _dbg('Fehler beim Zusammensetzen der manuellen Abfahrtszeit: $e');
        }
      }

      // km bevorzugt via Directions
      double km = double.tryParse(_kmCtl.text.trim()) ?? 0.0;
      var s = (_resolvedStart != null && _resolvedStart!.trim().isNotEmpty)
          ? _resolvedStart!.trim()
          : _startCtl.text.trim();
      var d = (_resolvedDestination != null &&
              _resolvedDestination!.trim().isNotEmpty)
          ? _resolvedDestination!.trim()
          : _destCtl.text.trim();

      // Try to finalize autocomplete suggestions for start/destination if user didn't explicitly pick one
      try {
        if (!places_auto.isExplicitlySelectedForController(_startCtl)) {
          final typed = s;
          bool finalized = false;
          try {
            if (typed.isNotEmpty) {
              final geores = await GeocodingService.resolve(typed);
              if (geores != null && geores.description.isNotEmpty) {
                _startCtl.text = geores.description;
                debugPrint(
                    'finalizing start via geocoding: ${geores.description}');
                places_auto.markExplicitSelection(_startCtl);
                finalized = true;
              }
            }
          } catch (e) {
            debugPrint('geocoding start failed: $e');
          }
          if (!finalized) {
            final sug = places_auto.getSuggestionsForController(_startCtl);
            if (sug.isNotEmpty) {
              final low = s.toLowerCase();
              String chosen = sug.first;
              final idxExact = sug.indexWhere((x) => x.toLowerCase() == low);
              if (idxExact != -1) {
                chosen = sug[idxExact];
              } else {
                final idxStarts = sug.indexWhere(
                    (x) => x.toLowerCase().startsWith(low) && low.isNotEmpty);
                if (idxStarts != -1) chosen = sug[idxStarts];
              }
              _startCtl.text = chosen;
              debugPrint('fallback to autocomplete suggestion: $chosen');
              places_auto.markExplicitSelection(_startCtl);
            }
          }
        }
      } catch (e) {
        debugPrint('finalize start suggestion error: $e');
      }

      try {
        if (!places_auto.isExplicitlySelectedForController(_destCtl)) {
          final typed = d;
          bool finalized = false;
          try {
            if (typed.isNotEmpty) {
              final geores = await GeocodingService.resolve(typed);
              if (geores != null && geores.description.isNotEmpty) {
                _destCtl.text = geores.description;
                debugPrint(
                    'finalizing destination via geocoding: ${geores.description}');
                places_auto.markExplicitSelection(_destCtl);
                finalized = true;
              }
            }
          } catch (e) {
            debugPrint('geocoding dest failed: $e');
          }
          if (!finalized) {
            final sug = places_auto.getSuggestionsForController(_destCtl);
            if (sug.isNotEmpty) {
              final low = d.toLowerCase();
              String chosen = sug.first;
              final idxExact = sug.indexWhere((x) => x.toLowerCase() == low);
              if (idxExact != -1) {
                chosen = sug[idxExact];
              } else {
                final idxStarts = sug.indexWhere(
                    (x) => x.toLowerCase().startsWith(low) && low.isNotEmpty);
                if (idxStarts != -1) chosen = sug[idxStarts];
              }
              _destCtl.text = chosen;
              debugPrint('fallback to autocomplete suggestion: $chosen');
              places_auto.markExplicitSelection(_destCtl);
            }
          }
        }
      } catch (e) {
        debugPrint('finalize dest suggestion error: $e');
      }

      // Die Autovervollständigung kann inzwischen präzisere Orts- und
      // Landesnamen geliefert haben. Diese Werte steuern auch das Norwegenprofil.
      s = (_resolvedStart != null && _resolvedStart!.trim().isNotEmpty)
          ? _resolvedStart!.trim()
          : _startCtl.text.trim();
      d = (_resolvedDestination != null &&
              _resolvedDestination!.trim().isNotEmpty)
          ? _resolvedDestination!.trim()
          : _destCtl.text.trim();

      // debug: show start/destination read from controllers before validation
      // ignore: avoid_print
      print('[Validation] start="${_startCtl.text.trim()}"');
      // ignore: avoid_print
      print('[Validation] dest="${_destCtl.text.trim()}"');
      // debug: show waypoints that will be passed to directions
      // ignore: avoid_print
      print('[Validation] waypoints=${_stops}');

      final (
        distKm,
        roadMix,
        matchedFerry,
        note,
        routedWaypoints,
        encodedPolyline,
        ferrySuggestion,
        denmarkRoute,
      ) = await _planDistanceAndFerryAuto(s, d, _stops, _optimizeStops);

      final speedPlan = SpeedProfileResolver.resolve(
        profile: _speedProfile,
        customKmh: _avgKmh,
        routedKmh: roadMix?.averageKmh,
        routeLabels: [s, d, ..._stops],
      );

      // debug
      // ignore: avoid_print
      print(
          '[Compute] planDistanceAndFerryAuto -> distKm=$distKm routedKmh=${roadMix?.averageKmh} note=$note matchedFerry=${matchedFerry?.name}');

      if (_showDetails) {
        _log.add(
          '🚛 Planungsschnitt: ${speedPlan.kmh.toStringAsFixed(1)} km/h '
          '(${speedPlan.reason})',
        );
      }

      if (distKm > 0 || matchedFerry != null || denmarkRoute != null) {
        km = distKm;
        if (_showDetails) {
          _log.add(
              '🗺️ Distanz (Google Directions): ${distKm.toStringAsFixed(1)} km');
        }
      } else {
        _log.add('⚠️ Directions nicht verfügbar – nutze manuelle km.');
        if (note.isNotEmpty) {
          final msg = 'Directions-Fehler: $note';
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(msg)));
          }
        }
      }

      // Regeln einmal bauen
      final driveRules = DriveRulesConfig(
        tenHourDay1: _ten1,
        tenHourDay2: _ten2,
        nineHourRest1: _nine1,
        nineHourRest2: _nine2,
        nineHourRest3: _nine3,
        tankPause: _tankpause,
        splitBreak: _splitBreak,
        weeklyRestDue: _weeklyRestDue,
      );

      EtaResult res;

      // Erzeuge FerryAutoDetect und delegiere ETA-Berechnung (Wrapper entscheidet, ob Fähre benutzt wird)
      final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
      final FerryRoute? ferryCandidate =
          _manualFerry ?? (_autoFerry ? matchedFerry : null);
      if (_avoidSerbia && ferryCandidate != null) {
        throw const CountryRouteException(
          'Serbien-Sperre und Fährplanung können derzeit nicht gemeinsam geprüft werden. Bitte Fähre deaktivieren.',
        );
      }
      res = denmarkRoute != null
          ? EtaCalculator.computeTwoShortFerries(
              start: start,
              alreadyDrivenMin: _drivenMin,
              alreadyDrivenSinceBreakMin: _continuousDrivenMin,
              dutyTimeOffsetMin: _dutyOffsetMin,
              avgKmh: speedPlan.kmh,
              rules: driveRules,
              kmBefore: denmarkRoute.kmBefore,
              kmBetween: denmarkRoute.kmBetween,
              kmAfter: denmarkRoute.kmAfter,
              firstDeparturePort: denmarkRoute.firstDeparturePort,
              firstFerry: denmarkRoute.firstFerry,
              firstFerryMinutes: denmarkRoute.firstFerryMinutes,
              secondDeparturePort: denmarkRoute.secondDeparturePort,
              secondFerry: denmarkRoute.secondFerry,
              secondFerryMinutes: denmarkRoute.secondFerryMinutes,
              startLabel: s,
              destinationLabel: d,
            )
          : await det.computeEtaWithOptionalFerry(
              startTime: start,
              alreadyDrivenMin: _drivenMin,
              alreadyDrivenSinceBreakMin: _continuousDrivenMin,
              dutyOffsetMin: _dutyOffsetMin,
              avgKmh: speedPlan.kmh,
              rules: driveRules,
              startAddress: s,
              endAddress: d,
              autoOrManualFerry: ferryCandidate,
              manualDeparture: _manualFerryDeparture,
              waypoints: routedWaypoints,
              verifiedKm: _avoidSerbia ? distKm : null,
              ferryRoadKmBefore: ferrySuggestion?.kmBefore,
              ferryRoadKmAfter: ferrySuggestion?.kmAfter,
              fallbackKm: km,
              ferryRestEligible: _ferryRestEligible,
            );
      _log.addAll(res.steps.map((e) => e.text));
      if (res.summary == null ||
          (res.summary!.distanceKm <= 0 &&
              ferryCandidate == null &&
              denmarkRoute == null)) {
        throw StateError('Keine verwertbare Routendistanz vorhanden');
      }
      if (!mounted) return;
      setState(() {
        _etaResult = res;
        _resultOrigin = s;
        _resultDestination = d;
        _resultRoadMix = roadMix;
        _resultRouteStops = routedWaypoints;
        _resultRoutePolyline = encodedPolyline;
        _countryRouteNote = _avoidSerbia ? note.split(' · 🛳️').first : null;
        _resultFerry = ferryCandidate;
        _resultViaDenmark = denmarkRoute != null;
        _ferryRouteNote = denmarkRoute != null
            ? 'Über Dänemark: zwei kurze Fähren eingeplant. ETA ohne Hafenwartezeit oder Buchungsabfahrt; vor der Fahrt bei beiden Betreibern prüfen.'
            : ferryCandidate == null
                ? null
                : _manualFerryDeparture == null
                    ? 'Fähre ${ferryCandidate.name}: frühestmögliche ETA ohne Hafenwartezeit. Gebuchte Abfahrt bitte im Fähre-Feld eintragen.'
                    : 'Fähre ${ferryCandidate.name}: Eingetragene Abfahrtszeit in der ETA berücksichtigt. Buchung und Verfügbarkeit beim Betreiber prüfen.';
      });
    } catch (error, stackTrace) {
      debugPrint('ETA-Berechnung fehlgeschlagen: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CountryRouteException
                  ? error.message
                  : error is FerryRouteException
                      ? error.message
                      : 'Route konnte nicht berechnet werden. Bitte Adressen, Distanz und Verbindung prüfen.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _calculating = false);
    }
  }

  void _dbg(String msg) {
    if (_showDetails) _log.add('🔍 $msg');
  }

  Widget _numField(String label, int value, void Function(int) onChanged) {
    final ctl = TextEditingController(text: value.toString());
    return TextField(
      controller: ctl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
      onChanged: (s) {
        onChanged(int.tryParse(s) ?? 0);
      },
    );
  }

  // Google encoded polyline -> List<LatLng>
  List<LatLng> _decodePolyline(String encoded) =>
      map_launcher.decodePolyline(encoded);

  Future<void> _openMapOsm() async {
    if (_avoidSerbia && _etaResult != null && _resultRoutePolyline != null) {
      final points = map_launcher.decodePolyline(_resultRoutePolyline!);
      if (points.length >= 2) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MapOsmView(
            start: points.first,
            dest: points.last,
            route: points,
          ),
        ));
        return;
      }
    }
    final routedStops = _etaResult == null ? _stops : _resultRouteStops;
    await map_launcher.openMapOsm(
      context,
      s: _startCtl.text.trim(),
      d: _destCtl.text.trim(),
      stops: routedStops,
      stopCoords: routedStops.length == _stopCoords.length
          ? _stopCoords
          : List<LatLng?>.filled(routedStops.length, null),
      startLat: _startLat,
      startLng: _startLng,
      destLat: _destLat,
      destLng: _destLng,
      optimizeStops: _optimizeStops,
      googleMapsApiKey: GOOGLE_MAPS_API_KEY,
      mapsDirectCallsAllowed: mapsDirectCallsAllowed,
      addLog: (m) => setState(() => _log.add(m)),
      showDetails: () => _showDetails,
      mounted: mounted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = const EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: const Row(
          children: [
            Icon(Icons.local_shipping_rounded, color: Color(0xFF69F0AE)),
            SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DriverRoute ETA',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                ),
                Text(
                  'LKW-Tourenplanung',
                  style: TextStyle(fontSize: 11, color: Color(0xFFBCCCDC)),
                ),
              ],
            ),
          ],
        ),
        centerTitle: false,
      ),
      body: LayoutBuilder(
        builder: (context, viewport) {
          final wideLayout = viewport.maxWidth >= 860;
          final formPane = ListView(
            padding: EdgeInsets.symmetric(vertical: wideLayout ? 14 : 8),
            children: [
              const _PageIntro(),
              if (_showDetails)
                Padding(
                  padding: pad,
                  child: Text(
                    'Fahrplan-Quelle: $_source · ${_routes.length} Routen',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Padding(
                padding: pad,
                child: _InputCard(
                  title: 'Route planen',
                  subtitle: 'Start und Ziel festlegen',
                  icon: Icons.route_rounded,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final stacked = constraints.maxWidth < 680;
                      final fieldWidth = stacked
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 12) / 2;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: fieldWidth,
                            child: PlaceInput(
                              inlineAutocomplete: true,
                              label: '📍 Startort/PLZ',
                              hint: 'Start eingeben',
                              controller: _startCtl,
                              initialText: _startCtl.text,
                              enableCurrentLocation: true,
                              onCoordinatesResolved: (lat, lng) => setState(() {
                                _startLat = lat;
                                _startLng = lng;
                              }),
                              onChanged: (v) => _startCtl.text = v,
                              onConfirmed: (v) async {
                                final txt = v.trim();
                                if (txt.isEmpty) return;
                                // store resolved preview (do not overwrite controller)
                                setState(() => _resolvedStart = txt);
                                // attempt to resolve coordinates for routing, but keep controller as-is
                                try {
                                  final r = await GeocodingService.resolve(txt);
                                  setState(() {
                                    _startLat = r.lat;
                                    _startLng = r.lng;
                                  });
                                  // debug
                                  print('preview resolved start: $txt');
                                } catch (e) {
                                  debugPrint(
                                      'start preview geocoding failed: $e');
                                }
                              },
                            ),
                          ),
                          SizedBox(
                            width: fieldWidth,
                            child: PlaceInput(
                              inlineAutocomplete: true,
                              label: '🏁 Zielort/PLZ',
                              hint: 'Ziel eingeben',
                              controller: _destCtl,
                              initialText: _destCtl.text,
                              originLat: _startLat,
                              originLng: _startLng,
                              onCoordinatesResolved: (lat, lng) => setState(() {
                                _destLat = lat;
                                _destLng = lng;
                              }),
                              onChanged: (v) => _destCtl.text = v,
                              onConfirmed: (v) async {
                                final txt = v.trim();
                                if (txt.isEmpty) return;
                                // store resolved preview (do not overwrite controller)
                                setState(() => _resolvedDestination = txt);
                                try {
                                  final r = await GeocodingService.resolve(txt);
                                  setState(() {
                                    _destLat = r.lat;
                                    _destLng = r.lng;
                                  });
                                  // debug
                                  print('preview resolved destination: $txt');
                                } catch (e) {
                                  debugPrint(
                                      'destination preview geocoding failed: $e');
                                }
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.add_location_alt_rounded),
                  title: const Text(
                    'Zwischenstopps',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text(
                    'Mehrere Orte in Fahrreihenfolge hinzufügen',
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PlaceInput(
                            inlineAutocomplete: true,
                            label: '📍 Weiterer Zwischenstopp',
                            hint: 'Adresse oder Ort eingeben',
                            controller: _stopCtl,
                            initialText: _stopCtl.text,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              onPressed: _addingStop ? null : _addStop,
                              icon: _addingStop
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.add_rounded),
                              label: const Text('Zwischenstopp hinzufügen'),
                            ),
                          ),
                          for (var index = 0; index < _stops.length; index++)
                            Card(
                              child: ListTile(
                                title: Text('${index + 1}. ${_stops[index]}'),
                                trailing: Wrap(
                                  spacing: 0,
                                  children: [
                                    IconButton(
                                      tooltip: 'Nach oben',
                                      onPressed: index == 0
                                          ? null
                                          : () => _moveStop(index, index - 1),
                                      icon: const Icon(Icons.arrow_upward),
                                    ),
                                    IconButton(
                                      tooltip: 'Nach unten',
                                      onPressed: index == _stops.length - 1
                                          ? null
                                          : () => _moveStop(index, index + 1),
                                      icon: const Icon(Icons.arrow_downward),
                                    ),
                                    IconButton(
                                      tooltip: 'Zwischenstopp entfernen',
                                      onPressed: () => _removeStop(index),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_stops.isNotEmpty)
                            const Text(
                              'Die Stopps werden in dieser Reihenfolge angefahren.',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: pad,
                child: Card(
                  child: SwitchListTile.adaptive(
                    secondary: const Icon(Icons.block_rounded),
                    title: const Text('Serbien für die Route sperren'),
                    subtitle: const Text(
                      'Optional. Für Griechenland–Österreich wird bei Bedarf automatisch über Bulgarien, Rumänien und Ungarn geplant. Die gelieferte Route wird geprüft.',
                    ),
                    value: _avoidSerbia,
                    onChanged: (value) => setState(() {
                      _avoidSerbia = value;
                      _etaResult = null;
                      _countryRouteNote = null;
                      _ferryRouteNote = null;
                    }),
                  ),
                ),
              ),
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text(
                    'Abfahrt und verbleibende Zeit',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  children: [
                    LayoutBuilder(
                      builder: (ctx, box) {
                        // bei schmalen Layouts untereinander
                        final stackVertically = box.maxWidth < 720;

                        final leftWidget = Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Zeitbudget für heute',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF4FF),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFFC9E1FA),
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Verbleibende Fahrzeit',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Bis zur nächsten Tagesruhe; eine Lenkpause kann früher nötig sein.',
                                    ),
                                    const SizedBox(height: 8),
                                    DurationInput(
                                      minutes: _remainingDrivingMin.clamp(
                                          0, _dailyDrivingLimit),
                                      maxMinutes: _dailyDrivingLimit,
                                      onChanged: (v) => setState(
                                          () => _remainingDrivingMin = v),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF8F3),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFFC7E7D9),
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Verbleibende Einsatzzeit',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Bis zur Tagesruhe (derzeit höchstens ${_dailyDutyLimit ~/ 60} Stunden).',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
                                    ),
                                    const SizedBox(height: 8),
                                    DurationInput(
                                      minutes: _remainingDutyMin.clamp(
                                          0, _dailyDutyLimit),
                                      maxMinutes: _dailyDutyLimit,
                                      onChanged: (v) =>
                                          setState(() => _remainingDutyMin = v),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Seit der letzten Lenkpause',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Nur falls heute bereits gefahren wurde.',
                                    ),
                                    const SizedBox(height: 8),
                                    DurationInput(
                                      minutes: _continuousDrivenMin,
                                      maxMinutes: 270,
                                      onChanged: (v) => setState(
                                          () => _continuousDrivenMin = v),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              _speedProfileInput(),
                            ],
                          ),
                        );

                        final rightWidget = Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color:
                                  Theme.of(context).colorScheme.outlineVariant,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Manuelle Abfahrt'),
                                subtitle: const Text(
                                  'Ausschalten für Abfahrt ab jetzt',
                                ),
                                value: _manualDepartureActive,
                                onChanged: (v) =>
                                    setState(() => _manualDepartureActive = v),
                              ),
                              if (_manualDepartureActive) ...[
                                const SizedBox(height: 10),
                                InkWell(
                                  onTap: () async {
                                    final selectedDate = await showDatePicker(
                                      context: context,
                                      initialDate: _manualDepartureDate,
                                      firstDate: DateTime.now()
                                          .subtract(const Duration(days: 365)),
                                      lastDate: DateTime.now()
                                          .add(const Duration(days: 365)),
                                    );
                                    if (selectedDate != null) {
                                      setState(() =>
                                          _manualDepartureDate = selectedDate);
                                    }
                                  },
                                  child: InputDecorator(
                                    decoration: InputDecoration(
                                      labelText: '📅 Datum',
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              vertical: 12, horizontal: 12),
                                    ),
                                    child: Text(DateFormat('yyyy-MM-dd')
                                        .format(_manualDepartureDate)),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.access_time_rounded),
                                  label: Text(
                                    'Abfahrtszeit ${_manualDepartureHour.toString().padLeft(2, '0')}:${_manualDepartureMinute.toString().padLeft(2, '0')}',
                                  ),
                                  onPressed: () async {
                                    final selected = await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay(
                                        hour: _manualDepartureHour,
                                        minute: _manualDepartureMinute,
                                      ),
                                      initialEntryMode:
                                          TimePickerEntryMode.input,
                                      builder: (context, child) => MediaQuery(
                                        data: MediaQuery.of(context).copyWith(
                                          alwaysUse24HourFormat: true,
                                        ),
                                        child: child!,
                                      ),
                                    );
                                    if (selected != null && mounted) {
                                      setState(() {
                                        _manualDepartureHour = selected.hour;
                                        _manualDepartureMinute =
                                            selected.minute;
                                      });
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                        );

                        if (stackVertically) {
                          return Column(
                            children: [
                              leftWidget,
                              const SizedBox(height: 12),
                              rightWidget
                            ],
                          );
                        }

                        return Row(
                          children: [
                            Expanded(child: leftWidget),
                            const SizedBox(width: 12),
                            Expanded(child: rightWidget),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),

              // --- Lenk-/Ruhezeit & Tankpause ---
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.rule_rounded),
                  title: const Text(
                    'Lenk- und Ruhezeiten',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Tippe, um Verfügbarkeit umzuschalten (hell = nicht verfügbar).',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('10h-Tag #1'),
                          selected: _ten1,
                          onSelected: (v) =>
                              _changeDrivingLimit(() => _ten1 = v),
                        ),
                        FilterChip(
                          label: const Text('10h-Tag #2'),
                          selected: _ten2,
                          onSelected: (v) =>
                              _changeDrivingLimit(() => _ten2 = v),
                        ),
                        FilterChip(
                          label: const Text('9h-Ruhe #1'),
                          selected: _nine1,
                          onSelected: (v) => _changeDutyLimit(() => _nine1 = v),
                        ),
                        FilterChip(
                          label: const Text('9h-Ruhe #2'),
                          selected: _nine2,
                          onSelected: (v) => _changeDutyLimit(() => _nine2 = v),
                        ),
                        FilterChip(
                          label: const Text('9h-Ruhe #3'),
                          selected: _nine3,
                          onSelected: (v) => _changeDutyLimit(() => _nine3 = v),
                        ),
                        FilterChip(
                          label: const Text('⛽ Tankpause +30 min'),
                          selected: _tankpause,
                          onSelected: (v) => setState(() => _tankpause = v),
                        ),
                        FilterChip(
                          label: const Text('Geteilte Pause 15 + 30 min'),
                          selected: _splitBreak,
                          onSelected: (v) => setState(() => _splitBreak = v),
                        ),
                        FilterChip(
                          label: const Text('Wochenruhe vor Abfahrt fällig'),
                          selected: _weeklyRestDue,
                          onSelected: (v) => setState(() => _weeklyRestDue = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),

              // --- Fähre ---
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.directions_boat_rounded),
                  title: const Text(
                    'Fähre',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  children: [
                    SwitchListTile(
                      title: const Text('Fähre automatisch vorschlagen'),
                      subtitle: const Text(
                        'Für Griechenland–Italien sowie Deutschland/Österreich–Schweden/Norwegen werden erreichbare Häfen ohne Zwischenstopp verglichen. Buchung separat beim Anbieter prüfen.',
                      ),
                      value: _autoFerry,
                      onChanged: (v) => setState(() {
                        _autoFerry = v;
                        if (v) _viaDenmarkFerries = false;
                        _etaResult = null;
                      }),
                    ),
                    SwitchListTile(
                      title: const Text('Alternative über Dänemark: 2 Fähren'),
                      subtitle: const Text(
                        'Helsingborg–Helsingør und Rødby–Puttgarden. Nur Deutschland–Schweden; Wartezeiten und Buchungen separat.',
                      ),
                      value: _viaDenmarkFerries,
                      onChanged: (v) => setState(() {
                        _viaDenmarkFerries = v;
                        if (v) {
                          _autoFerry = false;
                          _manualFerry = null;
                          _manualFerryDeparture = null;
                        }
                        _etaResult = null;
                      }),
                    ),
                    SwitchListTile(
                      title: const Text('Schlafkabine/Liegeplatz verfügbar'),
                      subtitle: const Text(
                        'Nur dann kann die Zeit an Bord als Ruhezeit gewertet werden.',
                      ),
                      value: _ferryRestEligible,
                      onChanged: (value) =>
                          setState(() => _ferryRestEligible = value),
                    ),
                    // WICHTIG: Kein "null"-DropdownItem, stattdessen hint verwenden
                    // --- Fähre Auswahl (mit robustem initialValue + Reset) ---
                    Builder(builder: (ctx) {
                      final selectedFerry =
                          _routes.contains(_manualFerry) ? _manualFerry : null;
                      return Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<FerryRoute>(
                              key: ValueKey(selectedFerry?.id ?? 'no-ferry'),
                              isExpanded: true,
                              initialValue: selectedFerry,
                              hint: const Text('Keine'),
                              decoration: const InputDecoration(
                                labelText: 'Manuelle Fährwahl (optional)',
                              ),
                              items: _routes
                                  .map((r) => DropdownMenuItem<FerryRoute>(
                                        value: r,
                                        child: Text(r.name),
                                      ))
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _manualFerry = v;
                                if (v != null) _viaDenmarkFerries = false;
                                _etaResult = null;
                              }),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Auswahl zurücksetzen',
                            onPressed: () => setState(() {
                              _manualFerry = null;
                              _manualFerryDeparture = null;
                              _etaResult = null;
                            }),
                            icon: const Icon(Icons.clear),
                          ),
                        ],
                      );
                    }),
                    if (_manualFerry != null || _autoFerry)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Gebuchte Fährabfahrt',
                                style: Theme.of(context).textTheme.titleMedium),
                            const Text(
                              'Datum und Uhrzeit nach der Buchung eintragen. Ohne Eingabe ist die ETA nur vorläufig.',
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                SizedBox(
                                  width: 176,
                                  child: GestureDetector(
                                    onTap: () async {
                                      final now = DateTime.now();
                                      final d = await showDatePicker(
                                        context: context,
                                        firstDate: now,
                                        lastDate:
                                            now.add(const Duration(days: 365)),
                                        initialDate:
                                            _manualFerryDeparture ?? now,
                                      );
                                      if (d == null) return;
                                      setState(() {
                                        final prev = _manualFerryDeparture ??
                                            DateTime.now();
                                        _manualFerryDeparture = DateTime(
                                            d.year,
                                            d.month,
                                            d.day,
                                            prev.hour,
                                            prev.minute);
                                        _etaResult = null;
                                      });
                                    },
                                    child: InputDecorator(
                                      decoration: InputDecoration(
                                        labelText: '📅 Datum',
                                        border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                vertical: 12, horizontal: 12),
                                      ),
                                      child: Text(_manualFerryDeparture == null
                                          ? 'Kein Datum'
                                          : DateFormat('yyyy-MM-dd')
                                              .format(_manualFerryDeparture!)),
                                    ),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.access_time_rounded),
                                  label: Text(_manualFerryDeparture == null
                                      ? 'Uhrzeit wählen'
                                      : DateFormat('HH:mm')
                                          .format(_manualFerryDeparture!)),
                                  onPressed: () async {
                                    final initial =
                                        _manualFerryDeparture ?? DateTime.now();
                                    final selected = await showTimePicker(
                                      context: context,
                                      initialTime:
                                          TimeOfDay.fromDateTime(initial),
                                      initialEntryMode:
                                          TimePickerEntryMode.input,
                                      builder: (context, child) => MediaQuery(
                                        data: MediaQuery.of(context).copyWith(
                                          alwaysUse24HourFormat: true,
                                        ),
                                        child: child!,
                                      ),
                                    );
                                    if (selected == null || !mounted) return;
                                    setState(() {
                                      _manualFerryDeparture = DateTime(
                                        initial.year,
                                        initial.month,
                                        initial.day,
                                        selected.hour,
                                        selected.minute,
                                      );
                                      _etaResult = null;
                                    });
                                  },
                                ),
                                if (_manualFerryDeparture != null)
                                  TextButton(
                                    onPressed: () => setState(() {
                                      _manualFerryDeparture = null;
                                      _etaResult = null;
                                    }),
                                    child: const Text('Zeit zurücksetzen'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (_manualFerryDeparture != null)
                              Text(
                                'Manuelle Abfahrtszeit: ${DateFormat('dd.MM. HH:mm').format(_manualFerryDeparture!)}',
                                style: const TextStyle(color: Colors.black54),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: pad,
                child: FilledButton.icon(
                  icon: _calculating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.route),
                  label: Text(_calculating
                      ? 'Route wird berechnet …'
                      : 'Route berechnen'),
                  onPressed: _calculating ? null : _compute,
                ),
              ),
              if (!wideLayout && _etaResult != null)
                Padding(
                  padding: pad,
                  child: TourResultView(
                    result: _etaResult!,
                    origin: _resultOrigin,
                    destination: _resultDestination,
                    roadMix: _resultRoadMix,
                  ),
                ),
              if (_etaResult != null && _countryRouteNote != null)
                Padding(
                  padding: pad,
                  child: Card(
                    color: const Color(0xFFE5F6EF),
                    child: ListTile(
                      leading: const Icon(Icons.verified_rounded,
                          color: Color(0xFF087F5B)),
                      title: Text(_countryRouteNote!),
                      subtitle: const Text(
                        'Karten- und Grenzdaten sind eine Planungshilfe; Grenzverlauf vor der Fahrt prüfen.',
                      ),
                    ),
                  ),
                ),
              if (!wideLayout && _etaResult != null && _ferryRouteNote != null)
                Padding(
                  padding: pad,
                  child: _ferryNoticeCard(),
                ),
              const SizedBox(height: 8),
              Padding(
                padding: pad,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.map),
                  label: Text(_etaResult != null &&
                          (_resultFerry != null || _resultViaDenmark)
                      ? 'Fährroute: Karte derzeit nicht verfügbar'
                      : 'Karte anzeigen'),
                  onPressed: (_avoidSerbia && _etaResult == null) ||
                          (_etaResult != null &&
                              (_resultFerry != null || _resultViaDenmark))
                      ? null
                      : () {
                          // Ensure window.open is triggered synchronously from user gesture to avoid popup blocking on web
                          if (kIsWeb) {
                            if ((_etaResult == null
                                    ? _stops
                                    : _resultRouteStops)
                                .isEmpty) {
                              // ignore: avoid_print
                              print('[MapButton] using external web tab');
                              openInNewTabWithName(
                                  'about:blank', 'driverroute_map');
                            } else {
                              // ignore: avoid_print
                              print(
                                  '[MapButton] using in-app map because waypoints are present');
                            }
                          }
                          _openMapOsm();
                        },
                ),
              ),
              if (kDebugMode)
                Padding(
                  padding: pad,
                  child: SwitchListTile(
                    value: _showDetails,
                    onChanged: (v) => setState(() => _showDetails = v),
                    title: const Text('🔧 Details/Debug anzeigen'),
                    subtitle: const Text('Technische Hinweise ein-/ausblenden'),
                  ),
                ),
              if (kDebugMode && _showDetails && _log.isNotEmpty)
                Padding(
                  padding: pad,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('📋 Fahrplan:',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final l in _log)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(l),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 24),
            ],
          );

          if (!wideLayout) {
            final mobileWidth =
                viewport.maxWidth > 820 ? 820.0 : viewport.maxWidth;
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: mobileWidth, child: formPane),
            );
          }

          final inputWidth =
              (viewport.maxWidth * 0.42).clamp(380.0, 540.0).toDouble();
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: inputWidth, child: formPane),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(child: _buildDesktopResultPane()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDesktopResultPane() {
    if (_etaResult == null) {
      return const _DesktopEmptyResult();
    }
    return ColoredBox(
      color: const Color(0xFFF6F8FB),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 36),
        children: [
          TourResultView(
            result: _etaResult!,
            origin: _resultOrigin,
            destination: _resultDestination,
            roadMix: _resultRoadMix,
          ),
          if (_ferryRouteNote != null) ...[
            const SizedBox(height: 12),
            _ferryNoticeCard(),
          ],
        ],
      ),
    );
  }

  Widget _ferryNoticeCard() => Card(
        color: const Color(0xFFFFF4E8),
        child: ListTile(
          leading: const Icon(Icons.directions_boat_rounded,
              color: Color(0xFFB45309)),
          title: Text(_ferryRouteNote!),
        ),
      );

  Widget _slider(
    String label,
    double value,
    int min,
    int max,
    void Function(double) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Slider.adaptive(
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: (max - min),
                value: value
                    .clamp(min.toDouble(), max.toDouble())
                    .toDouble(), // cast wichtig
                label: value.round().toString(),
                onChanged: (v) => onChanged(v),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 56,
              child: Center(
                child: Text(
                  '${value.round()} km/h',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _speedProfileInput() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Geschwindigkeitsprofil',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final profile in SpeedProfile.values)
                ChoiceChip(
                  label: Text(profile.label),
                  selected: _speedProfile == profile,
                  onSelected: (_) => setState(() => _speedProfile = profile),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _speedProfile.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_speedProfile == SpeedProfile.custom) ...[
            const SizedBox(height: 6),
            _slider(
              'Eigener Planungsschnitt',
              _avgKmh,
              40,
              90,
              (v) => setState(() => _avgKmh = v),
            ),
          ],
        ],
      ),
    );
  }
}

class _PageIntro extends StatelessWidget {
  const _PageIntro();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tour vorbereiten',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: const Color(0xFF102A43),
                  fontWeight: FontWeight.w900,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            'Route, Lenkzeiten und Pausen in wenigen Schritten planen.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF627D98),
                ),
          ),
        ],
      ),
    );
  }
}

class _InputCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  const _InputCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD9E2EC)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D102A43),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF4FF),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF0A6EBD)),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF102A43),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF627D98),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _DesktopEmptyResult extends StatelessWidget {
  const _DesktopEmptyResult();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF6F8FB),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFD9E2EC)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 78,
                    height: 78,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE8F5EE),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.route_rounded,
                      size: 40,
                      color: Color(0xFF087F5B),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Deine Tourübersicht',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: const Color(0xFF102A43),
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Nach der Berechnung erscheinen hier ETA, Straßenmix, '
                    'Lenkpausen, Ruhezeiten und der komplette Tourablauf.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF627D98), height: 1.45),
                  ),
                  const SizedBox(height: 20),
                  const Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        avatar: Icon(Icons.flag_rounded, size: 17),
                        label: Text('Ankunft'),
                      ),
                      Chip(
                        avatar: Icon(Icons.coffee_rounded, size: 17),
                        label: Text('Pausen'),
                      ),
                      Chip(
                        avatar: Icon(Icons.add_road_rounded, size: 17),
                        label: Text('Straßenmix'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
