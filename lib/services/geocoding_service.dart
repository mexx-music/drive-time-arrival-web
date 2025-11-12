import 'dart:convert';
import 'package:http/http.dart' as http;
import '../secrets.dart';

class GeocodingResult {
  final double lat;
  final double lng;
  final String description;
  GeocodingResult(this.lat, this.lng, this.description);
}

class GeocodingService {
  /// Resolve freeform address/place text to lat/lng using Google Geocoding API.
  /// Throws an Exception on error.
  static Future<GeocodingResult> resolve(String input) async {
    if (GOOGLE_MAPS_API_KEY.isEmpty ||
        GOOGLE_MAPS_API_KEY == 'DEIN_API_KEY_HIER') {
      throw Exception('No Google Maps API key configured');
    }
    final uri = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?address=${Uri.encodeComponent(input)}&key=$GOOGLE_MAPS_API_KEY',
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['status'] != 'OK')
      throw Exception('Geocoding status ${data['status']}');
    final results = (data['results'] as List).cast<Map<String, dynamic>>();
    if (results.isEmpty) throw Exception('No results');
    final first = results.first;
    final geom = first['geometry'] as Map<String, dynamic>?;
    final loc = geom?['location'] as Map<String, dynamic>?;
    if (loc == null) throw Exception('No location in response');
    final lat = (loc['lat'] as num).toDouble();
    final lng = (loc['lng'] as num).toDouble();
    final formatted = (first['formatted_address'] ?? input) as String;
    return GeocodingResult(lat, lng, formatted);
  }
}
