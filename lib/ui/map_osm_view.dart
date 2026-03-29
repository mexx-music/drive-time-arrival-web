import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class MapOsmView extends StatefulWidget {
  final LatLng start;
  final LatLng dest;
  final List<LatLng> route;
  const MapOsmView(
      {super.key,
      required this.start,
      required this.dest,
      required this.route});

  @override
  State<MapOsmView> createState() => _MapOsmViewState();
}

class _MapOsmViewState extends State<MapOsmView> {
  late List<LatLng> _points;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _points = List<LatLng>.from(widget.route);
    int retries = 0;
    const int maxRetries = 5;
    const Duration interval = Duration(milliseconds: 300);
    Timer.periodic(interval, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      // ignore: avoid_print
      print('[MapOsmView] retry check: ${widget.route.length}');
      if (_points.length >= 2) {
        timer.cancel();
        return;
      }
      if (widget.route.length >= 2) {
        setState(() {
          _points = List<LatLng>.from(widget.route);
        });
        // ignore: avoid_print
        print('[MapOsmView] updated points count: ${_points.length}');
        timer.cancel();
        return;
      }
      retries++;
      if (retries >= maxRetries) {
        timer.cancel();
      }
    });
  }

  @override
  void didUpdateWidget(covariant MapOsmView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // if parent provides more points later, update internal state
    if (widget.route.length != oldWidget.route.length && widget.route.length >= 2) {
      setState(() {
        _points = List<LatLng>.from(widget.route);
      });
      // ignore: avoid_print
      print('[MapOsmView] didUpdateWidget points count: ${_points.length}');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sicherstellen, dass die Route am Start beginnt und am Ziel endet
    final List<LatLng> fullRoute = [widget.start, ..._points];
    if (_points.isEmpty || _points.last != widget.dest) {
      fullRoute.add(widget.dest);
    }

    // Debug: Anzahl Punkte
    // ignore: avoid_print
    print('[MapOsmView] route points count: ${fullRoute.length}');

    // Wenn weniger als 2 valide Punkte vorliegen, zeige eine einfache Lade-Seite
    if (fullRoute.length < 2) {
      return Scaffold(
        appBar: AppBar(title: const Text('Karte wird geladen...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Bounds initialisieren mit erstem Punkt
    final bounds = LatLngBounds(fullRoute.first, fullRoute.first);
    for (final p in fullRoute) {
      bounds.extend(p);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('🗺️ Route (OSM)')),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: widget.start,
          initialZoom: 5,
          onMapReady: () {
            // ignore: avoid_print
            print('[MapOsmView] using local MapController');
            _mapController.fitCamera(CameraFit.bounds(
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
                point: widget.start,
                width: 36,
                height: 36,
                child: const Icon(Icons.flag, size: 28)),
            Marker(
                point: widget.dest,
                width: 36,
                height: 36,
                child: const Icon(Icons.location_pin, size: 32)),
          ]),
        ],
      ),
    );
  }
}
