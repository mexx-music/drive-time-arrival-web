import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Small abstraction for map REST calls. In browsers direct calls to Google
/// REST endpoints are blocked by CORS and should be proxied via a backend.
/// This file centralizes the guard so callers can be migrated later.

bool mapsDirectCallsAllowed() => !kIsWeb;

const String webBlockedMessage = 'Web routing via direct Google REST request is blocked in browser';

// Optional proxy base for web builds. Provide via `--dart-define=MAPS_PROXY_BASE=https://...`
const String mapsProxyBase = String.fromEnvironment('MAPS_PROXY_BASE', defaultValue: '');
bool mapsProxyConfigured() => mapsProxyBase.isNotEmpty;

/// Debug helper - call this from a runtime location if you need to log the proxy config.
void _logMapsProxyConfig() {
  if (kDebugMode) {
    // ignore: avoid_print
    print('MAPS_PROXY_BASE="${mapsProxyBase}" configured=${mapsProxyConfigured()}');
  }
}

/// Public wrapper to log proxy config in debug builds.
void logMapsProxyConfig() => _logMapsProxyConfig();

String _proxyBaseNoSlash() => mapsProxyBase.replaceAll(RegExp(r'/+\u0000*\u0000*\u0000*\z'), '');

/// Proxy helper: POST /api/geocode with { address }
Future<Map<String, dynamic>> proxyGeocode(String address) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/') ? mapsProxyBase.substring(0, mapsProxyBase.length - 1) : mapsProxyBase;
  final uri = Uri.parse('$base/api/geocode');
  final res = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode({'address': address}));
  if (res.statusCode != 200) throw Exception('Proxy error HTTP ${res.statusCode}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// Proxy helper: POST /api/directions with { origin, destination, waypoints }
Future<Map<String, dynamic>> proxyDirections({
  required String origin,
  required String destination,
  List<String>? waypoints,
  String mode = 'driving',
  String departureTime = 'now',
}) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/') ? mapsProxyBase.substring(0, mapsProxyBase.length - 1) : mapsProxyBase;
  final uri = Uri.parse('$base/api/directions');
  final payload = {
    'origin': origin,
    'destination': destination,
    'waypoints': waypoints ?? [],
    'mode': mode,
    'departure_time': departureTime,
  };
  final res = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(payload));
  if (res.statusCode != 200) throw Exception('Proxy error HTTP ${res.statusCode}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}
