// lib/services/map_launcher.dart
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../logic/ferry_auto.dart';
import '../ui/map_osm_view.dart';
import '../utils/open_in_tab.dart';

// Standard Google polyline decode with factor 1e5
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  int index = 0;
  int lat = 0;
  int lng = 0;
  final len = encoded.length;
  while (index < len) {
    int b;
    int shift = 0;
    int result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
    lng += dlng;

    points.add(LatLng(lat / 1e5, lng / 1e5));
  }

  // debug: basic info
  try {
    // ignore: avoid_print
    print('[decodePolyline] encoded.length=${encoded.length}, points=${points.length}');
    final first5 = points.take(5).map((p) => '${p.latitude},${p.longitude}').toList();
    // ignore: avoid_print
    print('[decodePolyline] first5: $first5');
  } catch (_) {}

  return points;
}

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

  if (stops.isNotEmpty) {
    // ignore: avoid_print
    print('[openMapOsm] waypoint route detected, using in-app segmented map');
    final det = FerryAutoDetect(googleMapsApiKey);
    var points = <LatLng>[];
    final places = <String>[];
    places.add(s);
    places.addAll(stops);
    places.add(d);

    for (var i = 0; i < places.length - 1; i++) {
      final from = places[i];
      final to = places[i + 1];
      // ignore: avoid_print
      print('[openMapOsm] segment ${i + 1}: $from -> $to');
      try {
        final res = await det.fetchDirections(origin: from, destination: to);
        if (!res.ok) {
          // ignore: avoid_print
          print('[openMapOsm] segment directions failed: ${res.status} for $from->$to');
          continue;
        }
        final routeRaw = res.raw;

        // --- Diagnostics: inspect routeRaw and its structure (minimal, safe)
        try {
          // ignore: avoid_print
          print('[openMapOsm] routeRaw keys: ${routeRaw is Map ? (routeRaw as Map).keys.toList() : routeRaw.runtimeType}');
          if (routeRaw is Map && routeRaw.containsKey('routes')) {
            final routes = routeRaw['routes'];
            // ignore: avoid_print
            print('[openMapOsm] routes type: ${routes.runtimeType}');
            if (routes is List && routes.isNotEmpty) {
              final r0 = routes.first;
              if (r0 is Map) {
                // ignore: avoid_print
                print('[openMapOsm] routes[0] keys: ${r0.keys.toList()}');
                final overview = (r0['overview_polyline'] is Map) ? (r0['overview_polyline'] as Map)['points'] : null;
                // ignore: avoid_print
                print('[openMapOsm] overview_polyline exists: ${overview != null} (type=${overview?.runtimeType})');
                final legs = r0['legs'];
                // ignore: avoid_print
                print('[openMapOsm] legs type: ${legs.runtimeType}');
                if (legs is List && legs.isNotEmpty) {
                  // inspect first leg steps
                  final firstLeg = legs.first;
                  if (firstLeg is Map && firstLeg.containsKey('steps')) {
                    final steps = firstLeg['steps'];
                    // ignore: avoid_print
                    print('[openMapOsm] firstLeg.steps type: ${steps.runtimeType} length=${steps is List ? steps.length : 'n/a'}');
                    if (steps is List && steps.isNotEmpty) {
                      final sample = steps.take(3).map((st) {
                        if (st is Map) {
                          final poly = (st['polyline'] is Map) ? (st['polyline'] as Map)['points'] : null;
                          return {'polylineType': poly?.runtimeType.toString(), 'polylineLen': poly is String ? poly.length : 0};
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
            if (ov is Map && ov.containsKey('points') && ov['points'] is String) {
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
            print('[openMapOsm] overview_polyline length=${poly.length} snippet=$snippet');
          } catch (_) {}

          final seg = decodePolyline(poly);
          final validSeg = seg.where((p) => p.latitude >= -90 && p.latitude <= 90 && p.longitude >= -180 && p.longitude <= 180).toList();
          // ignore: avoid_print
          print('[openMapOsm] overview_polyline decoded points=${seg.length} valid=${validSeg.length}');

          // If overview gives too few valid points, try safe step-concatenation as fallback
          if (validSeg.length < 8) {
            try {
              final legs = routeRaw['routes'] is List && (routeRaw['routes'] as List).isNotEmpty
                  ? (routeRaw['routes'] as List).first['legs']
                  : null;
              if (legs is List) {
                final stepPolys = <LatLng>[];
                for (final leg in legs) {
                  if (leg is Map && leg.containsKey('steps') && leg['steps'] is List) {
                    final steps = leg['steps'] as List;
                    for (final st in steps) {
                      if (st is Map) {
                        final sp = (st['polyline'] is Map) ? (st['polyline'] as Map)['points'] : null;
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
                final validStepPolys = stepPolys.where((p) => p.latitude >= -90 && p.latitude <= 90 && p.longitude >= -180 && p.longitude <= 180).toList();
                // ignore: avoid_print
                print('[openMapOsm] step-polylines concat valid=${validStepPolys.length}');
                if (validStepPolys.length > validSeg.length) {
                  // ignore: avoid_print
                  print('[openMapOsm] using step-polylines fallback, points=${validStepPolys.length}');
                  if (points.isNotEmpty) {
                    final first = validStepPolys.first;
                    final lastExisting = points.last;
                    if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
                      if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
                    if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
                  if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
              if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
              final legs = (r0 is Map && r0.containsKey('legs')) ? r0['legs'] : null;
              if (legs is List) {
                final stepPolys = <LatLng>[];
                for (final leg in legs) {
                  if (leg is Map && leg.containsKey('steps') && leg['steps'] is List) {
                    final steps = leg['steps'] as List;
                    for (final st in steps) {
                      if (st is Map) {
                        final sp = (st['polyline'] is Map) ? (st['polyline'] as Map)['points'] : null;
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
                final validStepPolys = stepPolys.where((p) => p.latitude >= -90 && p.latitude <= 90 && p.longitude >= -180 && p.longitude <= 180).toList();
                // ignore: avoid_print
                print('[openMapOsm] steps concat valid=${validStepPolys.length}');
                if (validStepPolys.isNotEmpty) {
                  if (points.isNotEmpty) {
                    final first = validStepPolys.first;
                    final lastExisting = points.last;
                    if (!(lastExisting.latitude == first.latitude && lastExisting.longitude == first.longitude)) {
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
        continue;
      }
    }

    // Filter combined points defensively
    final combinedValid = points.where((p) => p.latitude >= -90 && p.latitude <= 90 && p.longitude >= -180 && p.longitude <= 180).toList();
    // ignore: avoid_print
    print('[openMapOsm] final valid combined points: ${combinedValid.length}');
    if (combinedValid.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Karte: Keine gültigen Routensegmente.')));
      return;
    }

    final startLatLng = combinedValid.first;
    final destLatLng = combinedValid.last;
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MapOsmView(start: startLatLng, dest: destLatLng, route: combinedValid),
        ),
      );
    }
    return;
  }

  String wp = '';
  if (stops.isNotEmpty) {
    final parts = stops.map((w) => Uri.encodeComponent(w)).join('|');
    final head = optimizeStops ? 'optimize:true|' : '';
    wp = '&waypoints=$head$parts';
  }

  final uri = Uri.parse(
    'https://maps.googleapis.com/maps/api/directions/json'
    '?origin=${Uri.encodeComponent(s)}'
    '&destination=${Uri.encodeComponent(d)}'
    '&mode=driving&units=metric&language=en'
    '&key=$googleMapsApiKey$wp',
  );

  if (!mapsDirectCallsAllowed()) {
    addLog('⚠️ Web routing via direct Google REST request is blocked in browser');
    // ignore: avoid_print
    print('[openMapOsm] waypoints=$stops');

    if (startLat != null && startLng != null && destLat != null && destLng != null) {
      // ignore: avoid_print
      print('[openMapOsm] using coordinate route for web fallback');
      final coordParts = <String>[];
      coordParts.add('${startLat},${startLng}');
      if (stopCoords.isNotEmpty) {
        for (final c in stopCoords) {
          if (c == null) continue;
          coordParts.add('${c.latitude},${c.longitude}');
        }
      }
      coordParts.add('${destLat},${destLng}');
      final mapUrl = 'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route=' + coordParts.join(';');
      // ignore: avoid_print
      print('[openMapOsm] final coordinate map URL: $mapUrl');
      try {
        openInNewTabWithName(mapUrl, 'driverroute_map');
      } catch (e) {
        // ignore, will show snack instead
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Öffne Karte in neuem Tab...'),
        ));
      }
      return;
    }

    final parts = <String>[];
    parts.add('${Uri.encodeComponent(s)}');
    if (stops.isNotEmpty) {
      for (final w in stops) {
        if (w.trim().isEmpty) continue;
        parts.add(Uri.encodeComponent(w));
      }
    }
    parts.add('${Uri.encodeComponent(d)}');
    final mapUrl = 'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route=' + parts.join(';');
    // ignore: avoid_print
    print('[openMapOsm] final map URL with waypoints: $mapUrl');
    try {
      openInNewTabWithName(mapUrl, 'driverroute_map');
    } catch (e) {
      // ignore, will show snack instead
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Öffne Karte in neuem Tab...'),
      ));
    }
    return;
  }

  try {
    final res = await http.get(uri);
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['status'] != 'OK') throw Exception('Directions ${data['status']}');

    final route = (data['routes'] as List).first as Map<String, dynamic>;
    final legs = (route['legs'] as List).cast<Map<String, dynamic>>();
    final firstLeg = legs.first;
    final lastLeg = legs.last;
    final sl = firstLeg['start_location'] as Map<String, dynamic>;
    final dl = lastLeg['end_location'] as Map<String, dynamic>;
    final poly = (route['overview_polyline'] as Map<String, dynamic>)['points'] as String;

    final start = LatLng((sl['lat'] as num).toDouble(), (sl['lng'] as num).toDouble());
    final dest = LatLng((dl['lat'] as num).toDouble(), (dl['lng'] as num).toDouble());
    final coords = decodePolyline(poly);
    // debug counts for decoded polyline
    // ignore: avoid_print
    print('[openMapOsm] decoded route points: ${coords.length}');
    final validCoords = coords.where((p) => p.latitude >= -90 && p.latitude <= 90 && p.longitude >= -180 && p.longitude <= 180).toList();
    // ignore: avoid_print
    print('[openMapOsm] valid route points: ${validCoords.length}');
    if (validCoords.length < 2) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Karte: Ungültige Routenpunkte.')));
      return;
    }

    final coordParts = <String>[];
    coordParts.add('${start.latitude},${start.longitude}');
    if (stopCoords.isNotEmpty) {
      for (final c in stopCoords) {
        if (c == null) continue;
        coordParts.add('${c.latitude},${c.longitude}');
      }
    }
    coordParts.add('${dest.latitude},${dest.longitude}');
    final mapUrl = Uri.encodeFull('https://www.openstreetmap.org/directions?engine=fossgis_osrm_car&route=${coordParts.join(';')}');
    // ignore: avoid_print
    print('[openMapOsm] waypoints=$stops');
    // ignore: avoid_print
    print('[openMapOsm] final map URL with waypoints: $mapUrl');

    if (kIsWeb) {
      // ignore: avoid_print
      print('[openMapOsm] final map URL: $mapUrl');
      try {
        openInNewTabWithName(mapUrl, 'driverroute_map');
      } catch (e) {
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MapOsmView(start: start, dest: dest, route: coords),
            ),
          );
        }
      }
      return;
    }

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapOsmView(start: start, dest: dest, route: coords),
      ),
    );
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Karte fehlgeschlagen: $e')));
    }
  }
}
