import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../logic/eta_calculator.dart';
import '../models/ferry_route.dart';
import '../services/distance_service.dart';
import '../services/maps_proxy.dart';

class DirectionsFetchResult {
  final bool ok;
  final String status;
  final double km;
  final double sec;
  final List<Map<String, dynamic>> steps;
  final List<String> warnings;
  final Map<String, dynamic> raw;

  DirectionsFetchResult({
    required this.ok,
    required this.status,
    required this.km,
    required this.sec,
    required this.steps,
    required this.warnings,
    required this.raw,
  });

  static DirectionsFetchResult error(String status) => DirectionsFetchResult(
        ok: false,
        status: status,
        km: 0,
        sec: 0,
        steps: const [],
        warnings: const [],
        raw: const {},
      );
}

class FerryAutoDetect {
  final String apiKey;
  FerryAutoDetect(this.apiKey);

  Future<DirectionsFetchResult> fetchDirections({
    required String origin,
    required String destination,
    List<String> waypoints = const [],
    bool optimize = false,
    bool avoidFerries = false,
  }) async {
    // In browsers, direct calls to Google Directions REST endpoints are blocked by CORS.
    // Surface a clear error and avoid making the request; future work should proxy these requests via a backend.
    if (!mapsDirectCallsAllowed()) {
      if (mapsProxyConfigured()) {
        try {
          final data = await proxyDirections(origin: origin, destination: destination, waypoints: waypoints, mode: 'driving', departureTime: 'now');
          final status = (data['status'] ?? 'UNKNOWN').toString();
          if (status != 'OK') {
            if (kDebugMode) {
              print('[FerryAutoDetect] Proxy Directions status: $status');
              if (data.containsKey('error_message')) print('[FerryAutoDetect] proxy error_message: ${data['error_message']}');
            }
            return DirectionsFetchResult(
              ok: false,
              status: status,
              km: 0,
              sec: 0,
              steps: const [],
              warnings: _extractWarnings(data),
              raw: data,
            );
          }
          final route = (data['routes'] as List).first as Map<String, dynamic>;
          final legs = (route['legs'] as List).cast<Map<String, dynamic>>();

          double meters = 0;
          double seconds = 0;
          final List<Map<String, dynamic>> steps = [];
          for (final l in legs) {
            meters += (l['distance']['value'] as num).toDouble();
            seconds += (l['duration']['value'] as num).toDouble();
            final s = (l['steps'] as List).cast<Map<String, dynamic>>();
            steps.addAll(s);
          }
          final warnings = _extractWarnings(data);
          return DirectionsFetchResult(
            ok: true,
            status: status,
            km: meters / 1000.0,
            sec: seconds,
            steps: steps,
            warnings: warnings,
            raw: data,
          );
        } catch (e, st) {
          if (kDebugMode) {
            print('[FerryAutoDetect] Proxy exception: $e');
            print(st.toString());
          }
          return DirectionsFetchResult.error('PROXY_ERROR');
        }
      }

      return DirectionsFetchResult(
        ok: false,
        status: 'WEB_BLOCKED',
        km: 0,
        sec: 0,
        steps: const [],
        warnings: const [],
        raw: {'error_message': webBlockedMessage},
      );
    }

    if (apiKey.isEmpty) return DirectionsFetchResult.error('NO_KEY');

    String wp = '';
    if (waypoints.isNotEmpty) {
      final parts = waypoints.map((w) => Uri.encodeComponent(w)).join('|');
      final head = optimize ? 'optimize:true|' : '';
      wp = '&waypoints=$head$parts';
    }

    final params = [
          'origin=${Uri.encodeComponent(origin)}',
          'destination=${Uri.encodeComponent(destination)}',
          'mode=driving',
          'units=metric',
          'language=en', // stabil fürs Parsing
          'alternatives=false',
          'departure_time=now',
          if (avoidFerries) 'avoid=ferries',
          'key=$apiKey',
        ].join('&') +
        wp;

    final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?$params');

    // debug
    // ignore: avoid_print
    // print('[FerryAutoDetect] GET $uri');
    // print masked URL (do not print API key)
    // ignore: avoid_print
    print('[FerryAutoDetect] GET ${uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***')}');

    final res = await http.get(uri);

    // log HTTP problems to help diagnose API key restrictions on Android
    if (res.statusCode != 200) {
      // ignore: avoid_print
      print('[FerryAutoDetect] HTTP ${res.statusCode} for ${uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***')}');
      // ignore: avoid_print
      print('[FerryAutoDetect] Response body: ${res.body}');
      return DirectionsFetchResult.error('HTTP_${res.statusCode}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final status = (data['status'] ?? 'UNKNOWN').toString();

    // log non-OK status
    if (status != 'OK') {
      // ignore: avoid_print
      print('[FerryAutoDetect] Directions status: $status for ${uri.toString().replaceAll(RegExp(r'key=[^&]+'), 'key=***')}');
      // ignore: avoid_print
      print('[FerryAutoDetect] Response body: ${res.body}');
      if (data.containsKey('error_message')) {
        // ignore: avoid_print
        print('[FerryAutoDetect] error_message: ${data['error_message']}');
      }
      return DirectionsFetchResult(
        ok: false,
        status: status,
        km: 0,
        sec: 0,
        steps: const [],
        warnings: _extractWarnings(data),
        raw: data,
      );
    }

    final route = (data['routes'] as List).first as Map<String, dynamic>;
    final legs = (route['legs'] as List).cast<Map<String, dynamic>>();

    double meters = 0;
    double seconds = 0;
    final List<Map<String, dynamic>> steps = [];
    for (final l in legs) {
      meters += (l['distance']['value'] as num).toDouble();
      seconds += (l['duration']['value'] as num).toDouble();
      final s = (l['steps'] as List).cast<Map<String, dynamic>>();
      steps.addAll(s);
    }

    final warnings = _extractWarnings(data);
    return DirectionsFetchResult(
      ok: true,
      status: status,
      km: meters / 1000.0,
      sec: seconds,
      steps: steps,
      warnings: warnings,
      raw: data,
    );
  }

  static List<String> _extractWarnings(Map<String, dynamic> data) {
    try {
      final routes = (data['routes'] as List);
      if (routes.isEmpty) return const [];
      final w = (routes.first as Map<String, dynamic>)['warnings'];
      if (w is List) return w.map((e) => e.toString()).toList();
      return const [];
    } catch (_) {
      return const [];
    }
  }

  // Warnings + Steps prüfen
  bool routeHasFerry(DirectionsFetchResult r) {
    if (r.warnings.any((w) => w.toLowerCase().contains('ferry'))) return true;
    for (final st in r.steps) {
      final instr =
          _stripHtml((st['html_instructions'] ?? '').toString()).toLowerCase();
      final man = (st['maneuver'] ?? '').toString().toLowerCase();
      if (instr.contains('ferry') ||
          instr.contains('car ferry') ||
          man.contains('ferry')) return true;
    }
    return false;
  }

  static String _stripHtml(String s) => s
      .replaceAll(RegExp('<[^>]+>'), ' ')
      .replaceAll(RegExp('\\s+'), ' ')
      .trim();
}

extension FerryAutoEta on FerryAutoDetect {
  // === ETA-Berechnung (mit/ohne Fähre) – Wrapper in ferry_auto ===
  Future<EtaResult> computeEtaWithOptionalFerry({
    required DateTime startTime,
    required int alreadyDrivenMin,
    required int dutyOffsetMin,
    required double avgKmh,
    required DriveRulesConfig rules,
    required String startAddress,
    required String endAddress,
    FerryRoute? autoOrManualFerry,
    DateTime? manualDeparture,
    // Optional context-sensitive guard callbacks. If provided, use these instead of a global guard.
    bool Function()? ferryPlannedGet,
    void Function(bool)? ferryPlannedSet,
  }) async {
    // If another computation already planned a ferry during this UI flow, avoid re-planning.
    final bool alreadyPlanned =
        ferryPlannedGet != null ? ferryPlannedGet() : false;
    if (alreadyPlanned) {
      final km = await _distanceSingle(
              origin: startAddress, destination: endAddress) ??
          0.0;
      final single = EtaCalculator.compute(
        start: startTime,
        alreadyDrivenMin: alreadyDrivenMin,
        dutyTimeOffsetMin: dutyOffsetMin,
        km: km,
        avgKmh: avgKmh,
        rules: rules,
      );
      return EtaResult([
        EtaStep(
            '⚠️ Doppel-Trigger erkannt – Fähre wurde bereits geplant; Fallback auf Ein-Segment.'),
        ...single.steps
      ], single.arrival);
    }

    // If no ferry is requested, do the normal single-segment computation (do NOT set the guard)
    if (autoOrManualFerry == null) {
      return EtaCalculator.compute(
        start: startTime,
        alreadyDrivenMin: alreadyDrivenMin,
        dutyTimeOffsetMin: dutyOffsetMin,
        km: await _approxKm(startAddress, endAddress) ?? 0.0,
        avgKmh: avgKmh,
        rules: rules,
      );
    }

    // We are about to plan a ferry in this run; set context guard (if provided) and ensure reset in finally.
    ferryPlannedSet?.call(true);
    try {
      // Distanz-Logs (only these belong to wrapper)
      final distLogs = <EtaStep>[];
      final dist = const DistanceService();
      final fromPort = autoOrManualFerry.from;
      final toPort = autoOrManualFerry.to;

      // kmBefore: Start -> fromPort
      double kmBefore = await dist.fetchKmDistance(
              origin: startAddress, destination: fromPort) ??
          0.0;
      if (kmBefore == 0.0) {
        kmBefore = await _approxKm(startAddress, fromPort) ?? 0.0;
      }
      distLogs.add(
          EtaStep('📍 Distanz ${startAddress} → ${fromPort}: ${kmBefore} km'));

      // kmAfter: toPort -> Ziel (Retry and fallback for Sindos)
      String effectiveEnd = endAddress;
      double? kmAfter =
          await dist.fetchKmDistance(origin: toPort, destination: endAddress);
      if (kmAfter == null || kmAfter == 0) {
        if (endAddress.toLowerCase().contains('sindos')) {
          effectiveEnd = 'Sindos, Thessaloniki, Greece';
          kmAfter = await dist.fetchKmDistance(
              origin: toPort, destination: effectiveEnd);
        }
      }
      if (kmAfter == null || kmAfter == 0) {
        kmAfter = 500.0; // conservative fallback estimate
        distLogs.add(EtaStep(
            '⚠️ Distanz ${toPort} → ${effectiveEnd} geschätzt (${kmAfter} km)'));
      } else {
        distLogs.add(
            EtaStep('📍 Distanz ${toPort} → ${effectiveEnd}: ${kmAfter} km'));
      }

      // Build ferry label and call the internal two-leg calculator exactly once
      final operatorName = (autoOrManualFerry.operators.isNotEmpty)
          ? autoOrManualFerry.operators.first
          : '';
      final ferryLabel =
          '${autoOrManualFerry.from}–${autoOrManualFerry.to} (${operatorName})';

      final result = EtaCalculator.computeTwoLegsWithFerry(
        start: startTime,
        alreadyDrivenMin: alreadyDrivenMin,
        dutyTimeOffsetMin: dutyOffsetMin,
        kmBefore: kmBefore,
        kmAfter: kmAfter!,
        avgKmh: avgKmh,
        rules: rules,
        ferryLabel: ferryLabel,
        ferryDurationMin: (autoOrManualFerry.durationHours * 60).round(),
        departuresHHmm: autoOrManualFerry.departuresLocal,
        manualDeparture: manualDeparture,
      );

      // Combine dist logs + result steps
      final steps = <EtaStep>[];
      steps.addAll(distLogs);
      steps.addAll(result.steps);

      // Sanity filter: if multiple ferry entries still appear, remove any wrapper ferry/hafen/pause logs to avoid duplication
      final ferryCount =
          steps.where((s) => s.text.toLowerCase().contains('fähre ')).length;
      if (ferryCount > 1) {
        final filtered = steps.where((s) {
          final low = s.text.toLowerCase();
          if (low.contains('ankunft hafen')) return false;
          if (low.contains('wartezeit bis fähre')) return false;
          if (low.contains('fähre ')) return false;
          if (low.contains('pause während der fähre')) return false;
          return true;
        }).toList();
        final out = <EtaStep>[];
        out.addAll(filtered.where((s) =>
            s.text.startsWith('📍') ||
            s.text.startsWith('⚠️') ||
            s.text.startsWith('🔎')));
        out.addAll(result.steps);
        return EtaResult(out, result.arrival);
      }

      return EtaResult(steps, result.arrival);
    } finally {
      // reset context guard for next UI computation
      ferryPlannedSet?.call(false);
    }
  }

  // Kleine Hilfsfunktion: wenn Directions nicht verfügbar, schätze Strecke aus Namen (0.0 fallback)
  Future<double?> _approxKm(String origin, String destination) async {
    const d = DistanceService();
    return await d.fetchKmDistance(origin: origin, destination: destination);
  }

  // helper to obtain a single-segment distance via DistanceService
  Future<double?> _distanceSingle(
      {required String origin, required String destination}) async {
    const d = DistanceService();
    return await d.fetchKmDistance(origin: origin, destination: destination);
  }
}
