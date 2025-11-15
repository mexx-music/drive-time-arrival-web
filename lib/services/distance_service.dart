import 'dart:convert';
import 'package:http/http.dart' as http;

import '../secrets.dart';

/// Kleiner Service, der Straßenentfernungen via Google Directions API holt.
class DistanceService {
  const DistanceService();

  /// Gibt die Gesamtstrecke in Kilometern (1 Dezimalstelle) oder null bei Fehler.
  Future<double?> fetchKmDistance({
    required String origin,
    required String destination,
    List<String>? waypoints,
  }) async {
    if (GOOGLE_MAPS_API_KEY.isEmpty) return null;

    String wp = '';
    if (waypoints != null && waypoints.isNotEmpty) {
      final parts = waypoints.map((w) => Uri.encodeComponent(w)).join('|');
      wp = '&waypoints=$parts';
    }

    final params = [
          'origin=${Uri.encodeComponent(origin)}',
          'destination=${Uri.encodeComponent(destination)}',
          'mode=driving',
          'units=metric',
          'language=en',
          'departure_time=now',
          'alternatives=false',
          'key=$GOOGLE_MAPS_API_KEY',
        ].join('&') +
        wp;

    final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?$params');

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final status = (data['status'] ?? 'UNKNOWN').toString();
      if (status != 'OK') return null;

      final route = (data['routes'] as List).first as Map<String, dynamic>;
      final legs = (route['legs'] as List).cast<Map<String, dynamic>>();
      double meters = 0;
      for (final l in legs) {
        meters += (l['distance']['value'] as num).toDouble();
      }
      final km = meters / 1000.0;
      // runde auf 1 Dezimalstelle
      final rounded = (km * 10).round() / 10.0;
      return rounded;
    } catch (_) {
      return null;
    }
  }
}
