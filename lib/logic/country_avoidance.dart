import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/route_candidate.dart';
import '../services/country_geo.dart';
import 'avoidable_countries.dart';
import 'ferry_auto.dart';

/// Fehler, der gemeldet wird, wenn eine Ländersperre nicht eingehalten werden
/// kann. (Lag früher in serbia_avoidance.dart; die Meldung wird in main.dart
/// als Snackbar angezeigt.)
class CountryRouteException implements Exception {
  final String message;
  const CountryRouteException(this.message);

  @override
  String toString() => message;
}

/// Signatur des Routing-Aufrufs. Wird injiziert, damit die Logik ohne
/// Netzwerkzugriff testbar bleibt.
typedef DirectionsFetcher = Future<DirectionsFetchResult> Function({
  required String origin,
  required String destination,
  List<String> waypoints,
  bool optimize,
  bool avoidFerries,
  bool alternatives,
});

/// Ergebnis der automatischen Ländersperre.
class AvoidancePlan {
  /// Route gefunden (auch wenn sie evtl. noch ein gesperrtes Land berührt).
  final bool ok;
  final String status;

  /// Die final gewählte Route – Basis für km, Fahrzeit, ETA, Karte.
  final RouteCandidate? route;

  /// Wegpunkte, mit denen [route] berechnet wurde:
  /// Zwischenstopps des Fahrers + automatisch ergänzte Umfahrungspunkte.
  final List<String> effectiveWaypoints;

  /// Nur die automatisch erzeugten Umfahrungspunkte.
  final List<LatLng> autoDetours;

  /// Darf `optimize:true` noch benutzt werden? Sobald automatische
  /// Umfahrungspunkte gesetzt sind: nein (Google würde sie umsortieren).
  final bool optimizeAllowed;

  /// Länder, die die finale Route durchquert (ISO → km).
  final Map<String, double> countriesOnRoute;

  /// Gesperrte Länder, die trotz aller Versuche noch durchfahren werden.
  final List<String> stillBlocked;

  final List<String> log;

  const AvoidancePlan({
    required this.ok,
    required this.status,
    required this.route,
    required this.effectiveWaypoints,
    required this.autoDetours,
    required this.optimizeAllowed,
    required this.countriesOnRoute,
    required this.stillBlocked,
    required this.log,
  });

  bool get isClean => ok && stillBlocked.isEmpty;
}

class _Detour {
  final LatLng point;
  /// Position innerhalb des Nutzer-Abschnitts (0..1) – für die Reihenfolge.
  final double frac;
  const _Detour(this.point, this.frac);

  String get wp => '${point.latitude.toStringAsFixed(5)},'
      '${point.longitude.toStringAsFixed(5)}';
}

class _Blocked {
  final String iso;
  final int segment;
  final LatLng entry;
  final LatLng exit;
  final double entryFrac;
  final double exitFrac;
  const _Blocked(this.iso, this.segment, this.entry, this.exit, this.entryFrac, this.exitFrac);
}

/// Berechnet automatisch eine Route, die die gesperrten Länder meidet.
///
/// Vorgehen (ohne jede Nutzereingabe und ohne hartkodierte Umfahrungsorte):
/// 1. Route inkl. Alternativrouten abrufen.
/// 2. Jede Variante geometrisch gegen die Ländergrenzen prüfen.
/// 3. Ist eine Variante sauber → nehmen.
/// 4. Sonst: den im gesperrten Land liegenden Abschnitt bestimmen und
///    rechtwinklig dazu automatisch Ausweichpunkte in wachsendem Abstand
///    erzeugen, die nachweislich außerhalb aller gesperrten Länder und auf
///    Land liegen. Jeder Kandidat wird als Wegpunkt erneut geroutet und das
///    Ergebnis wieder geprüft.
/// 5. Mehrere gesperrte Länder werden runde für runde abgearbeitet.
class CountryAvoidancePlanner {
  final DirectionsFetcher fetch;

  /// Abstände (km), in denen automatisch Ausweichpunkte gesucht werden.
  final List<double> offsetsKm;

  /// Maximal so viele automatische Umfahrungspunkte.
  final int maxDetours;

  /// Obergrenze für Routing-Requests, damit die Suche nicht ausufert.
  final int maxRequests;

  /// Ab wie vielen Kilometern im Land gilt es als "durchfahren"?
  /// Schützt vor Fehlalarm bei grenznahen Autobahnen.
  final double minCrossingKm;

  int _requests = 0;
  final List<String> _log = [];

  CountryAvoidancePlanner({
    required this.fetch,
    this.offsetsKm = const [70, 120, 190, 280, 400],
    this.maxDetours = 3,
    this.maxRequests = 12,
    this.minCrossingKm = 4.0,
  });

  Future<AvoidancePlan> plan({
    required String origin,
    required String destination,
    List<String> stops = const [],
    bool optimize = false,
    Set<String> avoided = const {},
  }) async {
    await CountryGeo.ensureLoaded();

    final detours = List<List<_Detour>>.generate(stops.length + 1, (_) => <_Detour>[]);

    List<String> buildWaypoints() {
      final out = <String>[];
      for (var j = 0; j < stops.length; j++) {
        out.addAll(detours[j].map((d) => d.wp));
        out.add(stops[j]);
      }
      out.addAll(detours[stops.length].map((d) => d.wp));
      return out;
    }

    bool hasDetours() => detours.any((l) => l.isNotEmpty);

    AvoidancePlan fail(String status, {RouteCandidate? route, List<String> blocked = const []}) =>
        AvoidancePlan(
          ok: route != null,
          status: status,
          route: route,
          effectiveWaypoints: buildWaypoints(),
          autoDetours: [for (final l in detours) ...l.map((d) => d.point)],
          optimizeAllowed: optimize && !hasDetours(),
          countriesOnRoute: route == null ? const {} : CountryGeo.kmPerCountry(route.points),
          stillBlocked: blocked,
          log: List.of(_log),
        );

    AvoidancePlan success(RouteCandidate route) => AvoidancePlan(
          ok: true,
          status: 'OK',
          route: route,
          effectiveWaypoints: buildWaypoints(),
          autoDetours: [for (final l in detours) ...l.map((d) => d.point)],
          optimizeAllowed: optimize && !hasDetours(),
          countriesOnRoute: CountryGeo.kmPerCountry(route.points),
          stillBlocked: const [],
          log: List.of(_log),
        );

    // --- Sonderfall: Start/Ziel/Stopp liegt selbst im gesperrten Land -------
    // Dann ist keine Umfahrung möglich; das muss ehrlich gemeldet werden statt
    // endlos zu suchen.

    // Runde 0..n: routen, prüfen, ggf. einen Umfahrungspunkt ergänzen.
    DirectionsFetchResult? res;
    for (var round = 0; round <= maxDetours; round++) {
      if (_requests >= maxRequests) {
        _log.add('⚠️ Ländersperre: Suchbudget erschöpft.');
        break;
      }
      _requests++;
      res = await fetch(
        origin: origin,
        destination: destination,
        waypoints: buildWaypoints(),
        optimize: optimize && !hasDetours(),
        avoidFerries: false,
        // Alternativrouten kosten nichts extra, werden aber nur gebraucht,
        // wenn wirklich eine Sperre geprüft werden muss.
        alternatives: avoided.isNotEmpty,
      );

      if (!res.ok || res.candidates.isEmpty) {
        _log.add('⚠️ Ländersperre: Routing fehlgeschlagen (${res.status}).');
        return fail(res.status);
      }

      if (avoided.isEmpty) return success(res.candidates.first);

      // Sauberste Variante suchen: keine gesperrten Länder, kürzeste zuerst.
      final ranked = _rank(res.candidates, avoided, stops.length, detours);
      if (ranked.first.blocked.isEmpty) {
        if (round > 0 || res.candidates.length > 1) {
          _log.add('✅ Ländersperre: gültige Route gefunden '
              '(${ranked.first.route.km.toStringAsFixed(0)} km).');
        }
        return success(ranked.first.route);
      }

      final best = ranked.first;
      final blocking = best.blocked.first;
      _log.add('🚧 Route führt durch ${_name(blocking.iso)} – suche automatisch eine Umfahrung.');

      if (round == maxDetours) break;

      // Liegt ein Fixpunkt (Start/Ziel/Stopp) selbst im gesperrten Land?
      final fixed = await _fixedPointInside(best.route, avoided, stops.length, detours);
      if (fixed != null) {
        _log.add('⛔ ${_name(fixed)} kann nicht umfahren werden: Start, Ziel oder ein '
            'Zwischenstopp liegt in diesem Land.');
        return fail('BLOCKED_ENDPOINT', route: best.route, blocked: best.blocked.map((b) => b.iso).toList());
      }

      final detour = await _findDetour(
        origin: origin,
        destination: destination,
        stops: stops,
        detours: detours,
        buildWaypoints: buildWaypoints,
        blocking: blocking,
        avoided: avoided,
        optimize: optimize,
      );

      if (detour == null) {
        _log.add('⚠️ Keine automatische Umfahrung von ${_name(blocking.iso)} gefunden.');
        return fail('NO_DETOUR', route: best.route, blocked: best.blocked.map((b) => b.iso).toList());
      }

      detours[blocking.segment].add(detour);
      detours[blocking.segment].sort((a, b) => a.frac.compareTo(b.frac));
      _log.add('↪️ Automatischer Umfahrungspunkt gesetzt: ${detour.wp} '
          '(${CountryGeo.nameOf(CountryGeo.countryAt(detour.point) ?? '')}).');
    }

    // Beste erreichbare Route zurückgeben, aber ehrlich melden, dass sie noch
    // durch ein gesperrtes Land führt.
    if (res != null && res.ok && res.candidates.isNotEmpty) {
      final ranked = _rank(res.candidates, avoided, stops.length, detours);
      final blocked = ranked.first.blocked.map((b) => b.iso).toList();
      if (blocked.isEmpty) return success(ranked.first.route);
      return fail('STILL_BLOCKED', route: ranked.first.route, blocked: blocked);
    }
    return fail('NO_ROUTE');
  }

  // --- Bewertung -----------------------------------------------------------

  List<_Ranked> _rank(
    List<RouteCandidate> candidates,
    Set<String> avoided,
    int stopCount,
    List<List<_Detour>> detours,
  ) {
    final out = <_Ranked>[];
    for (final c in candidates) {
      out.add(_Ranked(c, _blockedStretches(c, avoided, stopCount, detours)));
    }
    out.sort((a, b) {
      if (a.blocked.isEmpty != b.blocked.isEmpty) return a.blocked.isEmpty ? -1 : 1;
      if (a.blocked.length != b.blocked.length) return a.blocked.length - b.blocked.length;
      return a.route.km.compareTo(b.route.km);
    });
    return out;
  }

  /// Legs → Nutzer-Abschnitte. Abschnitt j enthält (detours[j].length + 1) Legs.
  List<List<LatLng>> _segmentPolylines(
    RouteCandidate c,
    int stopCount,
    List<List<_Detour>> detours,
  ) {
    final segs = <List<LatLng>>[];
    var leg = 0;
    for (var j = 0; j <= stopCount; j++) {
      final count = (j < detours.length ? detours[j].length : 0) + 1;
      final pts = <LatLng>[];
      for (var k = 0; k < count && leg < c.legPoints.length; k++, leg++) {
        pts.addAll(c.legPoints[leg]);
      }
      segs.add(pts);
    }
    // Falls Google anders segmentiert hat (z. B. optimize), Rest anhängen.
    while (leg < c.legPoints.length) {
      segs.last.addAll(c.legPoints[leg++]);
    }
    return segs;
  }

  /// Alle zusammenhängenden Abschnitte in gesperrten Ländern, längster zuerst.
  List<_Blocked> _blockedStretches(
    RouteCandidate c,
    Set<String> avoided,
    int stopCount,
    List<List<_Detour>> detours,
  ) {
    if (avoided.isEmpty) return const [];
    final segs = _segmentPolylines(c, stopCount, detours);
    final found = <_Blocked>[];
    final lengths = <String, double>{};

    for (var j = 0; j < segs.length; j++) {
      final pts = segs[j];
      if (pts.length < 2) continue;
      final total = _pathKm(pts);
      if (total <= 0) continue;

      String? runIso;
      int runStart = 0;
      double runKm = 0;
      double acc = 0;
      double accAtRunStart = 0;

      void close(int endIdx, double endAcc) {
        if (runIso == null) return;
        lengths[runIso!] = (lengths[runIso!] ?? 0) + runKm;
        if (runKm >= minCrossingKm) {
          final entryIdx = runStart > 0 ? runStart - 1 : 0;
          final exitIdx = endIdx < pts.length ? endIdx : pts.length - 1;
          found.add(_Blocked(
            runIso!,
            j,
            pts[entryIdx],
            pts[exitIdx],
            (accAtRunStart / total).clamp(0.0, 1.0),
            (endAcc / total).clamp(0.0, 1.0),
          ));
        }
        runIso = null;
        runKm = 0;
      }

      for (var i = 0; i < pts.length - 1; i++) {
        final segKm = CountryGeo.distanceKm(pts[i], pts[i + 1]);
        final mid = LatLng(
          (pts[i].latitude + pts[i + 1].latitude) / 2,
          (pts[i].longitude + pts[i + 1].longitude) / 2,
        );
        // Nur gegen die gesperrten Länder testen – nicht gegen alle 41.
        final iso = CountryGeo.firstMatch(mid, avoided);
        final isBlocked = iso != null;
        if (isBlocked && iso == runIso) {
          runKm += segKm;
        } else {
          close(i, acc);
          if (isBlocked) {
            runIso = iso;
            runStart = i;
            accAtRunStart = acc;
            runKm = segKm;
          }
        }
        acc += segKm;
      }
      close(pts.length - 1, acc);
    }

    // Kurze Grenzberührungen ignorieren (vereinfachte Polygone, ~1 km genau).
    final real = found.where((b) => (lengths[b.iso] ?? 0) >= minCrossingKm).toList();
    real.sort((a, b) => (lengths[b.iso] ?? 0).compareTo(lengths[a.iso] ?? 0));
    return real;
  }

  /// Prüft, ob Start, Ziel oder ein Zwischenstopp selbst im gesperrten Land liegt.
  Future<String?> _fixedPointInside(
    RouteCandidate c,
    Set<String> avoided,
    int stopCount,
    List<List<_Detour>> detours,
  ) async {
    final segs = _segmentPolylines(c, stopCount, detours);
    final anchors = <LatLng>[];
    for (final s in segs) {
      if (s.isEmpty) continue;
      anchors.add(s.first);
      anchors.add(s.last);
    }
    for (final a in anchors) {
      final iso = CountryGeo.countryAt(a);
      if (iso != null && avoided.contains(iso)) return iso;
    }
    return null;
  }

  // --- Automatische Umfahrungspunkte ---------------------------------------

  /// Erzeugt Kandidaten rechtwinklig zum gesperrten Abschnitt und testet sie
  /// per echtem Routing. Kein einziger Ort ist hartkodiert – die Punkte folgen
  /// allein aus der Geometrie der blockierten Strecke.
  Future<_Detour?> _findDetour({
    required String origin,
    required String destination,
    required List<String> stops,
    required List<List<_Detour>> detours,
    required List<String> Function() buildWaypoints,
    required _Blocked blocking,
    required Set<String> avoided,
    required bool optimize,
  }) async {
    final mid = LatLng(
      (blocking.entry.latitude + blocking.exit.latitude) / 2,
      (blocking.entry.longitude + blocking.exit.longitude) / 2,
    );
    final axis = CountryGeo.bearingDeg(blocking.entry, blocking.exit);
    final frac = (blocking.entryFrac + blocking.exitFrac) / 2;

    // Kandidaten: abwechselnd links/rechts, Abstand aufsteigend.
    final candidates = <LatLng>[];
    for (final d in offsetsKm) {
      for (final side in const [90.0, -90.0]) {
        final p = CountryGeo.offsetKm(mid, (axis + side) % 360, d);
        if (CountryGeo.isInAny(p, avoided)) continue; // wieder im gesperrten Land
        if (!CountryGeo.isOnLand(p)) continue; // Meer / nicht erfasst
        candidates.add(p);
      }
    }

    if (candidates.isEmpty) return null;

    for (final p in candidates) {
      if (_requests >= maxRequests) return null;
      final probe = _Detour(p, frac);
      detours[blocking.segment].add(probe);
      detours[blocking.segment].sort((a, b) => a.frac.compareTo(b.frac));
      final wps = buildWaypoints();
      detours[blocking.segment].remove(probe);

      _requests++;
      final res = await fetch(
        origin: origin,
        destination: destination,
        waypoints: wps,
        optimize: false,
        avoidFerries: false,
        alternatives: true,
      );
      if (!res.ok || res.candidates.isEmpty) continue;

      // Testweise mit dem Probe-Umfahrungspunkt bewerten.
      detours[blocking.segment].add(probe);
      detours[blocking.segment].sort((a, b) => a.frac.compareTo(b.frac));
      final ranked = _rank(res.candidates, avoided, stops.length, detours);
      detours[blocking.segment].remove(probe);

      final stillSame = ranked.first.blocked.any((b) => b.iso == blocking.iso);
      if (!stillSame) {
        if (kDebugMode) {
          debugPrint('[Ländersperre] Umfahrung via ${probe.wp} löst ${blocking.iso}');
        }
        return probe;
      }
    }
    return null;
  }

  static double _pathKm(List<LatLng> pts) {
    double km = 0;
    for (var i = 0; i < pts.length - 1; i++) {
      km += CountryGeo.distanceKm(pts[i], pts[i + 1]);
    }
    return km;
  }

  static String _name(String iso) {
    final n = CountryGeo.nameOf(iso);
    return n == iso ? avoidableCountryNameDe(iso) : n;
  }
}

class _Ranked {
  final RouteCandidate route;
  final List<_Blocked> blocked;
  const _Ranked(this.route, this.blocked);
}
