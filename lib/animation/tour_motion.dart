import 'dart:math' as math;

import 'articulation.dart';
import 'cinematic_camera.dart';
import 'tour_camera.dart';
import 'ferry_cinematic.dart';
import 'tour_path.dart';

/// Wie schnell der Sattelzug in der Cinematic-Animation sichtbar fährt –
/// reine Rechnung, ohne Uhr.
///
/// Bisher lief die Fahrt nach [tourEase] gleichmäßig über die Strecke: auf
/// einer langen Tour rund 1,4 km Kartenstrecke je Bild, in Kurven genauso
/// schnell wie auf der Geraden. Hier entsteht stattdessen ein ruhiges
/// Filmtempo:
///
/// - Der Zug fährt [slow]-mal langsamer als bisher.
/// - Die Kamerafahrten behalten ihre Dauer in Sekunden: [retimePlan] setzt
///   sie neu auf die langsamere Fahrt (gleicher Startort, gleiche Dauer).
/// - In Kurven begrenzt die Drehrate der Zugmaschine das Tempo: höchstens
///   [maxTurn] Grad je Sekunde. Davor wird weich gebremst, danach weich
///   beschleunigt (geglättete Zeitdichte, keine Sprünge).
/// - Anfahren und Ankommen bleiben sanft.
///
/// Ergebnis ist eine monotone Zuordnung Fahrzeit ↔ Streckenmeter. Gleiche
/// Tour, gleiche Zuordnung – bei jedem Wiedergabetempo.
class TourMotion {
  TourMotion({
    required this.path,
    required Duration oldDrive,
    required ArticulatedTrack track,
    this.slow = 1.6,
    this.maxTurn = 100,
    this.curveRef = 120,
    int samples = 4000,
  }) {
    final total = path.totalMeters;
    final n = math.max(2, samples);
    final dm = total / n;
    final oldS = math.max(0.1, oldDrive.inMicroseconds / 1e6);
    // Reisetempo der bisherigen Fahrt (Mitte von tourEase).
    const r = 0.06;
    final v0 = total / oldS / (1 - r / 2);

    // Drehrate der Zugmaschine je Meter, vorausschauend als Maximum über
    // ±2 Radstände (früh bremsen, spät beschleunigen).
    final heading = [for (var i = 0; i <= n; i++) track.tractorHeadingAt(i * dm)];
    final rate = List<double>.filled(n + 1, 0);
    for (var i = 1; i <= n; i++) {
      rate[i] = angleDiff(heading[i - 1], heading[i]).abs() / math.max(1e-6, dm);
    }
    final look = math.max(1, (2 * track.dims.tractorWheelbase * _unitGuess(track) / dm).round());
    final rateMax = List<double>.filled(n + 1, 0);
    for (var i = 0; i <= n; i++) {
      var m = 0.0;
      for (var j = math.max(0, i - look); j <= math.min(n, i + look); j++) {
        m = math.max(m, rate[j]);
      }
      rateMax[i] = m;
    }

    // Zeitdichte (Sekunden je Meter) je Rasterpunkt.
    final rho = List<double>.filled(n + 1, 0);
    for (var i = 0; i <= n; i++) {
      // Kurven sichtbar ruhiger: je stärker die Zugmaschine bei Reisetempo
      // drehen würde, desto langsamer (weich), dazu die harte Grenze.
      final turnAtBase = v0 / slow * rateMax[i];
      final base = v0 / slow / (1 + turnAtBase / curveRef);
      final cap = rateMax[i] <= 0 ? double.infinity : maxTurn / rateMax[i];
      rho[i] = 1 / math.max(1e-9, math.min(base, cap));
    }
    // Weich: gleitender Mittelwert über ≈ 1,5 % der Strecke.
    final k = math.max(1, (n * 0.0075).round());
    final smooth = List<double>.filled(n + 1, 0);
    var acc = 0.0;
    final prefix = <double>[0];
    for (final v in rho) {
      acc += v;
      prefix.add(acc);
    }
    for (var i = 0; i <= n; i++) {
      final a = math.max(0, i - k), b = math.min(n, i + k);
      smooth[i] = (prefix[b + 1] - prefix[a]) / (b - a + 1);
    }
    // Sanftes Anfahren und Ankommen über je ≈ 2,5 s der Normalfahrt.
    final ease = 2.5 * v0 / slow;
    for (var i = 0; i <= n; i++) {
      final m = i * dm;
      final e = math.min(1.0, math.min(m, total - m) / math.max(1, ease));
      final ramp = 0.25 + 0.75 * e * e * (3 - 2 * e);
      smooth[i] /= ramp;
    }
    // Kumulierte Zeit.
    _t.add(0);
    for (var i = 1; i <= n; i++) {
      _t.add(_t.last + dm * (smooth[i - 1] + smooth[i]) / 2);
    }
    _dm = dm;
  }

  final TourPath path;

  /// Tempo-Faktor der normalen Fahrt gegenüber bisher.
  final double slow;

  /// Höchste sichtbare Drehrate der Zugmaschine in Grad je Sekunde.
  final double maxTurn;

  /// Weiche Kurvenbremse: bei dieser Drehrate (°/s, im Reisetempo) halbes Tempo.
  final double curveRef;

  final List<double> _t = [];
  double _dm = 1;

  static double _unitGuess(ArticulatedTrack track) =>
      track.path.totalMeters <= 0 ? 1 : 3.1 * metersPerScreenPoint(tourFollowZoom(track.path.totalMeters) + 0.6, track.path.start.latitude);

  Duration get duration => Duration(microseconds: (_t.last * 1e6).round());

  /// Fahrzeit (s), zu der das Fahrzeug [meters] erreicht.
  double secondsAt(double meters) {
    final x = meters.clamp(0.0, path.totalMeters) / _dm;
    final i = x.floor().clamp(0, _t.length - 1);
    final j = math.min(i + 1, _t.length - 1);
    return _t[i] + (_t[j] - _t[i]) * (x - i);
  }

  /// Streckenmeter nach [seconds] Fahrzeit.
  double metersAt(double seconds) {
    if (seconds <= 0) return 0;
    if (seconds >= _t.last) return path.totalMeters;
    var lo = 0, hi = _t.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_t[mid] <= seconds) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final f = (_t[hi] - _t[lo]) <= 0 ? 0.0 : (seconds - _t[lo]) / (_t[hi] - _t[lo]);
    return math.min(path.totalMeters, (lo + f) * _dm);
  }
}

/// Streckenbereiche (Anteil 0..1), in denen die Kamera eine Fahrt macht –
/// vom letzten FOLLOW-Stützpunkt davor bis zum ersten danach.
List<(double, double)> cameraWindows(CinematicPlan plan) {
  final keys = plan.keys;
  final out = <(double, double)>[];
  var i = 0;
  while (i < keys.length) {
    if (keys[i].shot != 'FOLLOW') {
      final a = i > 0 ? keys[i - 1].p : keys[i].p;
      var j = i;
      while (j < keys.length && keys[j].shot != 'FOLLOW') {
        j++;
      }
      final b = j < keys.length ? keys[j].p : 1.0;
      if (out.isNotEmpty && a <= out.last.$2) {
        out[out.length - 1] = (out.last.$1, math.max(out.last.$2, b));
      } else {
        out.add((a, b));
      }
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

/// Bisherige Fahrzeit (s, nach [tourEase]) bis zum Streckenanteil [p].
double legacyDriveSeconds(double p, Duration drive) {
  final target = p.clamp(0.0, 1.0);
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 40; i++) {
    final mid = (lo + hi) / 2;
    if (tourEase(mid) < target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return hi * drive.inMicroseconds / 1e6;
}

/// Kameraregie auf die neue Fahrt umsetzen: Jede Kamerafahrt beginnt am
/// selben Ort und dauert so viele Sekunden wie bisher; nur die ruhige
/// FOLLOW-Fahrt dazwischen wird länger. Fahrten, die an eine Fähre gebunden
/// sind (Häfen, Seestrecke), bleiben an ihrem Ort.
CinematicPlan retimePlan(CinematicPlan plan, TourMotion motion, Duration oldDrive,
    {Set<String> fixed = const {'TO PORT', 'FERRY FOLLOW', 'FERRY SIDE 3/4', 'HIGH DRONE', 'TO DEST PORT'}}) {
  final total = motion.path.totalMeters;
  if (total <= 0) return plan;
  final keys = plan.keys;
  final out = <ShotKey>[];
  var i = 0;
  while (i < keys.length) {
    final k = keys[i];
    if (k.shot == 'FOLLOW' || i == 0) {
      out.add(k);
      i++;
      continue;
    }
    // Fahrt: vom FOLLOW-Stützpunkt davor bis zum ersten FOLLOW danach.
    var j = i;
    while (j < keys.length && keys[j].shot != 'FOLLOW') {
      j++;
    }
    final end = j < keys.length ? j : keys.length - 1;
    final group = keys.sublist(i, end + 1);
    if (group.any((g) => fixed.contains(g.shot))) {
      out.addAll(group);
    } else {
      final anchor = keys[i - 1].p;
      final t0Old = legacyDriveSeconds(anchor, oldDrive);
      final t0New = motion.secondsAt(anchor * total);
      for (final g in group) {
        final t = t0New + legacyDriveSeconds(g.p, oldDrive) - t0Old;
        final p = motion.metersAt(t) / total;
        out.add(ShotKey(math.max(p, out.last.p + 1e-6), g.shot,
            orbit: g.orbit, pitch: g.pitch, zoom: g.zoom, ahead: g.ahead));
      }
    }
    i = end + 1;
  }
  return CinematicPlan(out);
}

/// Ruhiges Filmtempo und dazu passende Kameraregie für eine Tour – rein aus
/// der Linie berechnet; [truckScale] wie in der Szene.
({TourMotion motion, CinematicPlan plan}) cinematicMotionFor(TourPath path,
    {bool demo = false, double truckScale = 1}) {
  final oldDrive = tourAnimationDuration(path.totalMeters);
  final zoom = (tourFollowZoom(path.totalMeters) + 0.6).clamp(tourMinZoom, tourMaxZoom);
  final track = ArticulatedTrack(path,
      unitAt: (p) => 5 * truckScale * 0.62 * metersPerScreenPoint(zoom, p.latitude),
      inertia: cinematicTruckInertia);
  final motion = TourMotion(path: path, oldDrive: oldDrive, track: track);
  return (motion: motion, plan: retimePlan(cinematicPlanFor(path, demo: demo), motion, oldDrive));
}
