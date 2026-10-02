import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'articulation.dart';
import 'cinematic_camera.dart';
import 'tour_camera.dart';
import 'tour_path.dart';

/// EXPERIMENT – Cinematic-Outro v1: das Finale nach Erreichen des Ziels.
///
/// Reine Rechnung ohne Flutter und ohne Uhr: Jeder Zustand (Kamera, Licht,
/// Einblendungen) ist eine Funktion der Outro-Zeit [t] in Sekunden ab
/// Ankunft. 1×/2×/4× ändern nur, wie schnell [t] läuft – nie Ablauf oder
/// Gestaltung. Gleiche Tour + gleiche Zeit = gleiches Bild (Videoexport).

/// Ein Land der Reise in Fahrtreihenfolge.
class OutroCountry {
  const OutroCountry(this.iso, this.name);
  final String iso;
  final String name;
}

/// Was das Finale zeigt – ausschließlich aus der fertigen Tour.
class OutroData {
  const OutroData({
    required this.from,
    required this.to,
    required this.km,
    required this.countries,
    this.days,
    this.ferries = 0,
  });

  final String from;
  final String to;
  final double km;

  /// Durchfahrene Länder in tatsächlicher Reihenfolge (nicht dedupliziert).
  final List<OutroCountry> countries;

  /// Fahrtage laut Planung; null = unbekannt (dann nicht gezeigt).
  final int? days;

  /// Fährüberfahrten der Tour (Fährabschnitte der Linie).
  final int ferries;

  /// Anzahl verschiedener Länder (für „8 LÄNDER“).
  int get distinctCountries => countries.map((c) => c.iso).toSet().length;
}

/// Fährüberfahrten einer Tour = Fährabschnitte der Linie.
int ferryCount(TourPath path) =>
    path.legs.where((l) => l.kind == TourLegKind.ferry && l.points.length >= 2).length;

double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// Weicher als smoothstep (ruhiger Anfang und Auslauf).
double _smoother(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * t * (t * (t * 6 - 15) + 10);
}

double _ramp(double t, double a, double b) => b <= a ? (t >= a ? 1 : 0) : _smooth((t - a) / (b - a));

/// Zeitplan des Outros (Sekunden ab Ankunft) mit Markern für die spätere
/// Musik-Synchronisierung.
class OutroTimeline {
  OutroTimeline({required this.countryCount}) {
    // Länder: 0,18–0,42 s Abstand, zusammen höchstens ≈ 3,6 s.
    countryStep = countryCount <= 0 ? 0 : (3.6 / countryCount).clamp(0.18, 0.42);
    countriesComplete = countriesStart + countryCount * countryStep + entryFade;
    statsReveal = math.max(5.6, countriesComplete - 0.4);
    finalLogo = statsReveal + 1.8;
    end = finalLogo + 2.0;
  }

  final int countryCount;

  static const double arrival = 0;
  static const double heroReveal = 1.2;
  static const double lightsOn = 3.0;
  static const double countriesStart = 3.6;

  /// Dauer, in der ein Eintrag hereinkommt.
  static const double entryFade = 0.5;

  late final double countryStep;
  late final double countriesComplete;
  late final double statsReveal;
  late final double finalLogo;

  /// Ende; die letzten ≥ 2 s steht das fertige Bild ruhig.
  late final double end;

  Duration get duration => Duration(microseconds: (end * 1e6).round());

  /// Musikmarker in Reihenfolge.
  Map<String, double> get markers => {
        'arrival': arrival,
        'heroReveal': heroReveal,
        'lightsOn': lightsOn,
        'countriesStart': countriesStart,
        'countriesComplete': countriesComplete,
        'statsReveal': statsReveal,
        'finalLogo': finalLogo,
        'end': end,
      };

  // --------------------------------------------------------- Einblendungen

  /// Abdunklung der Umgebung 0..1 (Ziel bleibt erkennbar).
  double dim(double t) => _ramp(t, 0.8, 3.2);

  /// Titel „Tour abgeschlossen“ / Ankunftsort.
  double title(double t) => _ramp(t, heroReveal + 0.3, heroReveal + 1.2);

  /// Eintrag [i] der Länderliste 0..1.
  double country(int i, double t) {
    final s = countriesStart + i * countryStep;
    return _ramp(t, s, s + entryFade);
  }

  double stats(double t) => _ramp(t, statsReveal, statsReveal + 0.8);
  double logo(double t) => _ramp(t, finalLogo, finalLogo + 0.9);

  // ---------------------------------------------------------------- Licht

  /// Rück- und Begrenzungslichter.
  double tailLights(double t) => _ramp(t, lightsOn, lightsOn + 0.4);

  /// Scheinwerfer (und Lichtkegel), weich nach den Rücklichtern.
  double headLights(double t) => _ramp(t, lightsOn + 0.4, lightsOn + 1.0);

  /// Lichtlauf über Kabine und Auflieger: Position 0 (Front) … 1 (Heck),
  /// null außerhalb des Laufs.
  double? sweep(double t) {
    const a = lightsOn + 1.0, b = lightsOn + 2.0;
    if (t < a || t > b) return null;
    return _smoother((t - a) / (b - a));
  }
}

/// Licht-Zustand für ein Fahrzeugbild – quantisiert, damit nur wenige Bilder
/// entstehen und jeder Schritt klein bleibt.
class OutroLights {
  const OutroLights({required this.tail, required this.head, this.sweep});

  final double tail;
  final double head;
  final double? sweep;

  factory OutroLights.at(OutroTimeline tl, double t) {
    double q8(double v) => (v.clamp(0.0, 1.0) * 8).round() / 8;
    final s = tl.sweep(t);
    return OutroLights(
      tail: q8(tl.tailLights(t)),
      head: q8(tl.headLights(t)),
      sweep: s == null ? null : (s * 16).round() / 16,
    );
  }

  String get key => 't${(tail * 8).round()}h${(head * 8).round()}s${sweep == null ? '-' : (sweep! * 16).round()}';
}

// ---------------------------------------------------------------- Kamera

/// Wo der Truck im Bild stehen soll (Anteil der Breite/Höhe ab oben links)
/// und wie groß (Länge als Anteil der Breite).
({double x, double y, double length}) outroComposition({required bool portrait}) =>
    portrait ? (x: 0.6, y: 0.56, length: 0.48) : (x: 0.66, y: 0.52, length: 0.36);

/// Hero-Kamera des Outros. Startet exakt im letzten Zustand der Fahrt
/// ([from]) und fährt in eine 3/4-Ansicht schräg von vorn links, näher heran
/// (Zoom – der Truck wird nicht vergrößert), steiler, Truck rechts der Mitte.
class OutroCamera {
  OutroCamera({
    required this.from,
    required this.truck,
    required this.heading,
    required this.followZoom,
    required this.truckPointsPerMeter,
    required this.width,
    required this.height,
    required this.timeline,
  });

  final CameraState from;

  /// Fahrzeug am Ziel (Sattelpunkt) und Richtung der Zugmaschine.
  final LatLng truck;
  final double heading;
  final double followZoom;

  /// Bildschirmpunkte je Fahrzeugmeter beim Folge-Zoom.
  final double truckPointsPerMeter;
  final double width;
  final double height;
  final OutroTimeline timeline;

  static const double heroOrbit = -152; // Kamera vorn links: Front + linke Seite
  static const double heroPitch = 56;

  bool get portrait => width < height;

  /// Zoom, bei dem der Sattelzug (16,8 m) die gewünschte Bildlänge hat.
  double get heroZoom {
    final c = outroComposition(portrait: portrait);
    final want = math.min(c.length * width, 0.5 * height);
    final now = 16.8 * truckPointsPerMeter;
    return followZoom + math.log(want / now) / math.ln2;
  }

  double get heroBearing => (heading - heroOrbit) % 360;

  /// Blickpunkt so, dass der Truck an der Kompositionsstelle steht.
  LatLng heroTarget(double bearing, double zoom, double pitch) {
    final c = outroComposition(portrait: portrait);
    final mpp = metersPerScreenPoint(zoom, truck.latitude);
    final dx = (c.x - 0.5) * width * mpp; // Truck rechts der Mitte
    final dy = (c.y - 0.5) * height * mpp / math.cos(pitch * math.pi / 180);
    // Mitte = Truck − dx nach rechts − dy nach unten.
    final p = destination(truck, dx, (bearing - 90 + 360) % 360);
    return destination(p, dy, bearing);
  }

  CameraState at(double t) {
    // Phase 1 (0–1,2 s): ruhig weiter, minimal näher und steiler.
    // Phase 2 (0,4–3,4 s): Drohne schwenkt in die 3/4-Ansicht.
    // Danach: sehr langsamer Nachlauf, der vor dem Schluss stillsteht.
    final move = _smoother((t - 0.4) / 3.0);
    final settle = _smoother((t - 3.4) / math.max(0.1, timeline.end - 2.0 - 3.4));
    final bearingTarget = (heroBearing + 6 * settle) % 360;
    final bearing = (from.bearing + angleDiff(from.bearing, bearingTarget) * move + 360) % 360;
    final arrive = _smooth(t / 1.2);
    final zoom = from.zoom + 0.25 * arrive * (1 - move) + (heroZoom - 0.12 + 0.12 * settle - from.zoom) * move;
    final pitch = from.pitch + 3 * arrive * (1 - move) + (heroPitch - from.pitch) * move;
    final hero = heroTarget(bearing, zoom, pitch);
    final lat = from.target.latitude + (hero.latitude - from.target.latitude) * _smoother((t - 0.1) / 3.2);
    final lon = from.target.longitude + (hero.longitude - from.target.longitude) * _smoother((t - 0.1) / 3.2);
    return CameraState(
      target: LatLng(lat, lon),
      bearing: bearing,
      pitch: pitch,
      zoom: zoom,
      shot: t < OutroTimeline.heroReveal ? 'ARRIVAL' : 'HERO',
      orbit: heroOrbit * move,
    );
  }
}
