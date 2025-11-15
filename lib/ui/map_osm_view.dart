import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapOsmView extends StatelessWidget {
  final LatLng start;
  final LatLng dest;
  final List<LatLng> route;
  const MapOsmView(
      {super.key,
      required this.start,
      required this.dest,
      required this.route});

  @override
  Widget build(BuildContext context) {
    // Sicherstellen, dass die Route am Start beginnt und am Ziel endet
    final List<LatLng> fullRoute = [start, ...route];
    if (route.isEmpty || route.last != dest) {
      fullRoute.add(dest);
    }
    // Bounds initialisieren mit erstem Punkt
    final bounds = LatLngBounds(fullRoute.first, fullRoute.first);
    for (final p in fullRoute) {
      bounds.extend(p);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('🗺️ Route (OSM)')),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: start,
          initialZoom: 5,
          onMapReady: () {
            MapController.of(context)?.fitCamera(CameraFit.bounds(
                bounds: bounds, padding: const EdgeInsets.all(24)));
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.mexx.driverroute.eta',
          ),
          PolylineLayer(polylines: [
            Polyline(points: fullRoute, strokeWidth: 4),
          ]),
          MarkerLayer(markers: [
            Marker(
                point: start,
                width: 36,
                height: 36,
                child: const Icon(Icons.flag, size: 28)),
            Marker(
                point: dest,
                width: 36,
                height: 36,
                child: const Icon(Icons.location_pin, size: 32)),
          ]),
        ],
      ),
    );
  }
}
