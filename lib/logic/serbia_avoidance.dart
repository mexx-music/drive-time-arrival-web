import 'dart:math' as math;

class CountryRouteException implements Exception {
  final String message;
  const CountryRouteException(this.message);

  @override
  String toString() => message;
}

/// Automatic transit corridor for Greece–Austria when Serbia is excluded.
/// These are routing controls, not user-requested stops or rest breaks.
class SerbiaAvoidance {
  static const _corridor = [
    'Sofia, Bulgaria',
    'Ruse, Bulgaria',
    'Sibiu, Romania',
    'Arad, Romania',
    'Budapest, Hungary',
  ];

  static List<String>? corridorFor(String origin, String destination) {
    final from = origin.toLowerCase();
    final to = destination.toLowerCase();
    final fromGreece = _containsAny(from, ['greece', 'griechenland', 'ελλάδα']);
    final toGreece = _containsAny(to, ['greece', 'griechenland', 'ελλάδα']);
    final fromAustria = _containsAny(from, ['austria', 'österreich']);
    final toAustria = _containsAny(to, ['austria', 'österreich']);
    if (fromGreece && toAustria) return _corridor;
    if (fromAustria && toGreece) return _corridor.reversed.toList();
    return null;
  }

  static bool _containsAny(String input, List<String> tokens) =>
      tokens.any(input.contains);

  /// Returns null if Google did not supply usable route geometry.
  static bool? routeCrossesSerbia(Map<String, dynamic> response) {
    try {
      final routes = response['routes'] as List;
      if (routes.isEmpty) return null;
      final route = routes.first as Map<String, dynamic>;
      final legs = route['legs'] as List?;
      if (legs != null && legs.isNotEmpty) {
        var checkedStep = false;
        for (final rawLeg in legs) {
          final leg = rawLeg as Map<String, dynamic>;
          final steps = leg['steps'] as List?;
          if (steps == null || steps.isEmpty) return null;
          for (final rawStep in steps) {
            final step = rawStep as Map<String, dynamic>;
            final polyline = step['polyline'] as Map<String, dynamic>?;
            final encoded = polyline?['points'] as String?;
            if (encoded == null) return null;
            final points = _decodePolyline(encoded);
            if (points.length < 2) return null;
            checkedStep = true;
            if (_crossesBorder(points)) return true;
          }
        }
        if (checkedStep) return false;
      }
      final overview = route['overview_polyline'] as Map<String, dynamic>;
      final encoded = overview['points'] as String;
      final points = _decodePolyline(encoded);
      if (points.length < 2) return null;
      return _crossesBorder(points);
    } catch (_) {
      return null;
    }
  }

  static bool _crossesBorder(List<(double, double)> points) {
    for (var index = 1; index < points.length; index++) {
      final a = points[index - 1];
      final b = points[index];
      // Interpolate across simplified overview segments so a border crossing
      // cannot be missed merely because neither endpoint lies in Serbia.
      final subdivisions = math.max(
        1,
        (math.max((a.$1 - b.$1).abs(), (a.$2 - b.$2).abs()) / 0.03).ceil(),
      );
      for (var step = 0; step <= subdivisions; step++) {
        final fraction = step / subdivisions;
        if (_insideSerbia(
          a.$1 + (b.$1 - a.$1) * fraction,
          a.$2 + (b.$2 - a.$2) * fraction,
        )) {
          return true;
        }
      }
    }
    return false;
  }

  static List<(double, double)> _decodePolyline(String encoded) {
    final points = <(double, double)>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;
    int nextDelta() {
      var value = 0;
      var shift = 0;
      while (true) {
        if (index >= encoded.length) throw const FormatException('Polyline');
        final byte = encoded.codeUnitAt(index++) - 63;
        value |= (byte & 0x1f) << shift;
        shift += 5;
        if (byte < 0x20) break;
      }
      final magnitude = value ~/ 2;
      return value.isOdd ? -magnitude - 1 : magnitude;
    }

    while (index < encoded.length) {
      latitude += nextDelta();
      longitude += nextDelta();
      points.add((latitude / 1e5, longitude / 1e5));
    }
    return points;
  }

  static List<(double, double)> decodeCoordinates(String encoded) =>
      _decodePolyline(encoded);

  static bool _insideSerbia(double latitude, double longitude) {
    if (latitude < 42.2 ||
        latitude > 46.2 ||
        longitude < 18.8 ||
        longitude > 23) {
      return false;
    }
    var inside = false;
    for (var i = 0, j = _border.length - 1; i < _border.length; j = i++) {
      final a = _border[i];
      final b = _border[j];
      final crossesLatitude = (a.$2 > latitude) != (b.$2 > latitude);
      if (crossesLatitude &&
          longitude <
              (b.$1 - a.$1) * (latitude - a.$2) / (b.$2 - a.$2) + a.$1) {
        inside = !inside;
      }
    }
    return inside;
  }

  static bool containsCoordinate(double latitude, double longitude) =>
      _insideSerbia(latitude, longitude);

  // Natural Earth 1:50m Admin-0 Serbia, every second vertex, rounded to 1e-4°.
  // Natural Earth data is public domain; this is a planning check, not a
  // legally authoritative border. Source:
  // https://github.com/nvkelso/natural-earth-vector/tree/master/geojson
  static const _border = <(double, double)>[
    (21.3601, 44.8267),
    (21.5971, 44.7554),
    (21.7402, 44.6807),
    (22.027, 44.6199),
    (22.201, 44.5607),
    (22.4977, 44.7063),
    (22.7209, 44.6055),
    (22.7008, 44.5555),
    (22.554, 44.5403),
    (22.4945, 44.4354),
    (22.5818, 44.3383),
    (22.6833, 44.2865),
    (22.7051, 44.2378),
    (22.6266, 44.1941),
    (22.5975, 44.0753),
    (22.4208, 44.0074),
    (22.3654, 43.8621),
    (22.3869, 43.7401),
    (22.4363, 43.6655),
    (22.4991, 43.5188),
    (22.697, 43.3911),
    (22.8197, 43.3007),
    (22.9769, 43.188),
    (22.9423, 43.0971),
    (22.8568, 43.0183),
    (22.7062, 42.8839),
    (22.5228, 42.8703),
    (22.4393, 42.7916),
    (22.4633, 42.7095),
    (22.4721, 42.5433),
    (22.5324, 42.4812),
    (22.4457, 42.3591),
    (22.344, 42.314),
    (22.2771, 42.3499),
    (22.1467, 42.325),
    (21.9775, 42.3201),
    (21.853, 42.3084),
    (21.7393, 42.2677),
    (21.5625, 42.2475),
    (21.5189, 42.3284),
    (21.6099, 42.3875),
    (21.7307, 42.5955),
    (21.7529, 42.6698),
    (21.6625, 42.6815),
    (21.403, 42.8315),
    (21.2371, 42.9132),
    (21.1271, 43.043),
    (20.9677, 43.116),
    (20.8444, 43.1734),
    (20.8238, 43.2379),
    (20.7634, 43.2586),
    (20.6231, 43.1986),
    (20.6376, 43.1304),
    (20.6485, 43.0709),
    (20.4751, 42.953),
    (20.4868, 42.8791),
    (20.3443, 42.8279),
    (20.3399, 42.8929),
    (20.1679, 42.9685),
    (19.858, 43.0965),
    (19.671, 43.164),
    (19.5516, 43.2123),
    (19.2982, 43.414),
    (19.1965, 43.485),
    (19.1943, 43.5333),
    (19.3008, 43.5918),
    (19.3996, 43.5676),
    (19.48, 43.5952),
    (19.4882, 43.7036),
    (19.2572, 43.9433),
    (19.2681, 43.9834),
    (19.3452, 43.9851),
    (19.5495, 43.9871),
    (19.5838, 44.0435),
    (19.4302, 44.1545),
    (19.2315, 44.2806),
    (19.1283, 44.3303),
    (19.1273, 44.4146),
    (19.1514, 44.5273),
    (19.2919, 44.6968),
    (19.3568, 44.8585),
    (19.3127, 44.8975),
    (19.1315, 44.8996),
    (19.0071, 44.8692),
    (19.0096, 44.9194),
    (19.0605, 44.911),
    (19.1, 44.9738),
    (19.1297, 45.1517),
    (19.1369, 45.1962),
    (19.303, 45.1673),
    (19.401, 45.1891),
    (19.3823, 45.2306),
    (19.3303, 45.2681),
    (19.0931, 45.3369),
    (19.0076, 45.4658),
    (19.0643, 45.515),
    (18.9537, 45.558),
    (18.9473, 45.6558),
    (18.8391, 45.8357),
    (18.9011, 45.9076),
    (18.9278, 45.9314),
    (19.0477, 45.9827),
    (19.0873, 46.0162),
    (19.2084, 45.9844),
    (19.3303, 46.0285),
    (19.4213, 46.0645),
    (19.5308, 46.1552),
    (19.7245, 46.1519),
    (19.9341, 46.1615),
    (20.2102, 46.126),
    (20.3014, 46.0507),
    (20.438, 45.9408),
    (20.5812, 45.8695),
    (20.7093, 45.7353),
    (20.7469, 45.749),
    (20.775, 45.7498),
    (20.7793, 45.662),
    (20.786, 45.5365),
    (20.7725, 45.5001),
    (20.794, 45.4679),
    (20.9418, 45.3653),
    (21.0999, 45.2936),
    (21.2265, 45.2413),
    (21.4314, 45.1925),
    (21.4902, 45.1479),
    (21.4679, 45.1099),
    (21.4207, 45.033),
    (21.3711, 45.0214),
    (21.357, 44.9908),
    (21.41, 44.9577),
    (21.5332, 44.9188),
    (21.5199, 44.8808),
    (21.3844, 44.8701),
    (21.3601, 44.8267),
  ];
}
