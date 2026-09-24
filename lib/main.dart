// lib/main.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'services/maps_proxy.dart';
import 'services/catlab_trace.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'models/ferry_route.dart';
import 'services/ferry_schedule_loader.dart';
import 'logic/eta_calculator.dart';
import 'logic/ferry_auto.dart';
import 'logic/ferry_route_suggester.dart';
import 'logic/ferry_route_search.dart';
import 'logic/denmark_ferry_route.dart';
import 'logic/port_aliases.dart';
import 'logic/ferry_leg_plan.dart';
import 'logic/ferry_schedule.dart';
import 'logic/speed_profile.dart';
import 'logic/truck_speed.dart';
import 'logic/time_budget.dart';
import 'models/route_candidate.dart';
import 'models/route_preset.dart';
import 'services/route_preset_store.dart';
import 'widgets/route_preset_selector.dart';
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
  // Fahrplanzeiten gelten in der Ortszeit des Hafens.
  tz_data.initializeTimeZones();
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
  final _ferrySearchCtl = TextEditingController();
  final List<String> _stops = [];
  final List<LatLng?> _stopCoords =
      []; // parallel storage for resolved stop coordinates
  bool _addingStop = false;
  final bool _optimizeStops = false;
  /// LKW-Fahrzeit der zuletzt geplanten Route, aus den Google-Etappen
  /// abgeleitet. Null, solange keine Etappendaten vorliegen (z. B. wenn die
  /// Strecke nur aus Fährabschnitten besteht).
  TruckDriveTime? _truckTime;

  /// Die beiden Landwege um die geplante Fähre. Trägt die echten Kilometer
  /// und die Geometrie, die die Karte braucht.
  FerryLegPlan? _ferryLegPlan;

  /// Gespeicherte Wegpunkt-Folgen für wiederkehrende Strecken.
  List<RoutePreset> _presets = [];
  List<String> _resultRouteStops = [];
  String? _resultRoutePolyline;
  String? _countryRouteNote;
  String? _ferryRouteNote;
  FerryRoute? _resultFerry;
  bool _resultViaDenmark = false;

  double _avgKmh = 80;
  SpeedProfile _speedProfile = SpeedProfile.automatic;

  /// Voll beladen geht am Berg Zeit verloren – Googles PKW-Zeiten kennen das
  /// nicht.
  bool _heavyLoad = false;
  int _remainingDrivingMin = 600;
  int _continuousDrivenMin = 0;
  int _remainingDutyMin = 900;

  /// Welcher Wert des Zeitbudgets gerade bearbeitet wird (0/1/2), sonst null.
  int? _editingBudget;

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
    _loadPresets();
  }

  @override
  void dispose() {
    _startCtl.dispose();
    _destCtl.dispose();
    _kmCtl.dispose();
    _stopCtl.dispose();
    _ferrySearchCtl.dispose();
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
      _ferryLegPlan = null;
    });
  }

  Future<void> _loadPresets() async {
    final loaded = await RoutePresetStore.load();
    if (!mounted) return;
    setState(() => _presets = loaded);
  }

  /// Übernimmt eine Vorlage als Zwischenstopps. Die bisherigen Stopps werden
  /// ersetzt – eine Vorlage beschreibt die ganze Durchfahrt, nicht einen
  /// Zusatz.
  void _applyPreset(RoutePreset preset, {required bool reverse}) {
    final applied = reverse ? preset.reversed : preset;
    setState(() {
      _stops
        ..clear()
        ..addAll(applied.stops);
      _stopCoords
        ..clear()
        ..addAll(List<LatLng?>.filled(applied.stops.length, null));
      _etaResult = null;
      _ferryLegPlan = null;
      _ferryRouteNote = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${applied.name}${reverse ? ' (umgekehrt)' : ''}: '
            '${applied.stops.length} Stopps übernommen.'),
      ),
    );
  }

  Future<void> _saveCurrentAsPreset(String name) async {
    if (_stops.isEmpty) return;
    if (_presets.length >= RoutePresetStore.maxPresets) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Höchstens ${RoutePresetStore.maxPresets} Vorlagen '
              'sind möglich.'),
        ),
      );
      return;
    }
    final preset = RoutePreset(
      id: 'p${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      stops: List<String>.of(_stops),
    );
    final next = [..._presets, preset];
    setState(() => _presets = next);
    await RoutePresetStore.save(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Vorlage "$name" gespeichert.')),
    );
  }

  Future<void> _deletePreset(RoutePreset preset) async {
    final next = _presets.where((p) => p.id != preset.id).toList();
    setState(() => _presets = next);
    await RoutePresetStore.save(next);
  }

  void _moveStop(int from, int to) {
    if (to < 0 || to >= _stops.length) return;
    setState(() {
      final stop = _stops.removeAt(from);
      final coordinate = _stopCoords.removeAt(from);
      _stops.insert(to, stop);
      _stopCoords.insert(to, coordinate);
      _etaResult = null;
      _ferryLegPlan = null;
    });
  }

  void _removeStop(int index) {
    setState(() {
      _stops.removeAt(index);
      _stopCoords.removeAt(index);
      _etaResult = null;
      _ferryLegPlan = null;
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
    DateTime departureTime,
  ) async {
    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
    _truckTime = null;
    _ferryLegPlan = null;

    if (_viaDenmarkFerries) {
      if (wps.isNotEmpty) {
        throw const FerryRouteException(
          'Die Dänemark-Variante ist derzeit nur ohne eigene Zwischenstopps verfügbar.',
        );
      }
      CatLabTrace.markFerry();
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

    if (_autoFerry && _manualFerry == null && wps.isEmpty) {
      final suggestion = await FerryRouteSuggester.suggest(
        origin: origin,
        destination: destination,
        routes: _routes,
        // Ohne avoidFerries schmuggelt Google in den Landweg zum Hafen
        // eigene Überfahrten und die Kilometer stimmen nicht.
        roadDistance: (from, to) => const DistanceService().fetchKmDistance(
            origin: from, destination: to, avoidFerries: true),
        startTime: departureTime,
      );
      if (suggestion != null) {
        return _withFerryLegs(
          det,
          origin,
          destination,
          suggestion.route,
          fallback: suggestion,
          note: 'Fähre automatisch vorgeschlagen: ${suggestion.route.name}. '
              'Fahrplan vor Buchung prüfen.',
        );
      }
      if (FerryRouteSuggester.supportsTrip(origin, destination)) {
        throw const FerryRouteException(
          'Für diese Strecke konnte keine erreichbare Fähre geprüft werden. Bitte Verbindung prüfen oder eine Fähre manuell wählen.',
        );
      }
    }

    // Manuell gewählte Fähre: dieselben zwei Landwege, damit Kilometer und
    // Karte zur gewählten Verbindung passen statt zu Googles eigener.
    final manual = _manualFerry;
    if (manual != null) {
      return _withFerryLegs(
        det,
        origin,
        destination,
        manual,
        stops: wps,
        note: 'Fähre manuell gewählt: ${manual.name}.',
      );
    }

    // --- Routenplanung -------------------------------------------------
    // Eine Anfrage mit genau den Wegpunkten, die der Fahrer gesetzt hat –
    // direkt oder über eine gespeicherte Routen-Vorlage.
    final routedWaypoints = List<String>.of(wps);
    final res = await det.fetchDirections(
      origin: origin,
      destination: destination,
      waypoints: wps,
      optimize: optimize,
    );
    final planStatus = res.status;
    final RouteCandidate? route =
        res.ok && res.candidates.isNotEmpty ? res.candidates.first : null;

    // Ab hier ist genau diese eine Route die Grundlage für alles Weitere:
    // km, Fahrzeit, Straßenmix, ETA, Timeline, Karte und Export.
    final DirectionsFetchResult normal = DirectionsFetchResult(
      ok: route != null,
      status: planStatus,
      km: route?.km ?? 0,
      sec: route?.sec ?? 0,
      steps: route?.steps ?? const [],
      warnings: route?.warnings ?? const [],
      raw: route?.raw ?? const {},
    );

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
        // Hier und nur hier steht fest, dass diese Berechnung eine Fähre
        // benutzt. Alles danach – die getrennten Landwege vor und nach der
        // Überfahrt – kostet zusätzliche Google-Aufrufe. Damit die Auswertung
        // Fähr- und Straßenrouten nicht vermischt, wird die Berechnung ab
        // hier als Fährroute geführt.
        CatLabTrace.markFerry();
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

    // LKW-Fahrzeit je Etappe aus Googles Step-Daten.
    if (route != null && route.steps.isNotEmpty && route.km > 0) {
      final truck = truckDriveTimeFromSteps(
        steps: route.steps,
        totalKm: route.km,
        // Für Teilstrecken ohne Etappendaten der eingestellte Schnitt.
        fallbackKmh: _avgKmh,
      );
      _truckTime = truck;
      if (!truck.isComplete) {
        final fehlend = truck.km - truck.coveredKm;
        _log.add('ℹ️ Für ${fehlend.toStringAsFixed(0)} km lagen keine '
            'Etappendaten vor – dort mit ${_avgKmh.toStringAsFixed(0)} km/h '
            'gerechnet.');
      }
      if (_showDetails) {
        final h = truck.minutes ~/ 60, m = truck.minutes % 60;
        final gh = truck.googleMinutes ~/ 60, gm = truck.googleMinutes % 60;
        _log.add('🚛 LKW-Fahrzeit ${h}h${m.toString().padLeft(2, '0')} statt '
            '${gh}h${gm.toString().padLeft(2, '0')} laut Google '
            '(Ø ${truck.avgKmh.toStringAsFixed(1)} km/h)');
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
      hasFerry ? '🛳️ Fähre erkannt ($why)' : '',
      routedWaypoints,
      // Geometrie GENAU der Route, aus der oben km, Fahrzeit und Straßenmix
      // stammen – Grundlage für Karte, Timeline und Export.
      (route?.raw['overview_polyline'] as Map<String, dynamic>?)?['points']
          as String?,
      null,
      null,
    );
  }

  /// Baut aus der gewählten Fähre die beiden Landwege und liefert damit
  /// echte Kilometer, echte LKW-Fahrzeit und die Geometrie für die Karte.
  ///
  /// Fällt der Abruf aus, wird auf die bisherige Schätzung des Suggesters
  /// zurückgegriffen – dann fehlt der Karte allerdings die Streckenführung.
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
      )> _withFerryLegs(
    FerryAutoDetect det,
    String origin,
    String destination,
    FerryRoute ferry, {
    FerryRouteSuggestion? fallback,
    required String note,
    List<String> stops = const [],
  }) async {
    // Eine Faehrroute kostet mehr Google-Aufrufe als eine durchgehende
    // Strecke: zwei getrennte Landwege statt einem. Damit die Auswertung
    // spaeter nicht Aepfel mit Birnen vergleicht, wird sie eigens vermerkt.
    CatLabTrace.markFerry();

    final plan = await FerryLegPlan.plan(
      origin: origin,
      destination: destination,
      ferry: ferry,
      det: det,
      stops: stops,
      stopCoords: _stopCoords,
    );

    if (plan == null) {
      _log.add('⚠️ Landwege zur Fähre konnten nicht abgerufen werden – '
          'gerechnet mit geschätzten Kilometern, die Karte zeigt keine '
          'geplante Strecke.');
      return (
        fallback?.roadKm ?? 0.0,
        null,
        ferry,
        note,
        <String>[],
        null,
        fallback,
        null,
      );
    }

    _ferryLegPlan = plan;
    _truckTime = truckDriveTimeFromSteps(
      steps: plan.steps,
      totalKm: plan.roadKm,
      fallbackKmh: _avgKmh,
    );
    if (_showDetails) {
      _log.add('🛣️ Landwege: ${plan.legA.km.toStringAsFixed(0)} km bis '
          '${plan.ferry.from}, ${plan.legB.km.toStringAsFixed(0)} km ab '
          '${plan.ferry.to} – zusammen ${plan.roadKm.toStringAsFixed(0)} km '
          'ohne Seestrecke.');
      if (plan.routedStops.isNotEmpty) {
        _log.add('📍 Zwischenstopps: '
            '${plan.stopsBefore.isEmpty ? "keine" : plan.stopsBefore.join(", ")} '
            'vor der Fähre, '
            '${plan.stopsAfter.isEmpty ? "keine" : plan.stopsAfter.join(", ")} '
            'danach.');
      }
    }

    return (
      plan.roadKm,
      RoadMixAnalysis.fromDirectionsSteps(plan.steps),
      plan.ferry,
      note,
      plan.routedStops,
      null,
      FerryRouteSuggestion(plan.ferry, plan.legA.km, plan.legB.km),
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
      _ferryLegPlan = null;
      _countryRouteNote = null;
      _ferryRouteNote = null;
    });

    // Ab hier gehoeren alle Google-Aufrufe zu dieser einen Berechnung.
    CatLabTrace.begin();

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
      ) = await _planDistanceAndFerryAuto(
        s,
        d,
        _stops,
        _optimizeStops,
        start,
      );

      // Googles Durchschnittstempo über die ganze Route ist zu optimistisch:
      // es mittelt 120 auf der Autobahn mit 50 auf der Landstraße. Der LKW
      // fährt auf dem Autobahnteil aber nur 80 und auf der Landstraße genauso
      // langsam. Deshalb je Abschnitt deckeln.
      final truckTime = _truckTime;
      final speedPlan = SpeedProfileResolver.resolve(
        profile: _speedProfile,
        customKmh: _avgKmh,
        routedKmh: truckTime?.avgKmh ?? roadMix?.averageKmh,
        routeLabels: [s, d, ..._stops],
        heavyLoad: _heavyLoad,
      );

      // debug
      // ignore: avoid_print
      print(
          '[Compute] planDistanceAndFerryAuto -> distKm=$distKm '
          'googleKmh=${roadMix?.averageKmh?.toStringAsFixed(1)} '
          'lkwKmh=${truckTime?.avgKmh.toStringAsFixed(1)} '
          'note=$note matchedFerry=${matchedFerry?.name}');

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
      // Bei einer von Hand gewählten Fähre läuft die Erkennung oben nicht an,
      // die Fährstrecke wird trotzdem gerechnet.
      if (ferryCandidate != null) CatLabTrace.markFerry();

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
              // Die Kilometer stehen aus der Routenplanung oben bereits fest.
              // Ohne sie würde die ETA dieselbe Strecke ein zweites Mal bei
              // Google abfragen – ein überflüssiger Directions-Request je
              // Berechnung.
              //
              // Auf eine Dezimalstelle gerundet wie bisher der DistanceService,
              // damit die Fahrzeit auf die Minute genau dieselbe bleibt.
              // Bei 0 (Directions fehlgeschlagen) greift wie bisher fallbackKm.
              verifiedKm: distKm > 0 ? (distKm * 10).round() / 10.0 : null,
              ferryRoadKmBefore: ferrySuggestion?.kmBefore,
              ferryRoadKmAfter: ferrySuggestion?.kmAfter,
              fallbackKm: km,
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
        _countryRouteNote = null;
        _resultFerry = ferryCandidate;
        _resultViaDenmark = denmarkRoute != null;
        _ferryRouteNote = denmarkRoute != null
            ? 'Über Dänemark: zwei kurze Fähren eingeplant. ETA ohne Hafenwartezeit oder Buchungsabfahrt; vor der Fahrt bei beiden Betreibern prüfen.'
            : ferryCandidate == null
                ? null
                : _manualFerryDeparture == null
                    ? 'Fähre ${ferryCandidate.name}: gerechnet mit der ersten planmäßigen Abfahrt nach der Hafenankunft (Ortszeit des Hafens). Fahrplan ist ein Richtwert – gebuchte Abfahrt bitte im Fähre-Feld eintragen.'
                    : 'Fähre ${ferryCandidate.name}: Eingetragene Abfahrtszeit in der ETA berücksichtigt. Buchung und Verfügbarkeit beim Betreiber prüfen.';
      });
    } catch (error, stackTrace) {
      debugPrint('ETA-Berechnung fehlgeschlagen: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FerryRouteException
                  ? error.message
                  : 'Route konnte nicht berechnet werden. Bitte Adressen, Distanz und Verbindung prüfen.',
            ),
          ),
        );
      }
    } finally {
      CatLabTrace.end();
      if (mounted) setState(() => _calculating = false);
    }
  }

  void _dbg(String msg) {
    if (_showDetails) _log.add('🔍 $msg');
  }

  /// Ein einzelner Vorrat als Punkt. Blau mit Haken heißt vorhanden,
  /// hellgrau heißt verbraucht. Der Punkt ist klein, die Tippfläche nicht –
  /// im Fahrerhaus wird das mit dem Daumen bedient.
  Widget _reserveDot({
    required bool available,
    required String semantik,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      label: semantik,
      toggled: available,
      button: true,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: SizedBox(
          width: 36,
          height: 32,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: available
                    ? theme.colorScheme.primary
                    : theme.colorScheme.surfaceContainerHighest,
                border: Border.all(
                  color:
                      available ? theme.colorScheme.primary : theme.dividerColor,
                  width: 1.5,
                ),
              ),
              child: available
                  ? Icon(Icons.check,
                      size: 15, color: theme.colorScheme.onPrimary)
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  /// Eine Zeile Vorrat: Bezeichnung, die Punkte, und rechts wie viele davon
  /// noch übrig sind. Zwei solche Zeilen ersetzen fünf Schaltflächen.
  Widget _reserveRow({
    required String label,
    required List<bool> values,
    required void Function(int index, bool value) onToggle,
  }) {
    final theme = Theme.of(context);
    final frei = values.where((v) => v).length;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (var i = 0; i < values.length; i++)
          _reserveDot(
            available: values[i],
            semantik:
                '$label ${i + 1}, ${values[i] ? "verfügbar" : "verbraucht"}',
            onTap: () => onToggle(i, !values[i]),
          ),
        const SizedBox(width: 6),
        SizedBox(
          width: 30,
          child: Text(
            '$frei/${values.length}',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: frei == 0 ? theme.disabledColor : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  /// Eine Vorgabe für diese eine Tour: ausgewählt heißt aktiv.
  Widget _optionChip(
    IconData icon,
    String label,
    bool active,
    void Function(bool) onChanged,
  ) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(label),
      selected: active,
      onSelected: onChanged,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        icon,
        size: 17,
        color: active ? theme.colorScheme.primary : theme.disabledColor,
      ),
      labelStyle: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }

  /// Zusammenfassung für die zugeklappte Box, damit der Stand sichtbar ist,
  /// ohne sie aufzuklappen.
  String get _ruleSummary {
    final tage = (_ten1 ? 1 : 0) + (_ten2 ? 1 : 0);
    final ruhen = (_nine1 ? 1 : 0) + (_nine2 ? 1 : 0) + (_nine3 ? 1 : 0);
    final teile = <String>['$tage × 10 h', '$ruhen × 9 h'];
    if (_tankpause) teile.add('Tankpause');
    if (_splitBreak) teile.add('geteilte Pause');
    if (_weeklyRestDue) teile.add('Wochenruhe fällig');
    return teile.join(' · ');
  }

  /// Abschnittsüberschrift in Versalien. Steht als Titel IN der Kachel und
  /// nicht darüber, damit die ganze Kopfzeile antippbar bleibt.
  Widget _kapitel(String text) => Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
              color: const Color(0xFF486581),
            ),
      );

  /// Der Stand, der unter der Überschrift steht, solange zugeklappt ist.
  Widget _stand(String text) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF102A43),
              fontWeight: FontWeight.w600,
            ),
      );

  String get _stopsSummary => _stops.isEmpty
      ? 'Keine'
      : '${_stops.length} · ${_stops.take(2).join(', ')}'
          '${_stops.length > 2 ? ' …' : ''}';

  String get _ferrySummary {
    final manuell = _manualFerry;
    if (manuell != null) {
      final ab = _manualFerryDeparture;
      return ab == null
          ? manuell.name
          : '${manuell.name} · ab ${_zweistellig(ab.hour)}:'
              '${_zweistellig(ab.minute)}';
    }
    if (_viaDenmarkFerries) return 'Über Dänemark, zwei Fähren';
    return _autoFerry ? 'Automatisch vorschlagen' : 'Keine';
  }

  static String _hhmm(int minuten) =>
      '${minuten ~/ 60}:${(minuten % 60).toString().padLeft(2, '0')}';

  /// Kurzform des Geschwindigkeitsprofils für Chips und Zusammenfassung.
  /// Die Zahlen stehen unter der Überschrift „Geschwindigkeit“ und sind
  /// damit als km/h lesbar, ohne die Einheit fünfmal zu wiederholen.
  static String _profilKurz(SpeedProfile p) => switch (p) {
        SpeedProfile.automatic => 'Automatisch',
        SpeedProfile.standard80 => '80',
        SpeedProfile.mixedRoads70 => '70',
        SpeedProfile.norway60 => '60',
        SpeedProfile.custom => 'Individuell',
      };

  /// Was zugeklappt unter der Überschrift steht.
  String get _zeitSummary {
    final teile = <String>[
      'Fahrzeit ${_hhmm(_remainingDrivingMin)}',
      'Einsatz ${_hhmm(_remainingDutyMin)}',
    ];
    if (_continuousDrivenMin > 0) {
      teile.add('seit Pause ${_hhmm(_continuousDrivenMin)}');
    }
    // „ab jetzt“ ist der Normalfall und damit keine Nachricht wert; die
    // Zeile ist auf dem Telefon ohnehin knapp.
    if (_manualDepartureActive) {
      teile.add('ab ${_zweistellig(_manualDepartureHour)}:'
          '${_zweistellig(_manualDepartureMinute)}');
    }
    // Wie oben: nur melden, was vom Normalfall abweicht. Sonst passt die
    // Zeile auf dem Telefon nicht mehr und wird abgeschnitten.
    if (_speedProfile != SpeedProfile.automatic) {
      teile.add(_profilKurz(_speedProfile));
    }
    if (_heavyLoad) teile.add('schwere Ladung');
    return teile.join(' · ');
  }

  static String _zweistellig(int n) => n.toString().padLeft(2, '0');

  /// Ein Wert des Zeitbudgets. Zeigt nur die Zahl; die Eingabefelder
  /// erscheinen erst, wenn jemand darauf tippt. Vorher standen hier
  /// dauerhaft sechs Stunden-/Minuten-Felder.
  Widget _budgetTile({
    required int index,
    required String label,
    required int minuten,
    required String hinweis,
  }) {
    final theme = Theme.of(context);
    final offen = _editingBudget == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _editingBudget = offen ? null : index),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: offen
                ? theme.colorScheme.primary.withValues(alpha: 0.10)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _hhmm(minuten),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                hinweis,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Die Eingabe zum angetippten Wert. Nur einer ist gleichzeitig offen.
  Widget _budgetEditor() {
    final theme = Theme.of(context);
    final (titel, beschreibung, minuten, maxMinuten, setzen) =
        switch (_editingBudget!) {
      0 => (
          'Verbleibende Fahrzeit',
          'Bis zur nächsten Tagesruhe; eine Lenkpause kann früher nötig sein.',
          _remainingDrivingMin.clamp(0, _dailyDrivingLimit),
          _dailyDrivingLimit,
          (int v) => setState(() => _remainingDrivingMin = v),
        ),
      1 => (
          'Verbleibende Einsatzzeit',
          'Bis zur Tagesruhe (derzeit höchstens '
              '${_dailyDutyLimit ~/ 60} Stunden).',
          _remainingDutyMin.clamp(0, _dailyDutyLimit),
          _dailyDutyLimit,
          (int v) => setState(() => _remainingDutyMin = v),
        ),
      _ => (
          'Seit der letzten Lenkpause',
          'Nur falls heute bereits gefahren wurde.',
          _continuousDrivenMin,
          270,
          (int v) => setState(() => _continuousDrivenMin = v),
        ),
    };

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  titel,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _editingBudget = null),
                child: const Text('Fertig'),
              ),
            ],
          ),
          Text(beschreibung, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 4),
            child: DurationInput(
              key: ValueKey(_editingBudget),
              minutes: minuten,
              maxMinutes: maxMinuten,
              onChanged: setzen,
            ),
          ),
        ],
      ),
    );
  }

  /// Abfahrt in einer Zeile. Ohne Auswahl heißt es schlicht „Jetzt“.
  Widget _departureRow() {
    final theme = Theme.of(context);
    final text = _manualDepartureActive
        ? '${DateFormat('dd.MM.').format(_manualDepartureDate)} '
            '${_zweistellig(_manualDepartureHour)}:'
            '${_zweistellig(_manualDepartureMinute)}'
        : 'Jetzt';
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Icon(Icons.play_circle_outline_rounded,
              size: 18, color: theme.hintColor),
          const SizedBox(width: 8),
          Text(
            'Abfahrt',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          if (_manualDepartureActive)
            TextButton(
              onPressed: () =>
                  setState(() => _manualDepartureActive = false),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Jetzt'),
            ),
          InkWell(
            onTap: _abfahrtWaehlen,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.edit_calendar_outlined,
                      size: 16, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Datum und Uhrzeit nacheinander abfragen. Bricht der Fahrer ab, bleibt
  /// alles, wie es war – insbesondere bleibt „Jetzt“ stehen.
  Future<void> _abfahrtWaehlen() async {
    final datum = await showDatePicker(
      context: context,
      initialDate: _manualDepartureDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (datum == null || !mounted) return;
    final zeit = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _manualDepartureHour,
        minute: _manualDepartureMinute,
      ),
      initialEntryMode: TimePickerEntryMode.input,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (zeit == null || !mounted) return;
    setState(() {
      _manualDepartureDate = datum;
      _manualDepartureHour = zeit.hour;
      _manualDepartureMinute = zeit.minute;
      _manualDepartureActive = true;
    });
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

  /// Hinweis für die Kartenkopfzeile. Bei einer geplanten Fähre zeigt die
  /// Karte Googles eigene Streckenführung – die kann eine andere Verbindung
  /// wählen als die, mit der gerechnet wurde.
  String? _mapRouteNote() {
    if (_resultViaDenmark) {
      return 'Geplant über Dänemark; Karte zeigt Googles Streckenführung';
    }
    final ferry = _resultFerry;
    if (ferry != null) {
      return 'Geplant mit ${ferry.name}; Karte zeigt Googles Streckenführung '
          'und kann eine andere Fähre wählen';
    }
    return null;
  }

  Future<void> _openMapOsm() async {
    // Fährtour: die beiden geplanten Landwege plus Seestrecke zeichnen.
    // Ohne das fragt die Karte Google erneut von Start nach Ziel und zeigt
    // dessen eigene, kürzeste Fähre statt der geplanten.
    final legs = _ferryLegPlan;
    if (_etaResult != null && legs != null) {
      final from = legs.portFrom;
      final to = legs.portTo;
      final segs = <MapSegment>[
        MapSegment(
            points: legs.legA.points, label: 'Anfahrt → ${legs.ferry.from}'),
        if (from != null && to != null)
          MapSegment(
              points: [from, to], label: legs.ferry.name, isFerry: true),
        MapSegment(points: legs.legB.points, label: '${legs.ferry.to} → Ziel'),
      ];
      if (legs.legA.points.isNotEmpty && legs.legB.points.isNotEmpty) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MapOsmView(
            start: legs.legA.points.first,
            dest: legs.legB.points.last,
            route: const [],
            segments: segs,
            stops: [for (final c in _stopCoords) if (c != null) c],
            subtitle: _mapRouteNote(),
          ),
        ));
        return;
      }
    }

    if (_etaResult != null && _resultRoutePolyline != null) {
      final points = map_launcher.decodePolyline(_resultRoutePolyline!);
      if (points.length >= 2) {
        // Geometrie der tatsächlich berechneten Route – genauer als ein
        // erneuter Abruf, deshalb hier bevorzugt.
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MapOsmView(
            start: points.first,
            dest: points.last,
            route: points,
            stops: [for (final c in _stopCoords) if (c != null) c],
            subtitle: _mapRouteNote() ?? 'Berechnete Route',
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
      routeNote: _mapRouteNote(),
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
                  title: 'ROUTE PLANEN',
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
                  title: _kapitel('ZWISCHENSTOPPS'),
                  subtitle: _stand(_stopsSummary),
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
              // 🛣️ Routen-Vorlagen: eigene Wegpunkt-Folgen für Strecken,
              // die der Fahrer besser kennt als jeder Routenplaner.
              Padding(
                padding: pad,
                // In dieselbe Form wie die Abschnitte gesetzt: als lose Zeile
                // zwischen zwei Kacheln sah sie aus wie vergessen.
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFFD9E2EC)),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 2),
                  child: RoutePresetSelector(
                    presets: _presets,
                    currentStopCount: _stops.length,
                    onApply: _applyPreset,
                    onDelete: _deletePreset,
                    onSaveCurrent: _saveCurrentAsPreset,
                  ),
                ),
              ),
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: _kapitel('ABFAHRT & ZEIT'),
                  // Zugeklappt steht hier der ganze Stand – das ist der
                  // Normalfall, in dem niemand etwas ändern will.
                  subtitle: _stand(_zeitSummary),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  children: [
                    // Die drei Werte nebeneinander statt in drei großen
                    // Kästen untereinander. Antippen öffnet die Eingabe.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _budgetTile(
                          index: 0,
                          label: 'Fahrzeit',
                          minuten: _remainingDrivingMin,
                          hinweis: 'von ${_hhmm(_dailyDrivingLimit)}',
                        ),
                        _budgetTile(
                          index: 1,
                          label: 'Einsatzzeit',
                          minuten: _remainingDutyMin,
                          hinweis: 'von ${_hhmm(_dailyDutyLimit)}',
                        ),
                        _budgetTile(
                          index: 2,
                          label: 'Seit Lenkpause',
                          minuten: _continuousDrivenMin,
                          hinweis: _continuousDrivenMin == 0
                              ? 'frisch gestartet'
                              : 'max ${_hhmm(270)}',
                        ),
                      ],
                    ),
                    if (_editingBudget != null) _budgetEditor(),

                    const Divider(height: 18),
                    _departureRow(),

                    const Divider(height: 18),
                    // Fünf große Knöpfe plus Dauererklärung sind hier
                    // zusammengeschrumpft: die Erklärung hängt am ⓘ und
                    // wechselt mit dem gewählten Profil.
                    Row(
                      children: [
                        Text(
                          'Geschwindigkeit',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 5),
                        Tooltip(
                          message: _speedProfile.description,
                          triggerMode: TooltipTriggerMode.tap,
                          showDuration: const Duration(seconds: 8),
                          child: Icon(
                            Icons.info_outline_rounded,
                            size: 15,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final profile in SpeedProfile.values)
                          ChoiceChip(
                            label: Text(_profilKurz(profile)),
                            selected: _speedProfile == profile,
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            labelStyle: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  fontWeight: _speedProfile == profile
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                            onSelected: (_) =>
                                setState(() => _speedProfile = profile),
                          ),
                      ],
                    ),
                    if (_speedProfile == SpeedProfile.custom)
                      _slider(
                        'Eigener Planungsschnitt',
                        _avgKmh,
                        40,
                        90,
                        (v) => setState(() => _avgKmh = v),
                      ),

                    // Wirkt auf jedes Profil, nicht nur auf die Automatik.
                    SizedBox(
                      height: 38,
                      child: Row(
                        children: [
                          Icon(
                            Icons.scale_rounded,
                            size: 18,
                            color: _heavyLoad
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).disabledColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: 'Schwere Ladung',
                                    style: TextStyle(
                                      fontWeight: _heavyLoad
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '  +'
                                        '${((heavyLoadTimeFactor - 1) * 100).round()}'
                                        ' % Fahrzeit',
                                    style: TextStyle(
                                      color: Theme.of(context).hintColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          Switch(
                            value: _heavyLoad,
                            onChanged: (v) => setState(() {
                              _heavyLoad = v;
                              _etaResult = null;
                              _ferryLegPlan = null;
                            }),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // --- Lenk-/Ruhezeit & Tankpause ---
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.rule_rounded),
                  title: _kapitel('LENK- & RUHEZEITEN'),
                  // Die Erklärung hängt am Zeichen hinter dem Stand, damit
                  // sie keine eigene Zeile verbraucht.
                  subtitle: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: _ruleSummary),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Tooltip(
                              message: 'Auf einen Punkt tippen, um ihn als '
                                  'verbraucht zu markieren.\n'
                                  'Blau mit Haken = noch verfügbar, '
                                  'grau = schon verbraucht.',
                              triggerMode: TooltipTriggerMode.tap,
                              showDuration: const Duration(seconds: 6),
                              child: Icon(
                                Icons.info_outline_rounded,
                                size: 15,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF102A43),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  // Ohne beides stehen die Zeilen mittig und kleben am Rand.
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  children: [
                    // Zwei Zähler-Zeilen statt fünf Schaltflächen: der Fahrer
                    // sieht auf einen Blick, wie viel er noch hat.
                    _reserveRow(
                      label: '10 h-Lenktage',
                      values: [_ten1, _ten2],
                      onToggle: (i, v) => _changeDrivingLimit(
                        () => i == 0 ? _ten1 = v : _ten2 = v,
                      ),
                    ),
                    _reserveRow(
                      label: '9 h-Ruhezeiten',
                      values: [_nine1, _nine2, _nine3],
                      onToggle: (i, v) => _changeDutyLimit(
                        () => i == 0
                            ? _nine1 = v
                            : i == 1
                                ? _nine2 = v
                                : _nine3 = v,
                      ),
                    ),
                    const Divider(height: 10),
                    // Die drei unten bedeuten etwas anderes als „wie viel ist
                    // noch übrig“ und stehen deshalb abgesetzt.
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        _optionChip(
                          Icons.local_gas_station_rounded,
                          'Tankpause +30',
                          _tankpause,
                          (v) => setState(() => _tankpause = v),
                        ),
                        _optionChip(
                          Icons.hourglass_bottom_rounded,
                          'Geteilte Pause 15+30',
                          _splitBreak,
                          (v) => setState(() => _splitBreak = v),
                        ),
                      ],
                    ),
                    // Kein weiterer gleichwertiger Knopf, sondern ein Zustand.
                    SizedBox(
                      height: 34,
                      child: Row(
                        children: [
                          Icon(
                            Icons.bedtime_rounded,
                            size: 18,
                            color: _weeklyRestDue
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).disabledColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Wochenruhe vor Abfahrt fällig',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: _weeklyRestDue
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                            ),
                          ),
                          Switch(
                            value: _weeklyRestDue,
                            onChanged: (v) =>
                                setState(() => _weeklyRestDue = v),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // --- Fähre ---
              Padding(
                padding: pad,
                child: ExpansionTile(
                  leading: const Icon(Icons.directions_boat_rounded),
                  title: _kapitel('FÄHRE'),
                  subtitle: _stand(_ferrySummary),
                  children: [
                    SwitchListTile(
                      title: const Text('Fähre automatisch vorschlagen'),
                      value: _autoFerry,
                      onChanged: (v) => setState(() {
                        _autoFerry = v;
                        if (v) {
                          _viaDenmarkFerries = false;
                          _manualFerry = null;
                          _manualFerryDeparture = null;
                        }
                        _etaResult = null;
                        _ferryLegPlan = null;
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
                        _ferryLegPlan = null;
                      }),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextField(
                            controller: _ferrySearchCtl,
                            decoration: InputDecoration(
                              labelText: 'Fähre manuell suchen',
                              hintText:
                                  'Hafen oder Verbindung, z. B. Igoumenitsa',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _ferrySearchCtl.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Suche löschen',
                                      onPressed: () => setState(
                                        () => _ferrySearchCtl.clear(),
                                      ),
                                      icon: const Icon(Icons.clear),
                                    ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (_manualFerry != null) ...[
                            const SizedBox(height: 8),
                            Card(
                              color: const Color(0xFFEAF4FF),
                              child: ListTile(
                                leading: const Icon(Icons.directions_boat),
                                title: Text(_manualFerry!.name),
                                subtitle: const Text(
                                  'Manuell gewählt – statt automatischem Vorschlag',
                                ),
                                trailing: IconButton(
                                  tooltip: 'Fährwahl zurücksetzen',
                                  onPressed: () => setState(() {
                                    _manualFerry = null;
                                    _manualFerryDeparture = null;
                                    _etaResult = null;
                                    _ferryLegPlan = null;
                                  }),
                                  icon: const Icon(Icons.close),
                                ),
                              ),
                            ),
                          ],
                          if (_ferrySearchCtl.text.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Builder(builder: (context) {
                              final matches = FerryRouteSearch.find(
                                _routes,
                                _ferrySearchCtl.text,
                              );
                              if (matches.isEmpty) {
                                return const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text(
                                      'Keine passende Fährverbindung gefunden.'),
                                );
                              }
                              return ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxHeight: 260),
                                child: ListView.builder(
                                  shrinkWrap: true,
                                  itemCount: matches.length,
                                  itemBuilder: (context, index) {
                                    final route = matches[index];
                                    return ListTile(
                                      title: Text(route.name),
                                      subtitle: Text(
                                        '${route.from} → ${route.to} · ${route.operators.join(', ')}',
                                      ),
                                      onTap: () {
                                        FocusScope.of(context).unfocus();
                                        setState(() {
                                          _manualFerry = route;
                                          _manualFerryDeparture = null;
                                          _autoFerry = false;
                                          _viaDenmarkFerries = false;
                                          _ferrySearchCtl.clear();
                                          _etaResult = null;
                                          _ferryLegPlan = null;
                                        });
                                      },
                                    );
                                  },
                                ),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
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
                                        _ferryLegPlan = null;
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
                                      _ferryLegPlan = null;
                                    });
                                  },
                                ),
                                if (_manualFerryDeparture != null)
                                  TextButton(
                                    onPressed: () => setState(() {
                                      _manualFerryDeparture = null;
                                      _etaResult = null;
                                      _ferryLegPlan = null;
                                    }),
                                    child: const Text('Zeit zurücksetzen'),
                                  ),
                              ],
                            ),
                            _plannedDepartureChips(),
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
                  label: const Text('Karte anzeigen'),
                  // Immer die App-Karte, auch bei Fährrouten – die Karte
                  // stellt Fährabschnitte jetzt gesondert dar.
                  onPressed: _openMapOsm,
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

  /// Planmäßige Abfahrten der gewählten Fähre zum Antippen.
  ///
  /// Bisher musste die Uhrzeit frei eingetippt werden, obwohl der Fahrplan
  /// in der App liegt. Die Zeiten gelten in Hafen-Ortszeit; weicht die
  /// Gerätezeit ab, steht sie in Klammern dahinter.
  Widget _plannedDepartureChips() {
    final ferry = _manualFerry;
    if (ferry == null) return const SizedBox.shrink();

    final date = _manualFerryDeparture ?? DateTime.now();
    final times = FerrySchedule.timesForDate(
      date,
      ferry.departuresLocal,
      ferry.tz,
      departuresByWeekday: ferry.departuresByWeekday,
    );
    if (times.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Für ${DateFormat('EEEE, dd.MM.', 'de').format(date)} ist kein '
          'Fahrplan hinterlegt – Uhrzeit bitte eintragen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Planmäßig am ${DateFormat('EEEE, dd.MM.', 'de').format(date)} '
            '(Ortszeit ${ferry.from})',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              for (final t in times)
                Builder(builder: (context) {
                  final when = FerrySchedule.atPortTime(date, t, ferry.tz);
                  final hier =
                      when == null ? null : DateFormat('HH:mm').format(when);
                  final selected = when != null &&
                      _manualFerryDeparture != null &&
                      _manualFerryDeparture!.isAtSameMomentAs(when);
                  return ChoiceChip(
                    label: Text(hier != null && hier != t
                        ? '$t  (bei dir $hier)'
                        : t),
                    selected: selected,
                    onSelected: when == null
                        ? null
                        : (_) => setState(() {
                              _manualFerryDeparture = when;
                              _etaResult = null;
                              _ferryLegPlan = null;
                            }),
                  );
                }),
            ],
          ),
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

        ],
      ),
    );
  }
}

class _InputCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _InputCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Gleiche Form wie die aufklappbaren Abschnitte: weiss, gerundet, dünner
    // Rahmen. Der frühere Schatten und der 40 Pixel grosse Symbolkasten
    // liessen diesen einen Block schwerer wirken als alle anderen.
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFD9E2EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: const Color(0xFF486581)),
              const SizedBox(width: 12),
              Text(
                title,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.9,
                      color: const Color(0xFF486581),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
