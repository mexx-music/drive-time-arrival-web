// lib/main.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter/cupertino.dart';

import 'models/ferry_route.dart';
import 'services/ferry_schedule_loader.dart';
import 'logic/eta_calculator.dart';
import 'logic/ferry_auto.dart';
import 'logic/port_aliases.dart';
import 'secrets.dart';
import 'ui/map_osm_view.dart';
import 'widgets/places_autocomplete.dart';
import 'services/geocoding_service.dart';
import 'widgets/place_input.dart';
import 'widgets/route_input_widget.dart';
import 'widgets/ferry_selection_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('de');
  await initializeDateFormatting('en');
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF)),
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
  bool _optimizeStops = true;

  double _avgKmh = 80;
  int _drivenMin = 0;
  int _dutyOffsetMin = 0;

  // Lenk-/Ruhezeit & Tankpause
  bool _ten1 = true; // 10h-Tag #1 verfügbar?
  bool _ten2 = true; // 10h-Tag #2 verfügbar?
  bool _nine1 = true; // 9h-Ruheverkürzung #1 verfügbar?
  bool _nine2 = true; // 9h-Ruheverkürzung #2 verfügbar?
  bool _nine3 = true; // 9h-Ruheverkürzung #3 verfügbar?
  bool _tankpause = false; // ⛽ +30 min

  bool _autoFerry = false;
  bool _showDetails = false;
  FerryRoute? _manualFerry;
  DateTime? _manualFerryDeparture;

  List<FerryRoute> _routes = [];
  String _source = '…';

  List<String> _log = [];
  DateTime? _arrival;

  double? _startLat, _startLng, _destLat, _destLng;

  // Manuelle Abfahrt (UI & state)
  DateTime _manualDepartureDate = DateTime.now();
  int _manualDepartureHour = DateTime.now().hour;
  int _manualDepartureMinute = DateTime.now().minute;
  bool _manualDepartureActive = false;

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

  Future<void> _loadFerries() async {
    final (source, routes) = await FerryScheduleLoader.load();
    setState(() {
      _routes = routes.where((r) => r.active).toList();
      _source = source;
    });
  }

  // Reusable wheel picker (Cupertino-style)
  Future<int?> _showWheelPicker(
      BuildContext ctx, int initial, int maxInclusive) async {
    int temp = initial.clamp(0, maxInclusive);
    final res = await showModalBottomSheet<int>(
      context: ctx,
      useRootNavigator: true,
      isScrollControlled: false,
      builder: (mc) {
        return Container(
          height: 320,
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            children: [
              SizedBox(
                height: 220,
                child: CupertinoPicker(
                  itemExtent: 32,
                  scrollController:
                      FixedExtentScrollController(initialItem: temp),
                  onSelectedItemChanged: (i) => temp = i,
                  children: List.generate(
                    maxInclusive + 1,
                    (i) => Center(
                      child: Text(
                        i.toString().padLeft(2, '0'),
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(mc).pop(),
                      child: const Text('Abbrechen'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(mc).pop(temp),
                      child: const Text('OK'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    return res;
  }

  // ---- Google Directions: Distanz in km holen ----
  Future<double?> _getDistanceKm(String origin, String destination) async {
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

  Future<(double km, FerryRoute? ferry, String note)> _planDistanceAndFerryAuto(
    String origin,
    String destination,
    List<String> wps,
    bool optimize,
  ) async {
    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);

    final normal = await det.fetchDirections(
      origin: origin,
      destination: destination,
      waypoints: wps,
      optimize: optimize,
    );
    if (!normal.ok) {
      return (
        double.tryParse(_kmCtl.text.trim()) ?? 0.0,
        null,
        '⚠️ Directions(${normal.status}); nutze manuelle km'
      );
    }

    // Vergleichsroute ohne Fähren
    final avoid = await det.fetchDirections(
      origin: origin,
      destination: destination,
      waypoints: wps,
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

    return (km, matched, hasFerry ? '🛳️ Fähre erkannt ($why)' : '');
  }

  Future<void> _compute() async {
    _log.clear();
    setState(() {});

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
    final s = _startCtl.text.trim();
    final d = _destCtl.text.trim();
    final (distKm, matchedFerry, note) =
        await _planDistanceAndFerryAuto(s, d, _stops, _optimizeStops);

    // debug
    // ignore: avoid_print
    print(
        '[Compute] planDistanceAndFerryAuto -> distKm=$distKm note=$note matchedFerry=${matchedFerry?.name}');

    if (distKm > 0) {
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
    );

    bool usedTwoLegs = false;
    EtaResult res;
    DateTime? current;

    // Erzeuge FerryAutoDetect und delegiere ETA-Berechnung (Wrapper entscheidet, ob Fähre benutzt wird)
    final det = FerryAutoDetect(GOOGLE_MAPS_API_KEY);
    final FerryRoute? ferryCandidate =
        _manualFerry ?? (_autoFerry ? matchedFerry : null);
    final etaRes = await det.computeEtaWithOptionalFerry(
      startTime: start,
      alreadyDrivenMin: _drivenMin,
      dutyOffsetMin: _dutyOffsetMin,
      avgKmh: _avgKmh,
      rules: driveRules,
      startAddress: s,
      endAddress: d,
      autoOrManualFerry: ferryCandidate,
      manualDeparture: _manualFerryDeparture,
    );
    res = etaRes;
    _log.addAll(res.steps.map((e) => e.text));
    current = res.arrival;
    usedTwoLegs = ferryCandidate != null;

    // Fähre einplanen (manuell hat Vorrang)
    FerryRoute? ferry = _manualFerry;
    if (ferry == null && _autoFerry && matchedFerry != null && !usedTwoLegs) {
      // Use the richer selection dialog so the user can pick direction + departure
      final result = await showDialog<Map<String, String>?>(
        context: context,
        builder: (_) => FerrySelectionDialog(route: matchedFerry),
      );
      if (result != null) {
        // Apply user's selection: mark manual ferry and set a concrete departure DateTime
        setState(() {
          _manualFerry = matchedFerry;
          final depStr = result['departure'] ?? '';
          DateTime? parsed;
          try {
            final parts = depStr.split(':');
            final hh = int.tryParse(parts.isNotEmpty ? parts[0] : '0') ?? 0;
            final mm = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;
            // Use current arrival day as base if available
            final base = current ?? DateTime.now();
            var cand = DateTime(base.year, base.month, base.day, hh, mm);
            if (cand.isBefore(base)) cand = cand.add(const Duration(days: 1));
            parsed = cand;
          } catch (_) {
            parsed = null;
          }
          _manualFerryDeparture = parsed;
        });
        ferry = matchedFerry;
      }
    }

    if (!usedTwoLegs && ferry != null && current != null) {
      _log.add(
          '📍 Ankunft Hafen ${ferry.from} um ${DateFormat('yyyy-MM-dd HH:mm').format(current)}');
      DateTime? nextDep;
      if (_manualFerryDeparture != null) {
        nextDep = _manualFerryDeparture;
        _log.add(
            '🕓 Manuelle Abfahrt Fähre: ${DateFormat('yyyy-MM-dd HH:mm').format(nextDep!)}');
      } else if (ferry.departuresLocal.isNotEmpty) {
        for (final hhmm in ferry.departuresLocal) {
          final p = hhmm.split(':');
          final cand = DateTime(current.year, current.month, current.day,
              int.parse(p[0]), int.parse(p[1]));
          if (!cand.isBefore(current)) {
            nextDep = cand;
            break;
          }
        }
        nextDep ??= DateTime(current.year, current.month, current.day)
            .add(const Duration(days: 1));
        _log.add(
            '⏱ Wartezeit bis Fähre: ${_fmtHm(nextDep!.difference(current))} → Abfahrt: ${DateFormat('HH:mm').format(nextDep!)}');
      }
      if (nextDep != null) {
        current =
            nextDep.add(Duration(minutes: (ferry.durationHours * 60).round()));
        _log.add(
            '🚢 Fähre ${ferry.name} ${ferry.durationHours.toStringAsFixed(1)}h → Ankunft: ${DateFormat('yyyy-MM-dd HH:mm').format(current)}');
        if (ferry.durationHours * 60 >= 540) {
          _log.add('✅ Pause vollständig während Fähre erfüllt');
          _log.add('Zahler werden zurückgesetzt.');
        }
      }
    }
    setState(() => _arrival = current);
  }

  String _fmtHm(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60;
    return '${h}h${m.toString().padLeft(2, '0')}';
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

  Widget _durationField(
    String label,
    int minutes,
    void Function(int) onChanged, {
    bool showLabel = true,
  }) {
    return LayoutBuilder(builder: (context, c) {
      const gap = 4.0;
      const narrowThreshold = 180.0; // etwas großzügiger gegen Overflows

      final h = minutes ~/ 60;
      final m = minutes % 60;

      Future<void> _pickHour() async {
        final sel = await _showWheelPicker(context, h, 99);
        if (sel != null) onChanged(sel * 60 + m);
      }

      Future<void> _pickMinute() async {
        final sel = await _showWheelPicker(context, m, 59);
        if (sel != null) onChanged(h * 60 + sel);
      }

      // Basis-Button
      Widget _buildButton(Widget child, VoidCallback onTap) {
        return OutlinedButton(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          ),
          onPressed: onTap,
          child: child,
        );
      }

      final hourChild = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.access_time, size: 18),
          const SizedBox(width: 6),
          Text(h.toString().padLeft(2, '0'),
              style: const TextStyle(fontSize: 18)),
        ],
      );

      final minuteChild = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(m.toString().padLeft(2, '0'),
              style: const TextStyle(fontSize: 18)),
        ],
      );

      final isNarrow = c.maxWidth < narrowThreshold;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel) Text(label),
          if (showLabel) const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.6)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child:
                            _buildButton(Center(child: hourChild), _pickHour),
                      ),
                      const SizedBox(height: gap),
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: _buildButton(
                            Center(child: minuteChild), _pickMinute),
                      ),
                    ],
                  )
                : Wrap(
                    spacing: gap,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      ConstrainedBox(
                        constraints:
                            const BoxConstraints(minWidth: 60, maxWidth: 140),
                        child: SizedBox(
                          height: 48,
                          child:
                              _buildButton(Center(child: hourChild), _pickHour),
                        ),
                      ),
                      ConstrainedBox(
                        constraints:
                            const BoxConstraints(minWidth: 60, maxWidth: 140),
                        child: SizedBox(
                          height: 48,
                          child: _buildButton(
                              Center(child: minuteChild), _pickMinute),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      );
    });
  }

  // Google encoded polyline -> List<LatLng>
  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  Future<void> _openMapOsm() async {
    final s = _startCtl.text.trim();
    final d = _destCtl.text.trim();
    if (s.isEmpty || d.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte Start & Ziel eingeben.')),
        );
      }
      return;
    }

    String wp = '';
    if (_stops.isNotEmpty) {
      final parts = _stops.map((w) => Uri.encodeComponent(w)).join('|');
      final head = _optimizeStops ? 'optimize:true|' : '';
      wp = '&waypoints=$head$parts';
    }
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${Uri.encodeComponent(s)}'
      '&destination=${Uri.encodeComponent(d)}'
      '&mode=driving&units=metric&language=en'
      '&key=$GOOGLE_MAPS_API_KEY$wp',
    );

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['status'] != 'OK')
        throw Exception('Directions ${data['status']}');

      final route = (data['routes'] as List).first as Map<String, dynamic>;
      final legs = (route['legs'] as List).cast<Map<String, dynamic>>();
      final firstLeg = legs.first;
      final lastLeg = legs.last;
      final sl = firstLeg['start_location'] as Map<String, dynamic>;
      final dl = lastLeg['end_location'] as Map<String, dynamic>;
      final poly = (route['overview_polyline']
          as Map<String, dynamic>)['points'] as String;

      final start =
          LatLng((sl['lat'] as num).toDouble(), (sl['lng'] as num).toDouble());
      final dest =
          LatLng((dl['lat'] as num).toDouble(), (dl['lng'] as num).toDouble());
      final coords = _decodePolyline(poly);

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MapOsmView(start: start, dest: dest, route: coords),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Karte fehlgeschlagen: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = const EdgeInsets.symmetric(horizontal: 16, vertical: 8);
    return Scaffold(
      appBar: AppBar(title: const Text('🚛 DriverRoute ETA – MVP')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                Padding(
                  padding: pad,
                  child: Row(
                    children: [
                      const Text('Fahrplan-Quelle: ',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(_source),
                      const SizedBox(width: 12),
                      Text('Routen: ${_routes.length}'),
                    ],
                  ),
                ),
                Padding(
                  padding: pad,
                  child: Row(
                    children: [
                      Expanded(
                        child: PlaceInput(
                          label: '📍 Startort/PLZ',
                          hint: 'Start eingeben',
                          initialText: _startCtl.text,
                          onChanged: (v) => _startCtl.text = v,
                          onConfirmed: (v) async {
                            final txt = v.trim();
                            if (txt.isEmpty) return;
                            _startCtl.text = txt;
                            try {
                              final r = await GeocodingService.resolve(txt);
                              setState(() {
                                _startLat = r.lat;
                                _startLng = r.lng;
                              });
                            } catch (e) {
                              if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                    content: Text(
                                        'Start konnte nicht aufgelöst werden: $e')));
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PlaceInput(
                          label: '🏁 Zielort/PLZ',
                          hint: 'Ziel eingeben',
                          initialText: _destCtl.text,
                          onChanged: (v) => _destCtl.text = v,
                          onConfirmed: (v) async {
                            final txt = v.trim();
                            if (txt.isEmpty) return;
                            _destCtl.text = txt;
                            try {
                              final r = await GeocodingService.resolve(txt);
                              setState(() {
                                _destLat = r.lat;
                                _destLng = r.lng;
                              });
                            } catch (e) {
                              if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                    content: Text(
                                        'Ziel konnte nicht aufgelöst werden: $e')));
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: pad,
                  child: ExpansionTile(
                    title: const Text(
                        '⏳ Abfahrt & Zwischeneinstieg + 🕓 Manuelle Abfahrt (einblenden)'),
                    children: [
                      LayoutBuilder(
                        builder: (ctx, box) {
                          // bei schmalen Layouts untereinander
                          final stackVertically = box.maxWidth < 720;

                          final leftWidget = Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: ExpansionTile(
                              title: Text(
                                'Bereits gefahren / Einsatzzeit',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              initiallyExpanded: false,
                              children: [
                                // "Bereits gefahren" block
                                Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .dividerColor
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('Bereits gefahren',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      const SizedBox(height: 8),
                                      _durationField(
                                        'Bereits gefahren',
                                        _drivenMin,
                                        (v) => setState(() => _drivenMin = v),
                                        showLabel: false,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // "Einsatzzeit bisher" block
                                Container(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .dividerColor
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('Einsatzzeit bisher',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      const SizedBox(height: 8),
                                      _durationField(
                                        'Einsatzzeit bisher',
                                        _dutyOffsetMin,
                                        (v) =>
                                            setState(() => _dutyOffsetMin = v),
                                        showLabel: false,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Geschwindigkeit
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0, vertical: 6.0),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: _slider(
                                          'Ø-Geschwindigkeit (km/h)',
                                          _avgKmh,
                                          60,
                                          120,
                                          (v) => setState(() => _avgKmh = v),
                                        ),
                                      )
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );

                          final rightWidget = Container(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('🕓 Manuelle Abfahrt',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                Row(
                                  children: [
                                    Switch(
                                      value: _manualDepartureActive,
                                      onChanged: (v) => setState(
                                          () => _manualDepartureActive = v),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Manuelle Abfahrt aktivieren',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                GestureDetector(
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
                                const SizedBox(height: 8),
                                Text('🕓 Abfahrtszeit',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 6),
                                Builder(
                                  builder: (ctx) {
                                    final hourPicker = OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10, horizontal: 8)),
                                      onPressed: () async {
                                        final sel = await _showWheelPicker(
                                            ctx, _manualDepartureHour, 23);
                                        if (sel != null) {
                                          setState(
                                              () => _manualDepartureHour = sel);
                                        }
                                      },
                                      child: Row(
                                        children: [
                                          const Icon(Icons.access_time,
                                              size: 18),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            fit: FlexFit.loose,
                                            child: Text(
                                              _manualDepartureHour
                                                  .toString()
                                                  .padLeft(2, '0'),
                                              style:
                                                  const TextStyle(fontSize: 18),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );

                                    final minutePicker = OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10, horizontal: 8)),
                                      onPressed: () async {
                                        final sel = await _showWheelPicker(
                                            ctx, _manualDepartureMinute, 59);
                                        if (sel != null) {
                                          setState(() =>
                                              _manualDepartureMinute = sel);
                                        }
                                      },
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 4),
                                          Flexible(
                                            fit: FlexFit.loose,
                                            child: Text(
                                              _manualDepartureMinute
                                                  .toString()
                                                  .padLeft(2, '0'),
                                              style:
                                                  const TextStyle(fontSize: 18),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );

                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        Flexible(
                                            fit: FlexFit.tight,
                                            child: hourPicker),
                                        const SizedBox(width: 8),
                                        Flexible(
                                            fit: FlexFit.tight,
                                            child: minutePicker),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                if (_manualDepartureActive)
                                  Text(
                                    '🕓 Manuelle Abfahrt gesetzt: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime(_manualDepartureDate.year, _manualDepartureDate.month, _manualDepartureDate.day, _manualDepartureHour, _manualDepartureMinute))}',
                                    style:
                                        const TextStyle(color: Colors.black54),
                                  ),
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

                      // Centered stop input row spanning both columns
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16.0, vertical: 6.0),
                        child: Center(
                          child: FractionallySizedBox(
                            widthFactor: 0.75,
                            child: LayoutBuilder(
                              builder: (ctx, constraints) {
                                if (constraints.maxWidth < 400) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      PlaceInput(
                                        label: 'Zwischenziel',
                                        hint: 'Adresse/Ort für Zwischenziel',
                                        initialText: _stopCtl.text,
                                        onChanged: (v) => _stopCtl.text = v,
                                        onConfirmed: (txt) async {
                                          final t = txt.trim();
                                          if (t.isEmpty) return;
                                          try {
                                            final res =
                                                await GeocodingService.resolve(
                                                    t);
                                            setState(() {
                                              _stops.add(res.description);
                                              _stopCoords.add(
                                                  LatLng(res.lat, res.lng));
                                            });
                                            _stopCtl.clear();
                                          } catch (e) {
                                            // fallback: add raw text
                                            setState(() {
                                              _stops.add(t);
                                              _stopCoords.add(null);
                                            });
                                            _stopCtl.clear();
                                            if (mounted)
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                      content: Text(
                                                          'Zwischenziel konnte nicht aufgelöst werden: $e')));
                                          }
                                        },
                                      ),
                                      const SizedBox(height: 8),
                                      SizedBox(
                                        height: 48,
                                        child: FilledButton(
                                          style: FilledButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(48),
                                          ),
                                          onPressed: () {
                                            final t = _stopCtl.text.trim();
                                            if (t.isNotEmpty) {
                                              setState(() => _stops.add(t));
                                              _stopCtl.clear();
                                            }
                                          },
                                          child: const Text('Hinzufügen'),
                                        ),
                                      ),
                                    ],
                                  );
                                }

                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: PlaceInput(
                                        label: 'Zwischenziel',
                                        hint: 'Adresse/Ort für Zwischenziel',
                                        initialText: _stopCtl.text,
                                        onChanged: (v) => _stopCtl.text = v,
                                        onConfirmed: (txt) async {
                                          final t = txt.trim();
                                          if (t.isEmpty) return;
                                          try {
                                            final res =
                                                await GeocodingService.resolve(
                                                    t);
                                            setState(() {
                                              _stops.add(res.description);
                                              _stopCoords.add(
                                                  LatLng(res.lat, res.lng));
                                            });
                                            _stopCtl.clear();
                                          } catch (e) {
                                            setState(() {
                                              _stops.add(t);
                                              _stopCoords.add(null);
                                            });
                                            _stopCtl.clear();
                                            if (mounted)
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(SnackBar(
                                                      content: Text(
                                                          'Zwischenziel konnte nicht aufgelöst werden: $e')));
                                          }
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: 120,
                                      height: 48,
                                      child: FilledButton(
                                        style: FilledButton.styleFrom(
                                            minimumSize: const Size(120, 48)),
                                        onPressed: () {
                                          final t = _stopCtl.text.trim();
                                          if (t.isNotEmpty) {
                                            setState(() => _stops.add(t));
                                            _stopCtl.clear();
                                          }
                                        },
                                        child: const Text('Hinzufügen'),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: _stops.isEmpty
                            ? const Text('Noch keine Zwischenziele.')
                            : Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  for (int i = 0; i < _stops.length; i++)
                                    InputChip(
                                      label: Text('#${i + 1}  ${_stops[i]}'),
                                      onDeleted: () =>
                                          setState(() => _stops.removeAt(i)),
                                    )
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
                    title: const Text('🛌 Lenk-/Ruhezeit & Tankpause'),
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
                            onSelected: (v) => setState(() => _ten1 = v),
                          ),
                          FilterChip(
                            label: const Text('10h-Tag #2'),
                            selected: _ten2,
                            onSelected: (v) => setState(() => _ten2 = v),
                          ),
                          FilterChip(
                            label: const Text('9h-Ruhe #1'),
                            selected: _nine1,
                            onSelected: (v) => setState(() => _nine1 = v),
                          ),
                          FilterChip(
                            label: const Text('9h-Ruhe #2'),
                            selected: _nine2,
                            onSelected: (v) => setState(() => _nine2 = v),
                          ),
                          FilterChip(
                            label: const Text('9h-Ruhe #3'),
                            selected: _nine3,
                            onSelected: (v) => setState(() => _nine3 = v),
                          ),
                          FilterChip(
                            label: const Text('⛽ Tankpause +30 min'),
                            selected: _tankpause,
                            onSelected: (v) => setState(() => _tankpause = v),
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
                    title: const Text('🛳️ Fähre (einblenden)'),
                    children: [
                      SwitchListTile(
                        title: const Text(
                            '🚢 Automatische Erkennung aktivieren (MVP Anzeige)'),
                        value: _autoFerry,
                        onChanged: (v) => setState(() => _autoFerry = v),
                      ),
                      // WICHTIG: Kein "null"-DropdownItem, stattdessen hint verwenden
                      // --- Fähre Auswahl (mit robustem initialValue + Reset) ---
                      Builder(builder: (ctx) {
                        final selectedFerry = _routes.contains(_manualFerry)
                            ? _manualFerry
                            : null;
                        return Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<FerryRoute>(
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
                                onChanged: (v) =>
                                    setState(() => _manualFerry = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Auswahl zurücksetzen',
                              onPressed: () => setState(() {
                                _manualFerry = null;
                                _manualFerryDeparture = null;
                              }),
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        );
                      }),
                      const SizedBox(height: 8),
                      // Test widget: liefert ein FerryRoute-Objekt an die RouteInputWidget-Instanz
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: RouteInputWidget(
                          detectedRoute: _manualFerry ??
                              (_routes.isNotEmpty ? _routes.first : null),
                        ),
                      ),
                      if (_manualFerry != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('🕓 Manuelle Abfahrtszeit für Fähre',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () async {
                                        final now = DateTime.now();
                                        final d = await showDatePicker(
                                          context: context,
                                          firstDate: now,
                                          lastDate: now
                                              .add(const Duration(days: 365)),
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
                                        child: Text(_manualFerryDeparture ==
                                                null
                                            ? 'Kein Datum'
                                            : DateFormat('yyyy-MM-dd').format(
                                                _manualFerryDeparture!)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10, horizontal: 8),
                                      ),
                                      onPressed: () async {
                                        final now = DateTime.now();
                                        final initial =
                                            _manualFerryDeparture?.hour ??
                                                now.hour;
                                        final sel = await _showWheelPicker(
                                            context, initial, 23);
                                        if (sel != null) {
                                          setState(() {
                                            final prev =
                                                _manualFerryDeparture ??
                                                    DateTime.now();
                                            _manualFerryDeparture = DateTime(
                                                prev.year,
                                                prev.month,
                                                prev.day,
                                                sel,
                                                prev.minute);
                                          });
                                        }
                                      },
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.access_time,
                                              size: 18),
                                          const SizedBox(width: 6),
                                          Text(
                                            _manualFerryDeparture == null
                                                ? 'Stunde'
                                                : _manualFerryDeparture!.hour
                                                    .toString()
                                                    .padLeft(2, '0'),
                                            style:
                                                const TextStyle(fontSize: 16),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10, horizontal: 8),
                                      ),
                                      onPressed: () async {
                                        final now = DateTime.now();
                                        final initial =
                                            _manualFerryDeparture?.minute ??
                                                now.minute;
                                        final sel = await _showWheelPicker(
                                            context, initial, 59);
                                        if (sel != null) {
                                          setState(() {
                                            final prev =
                                                _manualFerryDeparture ??
                                                    DateTime.now();
                                            _manualFerryDeparture = DateTime(
                                                prev.year,
                                                prev.month,
                                                prev.day,
                                                prev.hour,
                                                sel);
                                          });
                                        }
                                      },
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const SizedBox(width: 4),
                                          Text(
                                            _manualFerryDeparture == null
                                                ? 'Minute'
                                                : _manualFerryDeparture!.minute
                                                    .toString()
                                                    .padLeft(2, '0'),
                                            style:
                                                const TextStyle(fontSize: 16),
                                          ),
                                        ],
                                      ),
                                    ),
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
                    icon: const Icon(Icons.route),
                    label: const Text('📦 Berechnen & ETA anzeigen'),
                    onPressed: _compute,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: pad,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.map),
                    label: const Text('🗺️ Karte (macOS) anzeigen'),
                    onPressed: _openMapOsm,
                  ),
                ),
                Padding(
                  padding: pad,
                  child: SwitchListTile(
                    value: _showDetails,
                    onChanged: (v) => setState(() => _showDetails = v),
                    title: const Text('🔧 Details/Debug anzeigen'),
                    subtitle: const Text('Technische Hinweise ein-/ausblenden'),
                  ),
                ),
                if (_log.isNotEmpty)
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
                if (_arrival != null)
                  Padding(
                    padding: pad,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Column(
                          children: [
                            const Text('✅ Ankunftszeit',
                                style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 8),
                            Text(DateFormat('EEEE, dd.MM.yyyy – HH:mm', 'de')
                                .format(_arrival!)),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ), // <-- Column schließen (Komma!)
    ); // <-- Scaffold schließen (Semikolon)
  }

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
}
