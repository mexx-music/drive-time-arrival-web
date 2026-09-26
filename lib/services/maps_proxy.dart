import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'catlab_trace.dart';

/// Small abstraction for map REST calls. In browsers direct calls to Google
/// REST endpoints are blocked by CORS and should be proxied via a backend.
/// This file centralizes the guard so callers can be migrated later.

bool mapsDirectCallsAllowed() => debugMapsDirectCallsAllowed ?? !kIsWeb;

/// Nur für Tests: erzwingt den Web-Weg über den Proxy auch in der VM, damit
/// Tests die tatsächlichen Proxy-Aufrufe zählen können.
@visibleForTesting
bool? debugMapsDirectCallsAllowed;
@visibleForTesting
String? debugMapsProxyBase;
@visibleForTesting
http.Client? debugMapsProxyClient;

const String webBlockedMessage =
    'Web routing via direct Google REST request is blocked in browser';

// Optional proxy base for web builds. Provide via `--dart-define=MAPS_PROXY_BASE=https://...`
const String _mapsProxyBaseDefine =
    String.fromEnvironment('MAPS_PROXY_BASE', defaultValue: '');
String get mapsProxyBase => debugMapsProxyBase ?? _mapsProxyBaseDefine;
bool mapsProxyConfigured() => mapsProxyBase.isNotEmpty;

Future<http.Response> _post(Uri uri, String body) {
  const headers = {'Content-Type': 'application/json'};
  final client = debugMapsProxyClient;
  return client != null
      ? client.post(uri, headers: headers, body: body)
      : http.post(uri, headers: headers, body: body);
}

/// Obergrenze für eine einzelne Proxy-Anfrage. Ohne Timeout bleibt ein
/// hängender Request für immer offen und die App zeigt endlos
/// "Route wird berechnet". Großzügig gewählt, weil der Proxy nach Leerlauf
/// erst hochfahren muss.
const Duration proxyRequestTimeout = Duration(seconds: 45);

/// Debug helper - call this from a runtime location if you need to log the proxy config.
void _logMapsProxyConfig() {
  if (kDebugMode) {
    // ignore: avoid_print
    print(
        'MAPS_PROXY_BASE="${mapsProxyBase}" configured=${mapsProxyConfigured()}');
  }
}

/// Public wrapper to log proxy config in debug builds.
void logMapsProxyConfig() => _logMapsProxyConfig();

String _proxyBaseNoSlash() =>
    mapsProxyBase.replaceAll(RegExp(r'/+\u0000*\u0000*\u0000*\z'), '');

/// Proxy helper: POST /api/geocode with { address }
Future<Map<String, dynamic>> proxyGeocode(String address) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/geocode');
  final res = await _post(
          uri, jsonEncode({'address': address, ...CatLabTrace.requestFields}))
      .timeout(proxyRequestTimeout);
  if (res.statusCode != 200)
    throw Exception('Proxy error HTTP ${res.statusCode}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> proxyReverseGeocode(
  double latitude,
  double longitude,
) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/geocode');
  final res = await _post(
    uri,
    jsonEncode(
      {'lat': latitude, 'lng': longitude, ...CatLabTrace.requestFields},
    ),
  ).timeout(proxyRequestTimeout);
  if (res.statusCode != 200) {
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> proxyAutocomplete({
  required String input,
  required String sessionToken,
  String language = 'de',
  double? latitude,
  double? longitude,
  int? radiusMeters,
}) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/autocomplete');
  final res = await _post(
    uri,
    jsonEncode({
      'input': input,
      'sessiontoken': sessionToken,
      'language': language,
      if (latitude != null && longitude != null)
        'location': '$latitude,$longitude',
      if (radiusMeters != null) 'radius': radiusMeters,
      ...CatLabTrace.requestFields,
    }),
  ).timeout(proxyRequestTimeout);
  if (res.statusCode != 200) {
    throw Exception('Proxy error HTTP ${res.statusCode}');
  }
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// Proxy helper: POST /api/directions with { origin, destination, waypoints }
Future<Map<String, dynamic>> proxyDirections({
  required String origin,
  required String destination,
  List<String>? waypoints,
  String mode = 'driving',
  String departureTime = 'now',
  bool optimize = false,
  bool avoidFerries = false,
  bool alternatives = false,
}) async {
  if (!mapsProxyConfigured()) throw Exception(webBlockedMessage);
  final base = mapsProxyBase.endsWith('/')
      ? mapsProxyBase.substring(0, mapsProxyBase.length - 1)
      : mapsProxyBase;
  final uri = Uri.parse('$base/api/directions');
  final payload = {
    'origin': origin,
    'destination': destination,
    'waypoints': waypoints ?? [],
    'mode': mode,
    'departure_time': departureTime,
    'optimize': optimize,
    'alternatives': alternatives,
    if (avoidFerries) 'avoid': 'ferries',
    // Nur die Kennung der laufenden Berechnung, damit der Proxy die Aufrufe
    // zusammenfassen kann. Der Proxy ignoriert die Felder fuer Google.
    ...CatLabTrace.requestFields,
  };
  final res =
      await _post(uri, jsonEncode(payload)).timeout(proxyRequestTimeout);
  if (res.statusCode != 200)
    throw Exception('Proxy error HTTP ${res.statusCode}');
  return jsonDecode(res.body) as Map<String, dynamic>;
}
