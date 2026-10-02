import 'dart:math' as math;

import 'cinematic_camera.dart';
import 'tour_motion.dart';

/// EXPERIMENT – filmischer Rhythmus der Cinematic-Kamera.
///
/// Die Kamerafahrten der Regie (PASS, FRONT 3/4, RETURN, Fähre …) bleiben
/// unverändert. Neu gestaltet werden nur die ruhigen Strecken dazwischen,
/// damit die Kamera nicht dauernd im selben Abstand hängt:
///
/// - START: nah und etwas steiler am stehenden Lkw, dann öffnet sich die
///   Kamera langsam in die Reise.
/// - WIDE: weite Reiseaufnahme auf langen Strecken.
/// - MEDIUM: auf sehr langen Strecken zwischendurch wieder mittel.
/// - NIGHT: nachts näher heran, damit Scheinwerfer und Licht wirken.
/// - APPROACH: vor dem Ziel heran – das Outro beginnt aus dieser Nähe.
///
/// Der Lkw wird nie vergrößert: Nähe entsteht nur über den Kamerazoom.
/// Alles nach Fahrzeit (Sekunden), weich über die Stützpunkte der Regie –
/// gleiche Tour, gleiche Kamera, bei jedem Wiedergabetempo.
CinematicPlan dramatizePlan(
  CinematicPlan plan,
  TourMotion motion, {
  double Function(double meters)? nightAt,
}) {
  final total = motion.path.totalMeters;
  final T = motion.duration.inMicroseconds / 1e6;
  if (total <= 0 || T <= 0) return plan;
  double pAt(double s) => (motion.metersAt(s.clamp(0.0, T)) / total).clamp(0.0, 1.0);
  double sAt(double p) => motion.secondsAt(p * total);

  ShotKey key(double s, String name, double zoom, {double pitch = 42, double? ahead}) {
    final p = pAt(s);
    final base = plan.at(p);
    return ShotKey(p, name, orbit: base.orbit, pitch: pitch, zoom: zoom, ahead: ahead ?? base.ahead);
  }

  // Ruhige Strecken = alles außerhalb der Kamerafahrten.
  final windows = cameraWindows(plan);
  final stretches = <(double, double)>[];
  var cursor = 0.0;
  for (final (a, b) in windows) {
    if (a > cursor) stretches.add((cursor, a));
    cursor = math.max(cursor, b);
  }
  if (cursor < 1) stretches.add((cursor, 1));

  final extra = <ShotKey>[];
  final replace = <double, ShotKey>{};
  for (final (a, b) in stretches) {
    final sa = sAt(a), sb = sAt(b);
    final first = a <= 0;
    final last = b >= 1;
    // Weit oder – nachts – nah, je nach Dunkelheit in der Mitte der Strecke.
    final night = (nightAt?.call(((a + b) / 2) * total) ?? 0) > 0.6;
    final travel = night ? ('NIGHT', 1.0, 48.0) : ('WIDE', -0.6, 38.0);

    var from = sa, to = sb;
    if (first) {
      // Start: nah am Lkw, kurz halten, dann langsam öffnen.
      replace[0] = key(0, 'START', 2.0, pitch: 52, ahead: 0.15);
      extra.add(key(2.5, 'START', 2.0, pitch: 52, ahead: 0.15));
      from = 2.5 + 4.5; // Öffnen über ≈ 4,5 s
    } else {
      from = sa + 4;
    }
    if (last) {
      // Zielanflug: heran, das Outro übernimmt aus dieser Nähe.
      to = sb - 9;
      extra.add(key(sb - 3, 'APPROACH', 1.4, pitch: 48));
      replace[1] = key(sb, 'APPROACH', 1.4, pitch: 48);
    } else {
      to = sb - 4;
    }
    if (to - from < 3) continue; // zu kurz für eine eigene Einstellung
    final (name, zoom, pitch) = travel;
    if (to - from >= 26 && !night) {
      // Sehr lang: weit – mittel – weit.
      final mid = (from + to) / 2;
      extra
        ..add(key(from, name, zoom, pitch: pitch))
        ..add(key(mid - 4, name, zoom, pitch: pitch))
        ..add(key(mid, 'MEDIUM', 0.2))
        ..add(key(mid + 3, 'MEDIUM', 0.2))
        ..add(key(mid + 7, name, zoom, pitch: pitch))
        ..add(key(to, name, zoom, pitch: pitch));
    } else {
      extra
        ..add(key(from, name, zoom, pitch: pitch))
        ..add(key(to, name, zoom, pitch: pitch));
    }
  }

  final keys = <ShotKey>[
    for (final k in plan.keys) replace[k.p] ?? k,
    ...extra,
  ]..sort((x, y) => x.p.compareTo(y.p));
  // Streng aufsteigend (doppelte Stellen entfernen, Regie-Stützpunkt behalten).
  final out = <ShotKey>[];
  for (final k in keys) {
    if (out.isNotEmpty && k.p <= out.last.p + 1e-9) {
      if (_isDrama(out.last.shot)) out[out.length - 1] = k;
      continue;
    }
    out.add(k);
  }
  return CinematicPlan(out);
}

const _dramaShots = {'START', 'WIDE', 'MEDIUM', 'NIGHT', 'APPROACH'};

bool _isDrama(String shot) => _dramaShots.contains(shot);

/// Ob ein Stützpunkt zur Dramaturgie (nicht zur Kamerafahrt) gehört.
bool isDramaturgyShot(String shot) => _isDrama(shot);
