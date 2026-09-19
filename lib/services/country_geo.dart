import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Offline-Länderpolygone (vereinfachte Natural-Earth-Grenzen, ~1 km Auflösung).
///
/// Damit lässt sich ohne zusätzliche API-Kosten feststellen, welche Länder eine
/// Route durchquert. Das ist die Grundlage der automatischen Ländersperre:
/// Google liefert keine Länder-Information zu einer Route, also prüfen wir die
/// zurückgelieferte Polyline selbst gegen die Grenzen.
class CountryGeo {
  CountryGeo._();

  static const String assetPath = 'assets/geo/countries_eu.json';

  static Map<String, _Country>? _data;
  static Future<void>? _loading;

  /// Lädt die Grenzdaten einmalig. Mehrfachaufrufe teilen sich denselben Future.
  static Future<void> ensureLoaded() {
    if (_data != null) return Future.value();
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, _Country>{};
      json.forEach((iso, v) {
        final m = v as Map<String, dynamic>;
        final bbox = (m['bbox'] as List).map((e) => (e as num).toDouble()).toList();
        final polys = (m['polys'] as List)
            .map<List<_P>>((r) => (r as List)
                .map<_P>((c) => _P((c[0] as num).toDouble(), (c[1] as num).toDouble()))
                .toList(growable: false))
            .toList(growable: false);
        out[iso] = _Country(
          iso: iso,
          name: (m['name'] ?? iso).toString(),
          minLng: bbox[0],
          minLat: bbox[1],
          maxLng: bbox[2],
          maxLat: bbox[3],
          polys: polys,
        );
      });
      _data = out;
    } catch (e) {
      if (kDebugMode) debugPrint('[CountryGeo] Laden fehlgeschlagen: $e');
      _data = const {};
    }
  }

  static bool get isLoaded => _data != null;

  /// ISO-Code des Landes an dieser Position, oder null (z. B. offenes Meer).
  static String? countryAt(LatLng p) {
    final d = _data;
    if (d == null) return null;
    for (final c in d.values) {
      if (c.contains(p.longitude, p.latitude)) return c.iso;
    }
    return null;
  }

  /// Liegt der Punkt in einem der angegebenen Länder?
  static bool isInAny(LatLng p, Set<String> isoCodes) {
    final d = _data;
    if (d == null || isoCodes.isEmpty) return false;
    for (final iso in isoCodes) {
      final c = d[iso];
      if (c != null && c.contains(p.longitude, p.latitude)) return true;
    }
    return false;
  }

  /// Liegt der Punkt überhaupt auf (erfasstem) Land? Wird benutzt, um
  /// automatisch erzeugte Umfahrungspunkte im Meer auszusortieren.
  static bool isOnLand(LatLng p) => countryAt(p) != null;

  static String nameOf(String iso) => _data?[iso]?.name ?? iso;

  /// Wie viele Kilometer verläuft der Pfad in welchem Land?
  ///
  /// Der Pfad wird in ~[sampleKm]-Schritten abgetastet; jedes Teilstück wird dem
  /// Land seines Mittelpunkts zugeschlagen.
  static Map<String, double> kmPerCountry(List<LatLng> path, {double sampleKm = 2.0}) {
    final out = <String, double>{};
    if (path.length < 2) return out;
    for (var i = 0; i < path.length - 1; i++) {
      final a = path[i], b = path[i + 1];
      final segKm = distanceKm(a, b);
      if (segKm <= 0) continue;
      final parts = math.max(1, (segKm / sampleKm).ceil());
      final partKm = segKm / parts;
      for (var k = 0; k < parts; k++) {
        final t = (k + 0.5) / parts;
        final mid = LatLng(
          a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t,
        );
        final iso = countryAt(mid);
        if (iso == null) continue; // Fähre / Meer / nicht erfasstes Gebiet
        out[iso] = (out[iso] ?? 0) + partKm;
      }
    }
    return out;
  }

  /// Welche der gesperrten Länder werden wirklich durchfahren?
  ///
  /// [minKm] filtert Grenzverläufe heraus: Die vereinfachten Polygone sind auf
  /// ~1 km genau, eine grenznahe Autobahn darf kein Fehlalarm auslösen.
  static List<String> blockedCountriesOnPath(
    List<LatLng> path,
    Set<String> avoided, {
    double minKm = 4.0,
  }) {
    if (avoided.isEmpty) return const [];
    final km = kmPerCountry(path);
    final hits = avoided.where((iso) => (km[iso] ?? 0) >= minKm).toList();
    hits.sort((a, b) => (km[b] ?? 0).compareTo(km[a] ?? 0));
    return hits;
  }

  // --- Geometrie-Helfer (equirektangulare Näherung, für Europa ausreichend) ---

  static const double _earthKm = 6371.0088;

  static double distanceKm(LatLng a, LatLng b) {
    final latMid = (a.latitude + b.latitude) / 2 * math.pi / 180;
    final dx = (b.longitude - a.longitude) * math.pi / 180 * math.cos(latMid);
    final dy = (b.latitude - a.latitude) * math.pi / 180;
    return _earthKm * math.sqrt(dx * dx + dy * dy);
  }

  /// Verschiebt [p] um [km] in Richtung [bearingDeg] (0 = Nord, 90 = Ost).
  static LatLng offsetKm(LatLng p, double bearingDeg, double km) {
    final br = bearingDeg * math.pi / 180;
    final dLat = (km * math.cos(br)) / 111.32;
    final cosLat = math.cos(p.latitude * math.pi / 180).abs();
    final dLng = (km * math.sin(br)) / (111.32 * (cosLat < 0.05 ? 0.05 : cosLat));
    return LatLng(p.latitude + dLat, p.longitude + dLng);
  }

  /// Kurs von [a] nach [b] in Grad (0 = Nord).
  static double bearingDeg(LatLng a, LatLng b) {
    final latMid = (a.latitude + b.latitude) / 2 * math.pi / 180;
    final dx = (b.longitude - a.longitude) * math.cos(latMid);
    final dy = b.latitude - a.latitude;
    final deg = math.atan2(dx, dy) * 180 / math.pi;
    return (deg + 360) % 360;
  }
}

class _P {
  final double x; // lng
  final double y; // lat
  const _P(this.x, this.y);
}

class _Country {
  final String iso;
  final String name;
  final double minLng, minLat, maxLng, maxLat;
  final List<List<_P>> polys;

  const _Country({
    required this.iso,
    required this.name,
    required this.minLng,
    required this.minLat,
    required this.maxLng,
    required this.maxLat,
    required this.polys,
  });

  bool contains(double lng, double lat) {
    if (lng < minLng || lng > maxLng || lat < minLat || lat > maxLat) return false;
    for (final ring in polys) {
      if (_inRing(ring, lng, lat)) return true;
    }
    return false;
  }

  static bool _inRing(List<_P> ring, double x, double y) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].x, yi = ring[i].y;
      final xj = ring[j].x, yj = ring[j].y;
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}
