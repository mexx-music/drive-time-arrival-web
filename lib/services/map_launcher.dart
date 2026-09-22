// lib/services/map_launcher.dart
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../logic/ferry_auto.dart';
import '../ui/map_osm_view.dart';
import '../utils/polyline.dart' as poly;

// Re-Export: der Decoder liegt jetzt in utils/polyline.dart, damit ihn auch
// Modelle ohne Flutter-/UI-Abhängigkeit benutzen können.
List<LatLng> decodePolyline(String encoded) => poly.decodePolyline(encoded);

/// Open a map (OSM) for the given start/destination and optional waypoints.
///
/// Parameters mirror the original implementation in main.dart as closely as
/// possible. `addLog` can be used to append debug/log lines back into the
/// caller's state (it is invoked inside setState in the caller typically).
Future<void> openMapOsm(
  BuildContext context, {
  required String s,
  required String d,
  required List<String> stops,
  required List<LatLng?> stopCoords,
  required double? startLat,
  required double? startLng,
  required double? destLat,
  required double? destLng,
  required bool optimizeStops,
  required String googleMapsApiKey,
  required bool Function() mapsDirectCallsAllowed,
  required void Function(String) addLog,
  required bool Function() showDetails,
  required bool mounted,
  /// Zusatzhinweis für die Kartenkopfzeile, z. B. die geplante Fähre.
  String? routeNote,
}) async {
  // ignore: avoid_print
  print('[openMapOsm] start="$s" dest="$d"');

  if (s.isEmpty || d.isEmpty) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bitte Start & Ziel eingeben.')),
      );
    }
    return;
  }

  {
    // Immer die App-Karte verwenden – auch ohne Zwischenstopps.
    // ignore: avoid_print
    print('[openMapOsm] using in-app segmented map');
    final det = FerryAutoDetect(googleMapsApiKey);
    var points = <LatLng>[];
    // Abschnitte für die Kartenansicht: gefahrene Strecke, Fähre, Lücke.
    final segments = <MapSegment>[];
    final failedLegs = <String>[];
    final places = <String>[];
    places.add(s);
    places.addAll(stops);
    places.add(d);

    for (var i = 0; i < places.length - 1; i++) {
      final from = places[i];
      final to = places[i + 1];
      final segmentStart = points.length;
      var ferryLeg = false;
      // ignore: avoid_print
      print('[openMapOsm] segment ${i + 1}: $from -> $to');
      try {
        final res = await det.fetchDirections(origin: from, destination: to);
        if (!res.ok) {
          // ignore: avoid_print
          print(
              '[openMapOsm] segment directions failed: ${res.status} for $from->$to');
          failedLegs.add('$from → $to');
          continue;
        }
        ferryLeg = res.candidates.isNotEmpty
            ? det.candidateHasFerry(res.candidates.first)
            : det.routeHasFerry(res);
        final routeRaw = res.raw;

        // --- Diagnostics: inspect routeRaw and its structure (minimal, safe)
        try {
          // ignore: avoid_print
          print(
              '[openMapOsm] routeRaw keys: ${routeRaw is Map ? (routeRaw as Map).keys.toList() : routeRaw.runtimeType}');
          if (routeRaw is Map && routeRaw.containsKey('routes')) {
            final routes = routeRaw['routes'];
            // ignore: avoid_print
            print('[openMapOsm] routes type: ${routes.runtimeType}');
            if (routes is List && routes.isNotEmpty) {
              final r0 = routes.first;
              if (r0 is Map) {
                // ignore: avoid_print
                print('[openMapOsm] routes[0] keys: ${r0.keys.toList()}');
                final overview = (r0['overview_polyline'] is Map)
                    ? (r0['overview_polyline'] as Map)['points']
                    : null;
                // ignore: avoid_print
                print(
                    '[openMapOsm] overview_polyline exists: ${overview != null} (type=${overview?.runtimeType})');
                final legs = r0['legs'];
                // ignore: avoid_print
                print('[openMapOsm] legs type: ${legs.runtimeType}');
                if (legs is List && legs.isNotEmpty) {
                  // inspect first leg steps
                  final firstLeg = legs.first;
                  if (firstLeg is Map && firstLeg.containsKey('steps')) {
                    final steps = firstLeg['steps'];
                    // ignore: avoid_print
                    print(
                        '[openMapOsm] firstLeg.steps type: ${steps.runtimeType} length=${steps is List ? steps.length : 'n/a'}');
                    if (steps is List && steps.isNotEmpty) {
                      final sample = steps.take(3).map((st) {
                        if (st is Map) {
                          final poly = (st['polyline'] is Map)
                              ? (st['polyline'] as Map)['points']
                              : null;
                          return {
                            'polylineType': poly?.runtimeType.toString(),
                            'polylineLen': poly is String ? poly.length : 0
                          };
                        }
                        return {'polylineType': st.runtimeType.toString()};
                      }).toList();
                      // ignore: avoid_print
                      print('[openMapOsm] first 3 steps poly info: $sample');
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          // ignore diagnostics failure
          // ignore: avoid_print
          print('[openMapOsm] diagnostics failed: $e');
        }

        String? poly;
        try {
          final routes = routeRaw['routes'];
          if (routes is List && routes.isNotEmpty) {
            final first = routes.first as Map<String, dynamic>;
            final ov = first['overview_polyline'];
            if (ov is Map &&
                ov.containsKey('points') &&
                ov['points'] is String) {
              poly = ov['points'] as String;
            } else {
              poly = null;
            }
          }
        } catch (_) {
          poly = null;
        }

        // if overview poly exists and looks plausible, decode it
        if (poly != null && poly.isNotEmpty) {
          // debug
          try {
            final snippet = poly.length > 120 ? poly.substring(0, 120) : poly;
            // ignore: avoid_print
            print(
                '[openMapOsm] overview_polyline length=${poly.length} snippet=$snippet');
          } catch (_) {}

          final seg = decodePolyline(poly);
          final validSeg = seg
              .where((p) =>
                  p.latitude >= -90 &&
                  p.latitude <= 90 &&
                  p.longitude >= -180 &&
                  p.longitude <= 180)
              .toList();
          // ignore: avoid_print
          print(
              '[openMapOsm] overview_polyline decoded points=${seg.length} valid=${validSeg.length}');

          // If overview gives too few valid points, try safe step-concatenation as fallback
          if (validSeg.length < 8) {
            try {
              final legs = routeRaw['routes'] is List &&
                      (routeRaw['routes'] as List).isNotEmpty
                  ? (routeRaw['routes'] as List).first['legs']
                  : null;
              if (legs is List) {
                final stepPolys = <LatLng>[];
                for (final leg in legs) {
                  if (leg is Map &&
                      leg.containsKey('steps') &&
                      leg['steps'] is List) {
                    final steps = leg['steps'] as List;
                    for (final st in steps) {
                      if (st is Map) {
                        final sp = (st['polyline'] is Map)
                            ? (st['polyline'] as Map)['points']
                            : null;
                        if (sp is String && sp.isNotEmpty) {
                          try {
                            final pts = decodePolyline(sp);
                            stepPolys.addAll(pts);
                          } catch (_) {}
                        }
                      }
                    }
                  }
                }
                final validStepPolys = stepPolys
                    .where((p) =>
                        p.latitude >= -90 &&
                        p.latitude <= 90 &&
                        p.longitude >= -180 &&
                        p.longitude <= 180)
                    .toList();
                // ignore: avoid_print
                print(
                    '[openMapOsm] step-polylines concat valid=${validStepPolys.length}');
                if (validStepPolys.length > validSeg.length) {
                  // ignore: avoid_print
                  print(
                      '[openMapOsm] using step-polylines fallback, points=${validStepPolys.length}');
                  if (points.isNotEmpty) {
                    final first = validStepPolys.first;
                    final lastExisting = points.last;
                    if (!(lastExisting.latitude == first.latitude &&
                        lastExisting.longitude == first.longitude)) {
                      points.addAll(validStepPolys);
                    } else {
                      points.addAll(validStepPolys.skip(1));
                    }
                  } else {
                    points.addAll(validStepPolys);
                  }
                } else {
                  // use overview validSeg even if small
                  if (validSeg.isNotEmpty) {
                    if (points.isNotEmpty) {
                      final first = validSeg.first;
                      final lastExisting = points.last;
                      if (!(lastExisting.latitude == first.latitude &&
                          lastExisting.longitude == first.longitude)) {
                        points.addAll(validSeg);
                      } else {
                        points.addAll(validSeg.skip(1));
                      }
                    } else {
                      points.addAll(validSeg);
                    }
                  }
                }
              } else {
                // no legs -> just use whatever overview gave
                if (validSeg.isNotEmpty) {
                  if (points.isNotEmpty) {
                    final first = validSeg.first;
                    final lastExisting = points.last;
                    if (!(lastExisting.latitude == first.latitude &&
                        lastExisting.longitude == first.longitude)) {
                      points.addAll(validSeg);
                    } else {
                      points.addAll(validSeg.skip(1));
                    }
                  } else {
                    points.addAll(validSeg);
                  }
                }
              }
            } catch (e) {
              // ignore: avoid_print
              print('[openMapOsm] step-polylines fallback failed: $e');
              // fallback to using overview small set
              if (validSeg.isNotEmpty) {
                if (points.isNotEmpty) {
                  final first = validSeg.first;
                  final lastExisting = points.last;
                  if (!(lastExisting.latitude == first.latitude &&
                      lastExisting.longitude == first.longitude)) {
                    points.addAll(validSeg);
                  } else {
                    points.addAll(validSeg.skip(1));
                  }
                } else {
                  points.addAll(validSeg);
                }
              }
            }
          } else {
            // overview had enough points
            if (points.isNotEmpty) {
              final first = validSeg.first;
              final lastExisting = points.last;
              if (!(lastExisting.latitude == first.latitude &&
                  lastExisting.longitude == first.longitude)) {
                points.addAll(validSeg);
              } else {
                points.addAll(validSeg.skip(1));
              }
            } else {
              points.addAll(validSeg);
            }
          }
        } else {
          // overview poly absent -> try steps concatenation directly (safe)
          try {
            final routes = routeRaw['routes'];
            if (routes is List && routes.isNotEmpty) {
              final r0 = routes.first;
              final legs =
                  (r0 is Map && r0.containsKey('legs')) ? r0['legs'] : null;
              if (legs is List) {
                final stepPolys = <LatLng>[];
                for (final leg in legs) {
                  if (leg is Map &&
                      leg.containsKey('steps') &&
                      leg['steps'] is List) {
                    final steps = leg['steps'] as List;
                    for (final st in steps) {
                      if (st is Map) {
                        final sp = (st['polyline'] is Map)
                            ? (st['polyline'] as Map)['points']
                            : null;
                        if (sp is String && sp.isNotEmpty) {
                          try {
                            final pts = decodePolyline(sp);
                            stepPolys.addAll(pts);
                          } catch (_) {}
                        }
                      }
                    }
                  }
                }
                final validStepPolys = stepPolys
                    .where((p) =>
                        p.latitude >= -90 &&
                        p.latitude <= 90 &&
                        p.longitude >= -180 &&
                        p.longitude <= 180)
                    .toList();
                // ignore: avoid_print
                print(
                    '[openMapOsm] steps concat valid=${validStepPolys.length}');
                if (validStepPolys.isNotEmpty) {
                  if (points.isNotEmpty) {
                    final first = validStepPolys.first;
                    final lastExisting = points.last;
                    if (!(lastExisting.latitude == first.latitude &&
                        lastExisting.longitude == first.longitude)) {
                      points.addAll(validStepPolys);
                    } else {
                      points.addAll(validStepPolys.skip(1));
                    }
                  } else {
                    points.addAll(validStepPolys);
                  }
                }
              }
            }
          } catch (e) {
            // ignore: avoid_print
            print('[openMapOsm] steps concat failed: $e');
          }
        }
      } catch (e) {
        // ignore segment failure, continue
        // ignore: avoid_print
        print('[openMapOsm] segment exception for $from->$to: $e');
        failedLegs.add('$from → $to');
        continue;
      }

      if (points.length > segmentStart) {
        segments.add(MapSegment(
          points: points.sublist(segmentStart),
          label: '$from → $to',
          isFerry: ferryLeg,
        ));
      } else {
        failedLegs.add('$from → $to');
      }
    }

    // Filter combined points defensively
    final combinedValid = points
        .where((p) =>
            p.latitude >= -90 &&
            p.latitude <= 90 &&
            p.longitude >= -180 &&
            p.longitude <= 180)
        .toList();
    // ignore: avoid_print
    print('[openMapOsm] final valid combined points: ${combinedValid.length}');
    if (failedLegs.isNotEmpty) {
      addLog('🗺️ Karte: keine Streckenführung für ${failedLegs.join(', ')} '
          '– als Lücke eingezeichnet.');
    }

    // Auch mit Teilstrecken zeigen, solange Start und Ziel bekannt sind.
    final fallbackStart = (startLat != null && startLng != null)
        ? LatLng(startLat, startLng)
        : (combinedValid.isNotEmpty ? combinedValid.first : null);
    final fallbackDest = (destLat != null && destLng != null)
        ? LatLng(destLat, destLng)
        : (combinedValid.isNotEmpty ? combinedValid.last : null);

    if (fallbackStart == null || fallbackDest == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Karte: Keine gültigen Routensegmente.')));
      }
      return;
    }

    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MapOsmView(
            start: fallbackStart,
            dest: fallbackDest,
            route: combinedValid,
            segments: segments,
            stops: [for (final c in stopCoords) if (c != null) c],
            subtitle: [
              failedLegs.isEmpty
                  ? '${segments.length} Abschnitt(e)'
                  : '${segments.length} Abschnitt(e), '
                      '${failedLegs.length} ohne Streckenführung',
              if (routeNote != null && routeNote.isNotEmpty) routeNote,
            ].join(' · '),
          ),
        ),
      );
    }
    return;
  }
}

