import 'package:latlong2/latlong.dart';

/// Dekodiert eine Google-"encoded polyline" (Faktor 1e5) zu Koordinaten.
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
  return points;
}
