import 'package:latlong2/latlong.dart';

import '../models/ferry_route.dart';
import '../models/route_candidate.dart';
import 'ferry_auto.dart';

/// Die beiden Landstrecken um eine Fähre herum.
///
/// Bisher wurde für eine Fährtour nur eine Gesamtdistanz geführt. Damit fehlte
/// der Karte die Geometrie der tatsächlich geplanten Route – sie fragte Google
/// erneut von Start nach Ziel und zeichnete dann Googles eigene, kürzeste
/// Fähre statt der geplanten.
///
/// Hier werden beide Landwege getrennt abgerufen, jeweils **ohne** Fähre:
/// sonst schmuggelt Google in die Anfahrt eine eigene Überfahrt.
class FerryLegPlan {
  final FerryRoute ferry;

  /// Start → Abfahrtshafen.
  final RouteCandidate legA;

  /// Ankunftshafen → Ziel.
  final RouteCandidate legB;

  const FerryLegPlan({
    required this.ferry,
    required this.legA,
    required this.legB,
  });

  /// Reine Straßenkilometer, ohne die Seestrecke.
  double get roadKm => legA.km + legB.km;

  /// Alle Etappen beider Landwege – Grundlage der LKW-Fahrzeit.
  List<Map<String, dynamic>> get steps => [...legA.steps, ...legB.steps];

  /// Abfahrtshafen = Ende des ersten Landwegs.
  /// Eigene Hafenkoordinaten braucht es nicht, Google geocodiert die
  /// Hafennamen selbst.
  LatLng? get portFrom =>
      legA.points.isEmpty ? null : legA.points.last;

  /// Ankunftshafen = Anfang des zweiten Landwegs.
  LatLng? get portTo => legB.points.isEmpty ? null : legB.points.first;

  static Future<FerryLegPlan?> plan({
    required String origin,
    required String destination,
    required FerryRoute ferry,
    required FerryAutoDetect det,
  }) async {
    final a = await det.fetchDirections(
      origin: origin,
      destination: ferry.from,
      avoidFerries: true,
    );
    final b = await det.fetchDirections(
      origin: ferry.to,
      destination: destination,
      avoidFerries: true,
    );
    if (!a.ok || !b.ok || a.candidates.isEmpty || b.candidates.isEmpty) {
      return null;
    }
    return FerryLegPlan(
      ferry: ferry,
      legA: a.candidates.first,
      legB: b.candidates.first,
    );
  }
}
