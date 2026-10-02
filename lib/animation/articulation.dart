import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'tour_path.dart';

/// Gekoppelter Sattelzug entlang einer [TourPath] – reine Geometrie.
///
/// Ohne Fahrphysik: Vorder- und Hinterachse der Zugmaschine liegen auf der
/// Route (die Zugmaschine fährt exakt auf der Straße), die Aufliegerachse
/// liegt [trailerWheelbase] hinter dem Sattelpunkt ebenfalls auf der Route.
/// Aus den drei Punkten folgen Zugmaschinen-Richtung, Auflieger-Richtung und
/// der Knickwinkel. Eine Funktion der Streckenposition – Bild für Bild
/// reproduzierbar, auch für Videoexport.
///
/// Die Maße werden mit [metersPerUnit] in Kartenmeter umgerechnet: Das
/// Fahrzeugsymbol ist stark überzeichnet, damit sein Auflieger der
/// SICHTBAREN Route folgt, rechnen wir mit seiner sichtbaren Größe.
class ArticulatedPose {
  const ArticulatedPose({
    required this.frontAxle,
    required this.kingpin,
    required this.trailerAxle,
    required this.tractorHeading,
    required this.trailerHeading,
  });

  final LatLng frontAxle;
  final LatLng kingpin;
  final LatLng trailerAxle;

  /// Richtungen in Grad (0 = Norden, im Uhrzeigersinn).
  final double tractorHeading;
  final double trailerHeading;

  /// Knickwinkel Auflieger gegen Zugmaschine, −180..180 (positiv: Auflieger
  /// steht nach rechts gedreht, d. h. Linkskurve).
  double get knick {
    var d = (trailerHeading - tractorHeading) % 360;
    if (d > 180) d -= 360;
    return d;
  }
}

/// Fahrzeugmaße in Metern (Standard-Sattelzug).
class TruckDimensions {
  const TruckDimensions({
    this.tractorWheelbase = 3.8,
    this.kingpinBehindFront = 3.5,
    this.trailerWheelbase = 10.5,
    this.maxKnick = 70,
  });

  /// Vorderachse → Hinterachse der Zugmaschine.
  final double tractorWheelbase;

  /// Vorderachse → Sattelpunkt (Königszapfen), knapp vor der Hinterachse.
  final double kingpinBehindFront;

  /// Sattelpunkt → Aufliegerachse(n).
  final double trailerWheelbase;

  /// Grenze gegen Einknicken an Polyline-Ecken.
  final double maxKnick;
}

const _hav = Distance(calculator: Haversine());

double _bearing(LatLng from, LatLng to) => (_hav.bearing(from, to) + 360) % 360;

/// Punkt in [dist] m Richtung [bearing]° (beliebiger Winkel). Eigene Formel:
/// latlong2 rundet `offset` auf 6 Stellen und verlangt −180…180°.
LatLng destination(LatLng p, double dist, double bearing) {
  const r = 6371008.8;
  final d = dist / r, b = bearing * math.pi / 180;
  final la1 = p.latitude * math.pi / 180, lo1 = p.longitude * math.pi / 180;
  final la2 = math.asin(math.sin(la1) * math.cos(d) + math.cos(la1) * math.sin(d) * math.cos(b));
  final lo2 = lo1 +
      math.atan2(math.sin(b) * math.sin(d) * math.cos(la1), math.cos(d) - math.sin(la1) * math.sin(la2));
  return LatLng(la2 * 180 / math.pi, lo2 * 180 / math.pi);
}

/// Pose bei [meters] (Vorderachse). [metersPerUnit]: Kartenmeter je
/// Fahrzeugmeter (1 = maßstabsgetreu).
ArticulatedPose articulate(
  TourPath path,
  double meters, {
  double metersPerUnit = 1,
  TruckDimensions dims = const TruckDimensions(),
}) {
  final total = path.totalMeters;
  final m = meters.clamp(0.0, total);
  final k = metersPerUnit;
  // Am Start fehlt Strecke hinter dem Fahrzeug: dann gerade nach hinten
  // verlängern (Richtung des ersten Stücks).
  LatLng behind(double d) {
    if (m - d >= 0) return path.at(m - d).point;
    final start = path.at(0).point;
    final dir = _bearing(path.at(math.min(total, 200)).point, start);
    return destination(start, d - m, dir);
  }

  final front = path.at(m).point;
  final rear = behind(dims.tractorWheelbase * k);
  final kingpin = behind(dims.kingpinBehindFront * k);
  final trailerAxle = behind((dims.kingpinBehindFront + dims.trailerWheelbase) * k);

  final tractorHeading = rear == front ? path.at(m).bearing : _bearing(rear, front);
  var trailerHeading = trailerAxle == kingpin ? tractorHeading : _bearing(trailerAxle, kingpin);
  // Begrenzen: nie stärker als maxKnick einknicken.
  var knick = (trailerHeading - tractorHeading) % 360;
  if (knick > 180) knick -= 360;
  if (knick.abs() > dims.maxKnick) {
    trailerHeading = (tractorHeading + knick.sign * dims.maxKnick + 360) % 360;
  }
  return ArticulatedPose(
    frontAxle: front,
    kingpin: kingpin,
    trailerAxle: trailerAxle,
    tractorHeading: tractorHeading,
    trailerHeading: trailerHeading,
  );
}

/// Kartenmeter je Bildschirmpunkt bei [zoom] und Breite [lat] (MapLibre,
/// 512er-Kacheln).
double metersPerScreenPoint(double zoom, double lat) =>
    78271.517 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

/// Lichtkegel der Zugmaschine: Ansatz [ahead] Fahrzeugmeter vor der
/// Vorderachse (Front der Kabine), Richtung AUSSCHLIESSLICH die der
/// Zugmaschine – nicht Kamera, nicht Auflieger.
({LatLng apex, double heading}) headlightPlacement(ArticulatedPose pose,
        {required double metersPerUnit, double ahead = 0.9}) =>
    (apex: destination(pose.frontAxle, ahead * metersPerUnit, pose.tractorHeading), heading: pose.tractorHeading);
