import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../animation/country_borders.dart';
import '../animation/tour_camera.dart';
import '../animation/tour_path.dart';
import '../animation/tour_story.dart';
import 'map_label_style.dart';
import 'tour_animation_view.dart' show tourKmLabel;
import 'tour_story_overlay.dart';
import 'truck_sprites.dart';

/// EXPERIMENT: dieselbe Cinematic-Szene in 2.5D mit MapLibre + Vektorkacheln
/// (OpenFreeMap). Nutzt [TourPath], Story, Fahrleiste und Abschlusskarte
/// unverändert; nur die Karte darunter ist eine andere.
class TourAnimationSceneMapLibre extends StatefulWidget {
  const TourAnimationSceneMapLibre({
    super.key,
    required this.path,
    required this.position,
    required this.title,
    required this.frame,
    this.stops = const [],
    this.finished = false,
    this.manualZoom,
    this.countries,
    this.planKm,
    this.summary,
    this.fromName,
    this.toName,
    this.storyEvents = const [],
    this.onReady,
    this.truckView = TruckView.top,
  });

  /// Ansicht des Fahrzeugs in der geneigten Karte.
  final TruckView truckView;

  /// Karte, Stil und Ebenen sind bereit – erst dann soll die Fahrt laufen.
  final VoidCallback? onReady;

  final TourPath path;
  final TourPosition position;
  final String title;
  final TourFrame frame;
  final List<LatLng> stops;
  final bool finished;
  final double? manualZoom;
  final CountryIndex? countries;
  final double? planKm;
  final TourSummary? summary;
  final String? fromName;
  final String? toName;
  final List<TourStoryEvent> storyEvents;

  /// Stil: OpenFreeMap „Liberty“ (OpenMapTiles-Schema), Beschriftung lesbar.
  static const styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static Future<String>? _style;

  /// Stil einmal laden und umschreiben – derselbe Abruf, den MapLibre sonst
  /// selbst machen würde.
  static Future<String> loadStyle() => _style ??= () async {
        try {
          final res = await http.get(Uri.parse(styleUrl));
          if (res.statusCode != 200) throw StateError('Stil HTTP ${res.statusCode}');
          final style = jsonDecode(res.body) as Map<String, dynamic>;
          return jsonEncode(latinizeStyle(style));
        } catch (_) {
          _style = null;
          rethrow;
        }
      }();

  @override
  State<TourAnimationSceneMapLibre> createState() => _TourAnimationSceneMapLibreState();
}

class _TourAnimationSceneMapLibreState extends State<TourAnimationSceneMapLibre> {
  late final Future<String> _style = TourAnimationSceneMapLibre.loadStyle();
  late final TourCameraRig _rig = TourCameraRig(widget.path);
  ml.MapLibreMapController? _map;
  bool _ready = false;
  DateTime? _lastFrame;
  DateTime _lastTrail = DateTime.fromMillisecondsSinceEpoch(0);
  String? _highlightIso;
  bool _overviewShown = false;
  double _cameraBearing = 0;

  static ml.LatLng _ml(LatLng p) => ml.LatLng(p.latitude, p.longitude);

  Map<String, dynamic> _line(List<LatLng> pts, [Map<String, dynamic> props = const {}]) => {
        'type': 'Feature',
        'properties': props,
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in pts) [p.longitude, p.latitude]],
        },
      };

  Map<String, dynamic> _collection(List<Map<String, dynamic>> features) =>
      {'type': 'FeatureCollection', 'features': features};

  Future<void> _onStyleLoaded() async {
    final map = _map;
    if (map == null) return;
    final path = widget.path;
    await map.addImage('truck-top', await truckTopPng());
    await map.addImage('truck-rear', await truckRearPng());
    await map.addImage('truck', await truckSidePng(mirrored: false));
    await map.addImage('truck-mirrored', await truckSidePng(mirrored: true));

    await map.addGeoJsonSource('country', _collection(const []));
    await map.addFillLayer('country', 'country-fill',
        const ml.FillLayerProperties(fillColor: '#1565C0', fillOpacity: 0.0));
    await map.addLineLayer('country', 'country-line',
        const ml.LineLayerProperties(lineColor: '#1565C0', lineWidth: 2, lineOpacity: 0.0));

    final full = path.trailUpTo(path.totalMeters, maxPointsPerLeg: 1500);
    await map.addGeoJsonSource('route', _collection([
      for (final t in full) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
    ]));
    await map.addLineLayer('route', 'route-line', const ml.LineLayerProperties(
      lineColor: ['case', ['get', 'ferry'], '#26A69A', '#3F51B5'],
      lineOpacity: 0.45,
      lineWidth: 5,
      lineCap: 'round',
      lineJoin: 'round',
    ));
    await map.addGeoJsonSource('driven', _collection(const []));
    await map.addLineLayer('driven', 'driven-line', const ml.LineLayerProperties(
      lineColor: ['case', ['get', 'ferry'], '#00897B', '#1B5E20'],
      lineWidth: 7,
      lineCap: 'round',
      lineJoin: 'round',
    ));
    await map.addGeoJsonSource('points', _collection([
      _point(path.start, {'kind': 'start'}),
      for (final s in widget.stops) _point(s, {'kind': 'stop'}),
      _point(path.end, {'kind': 'dest'}),
    ]));
    await map.addCircleLayer('points', 'points-circle', const ml.CircleLayerProperties(
      circleRadius: ['match', ['get', 'kind'], 'stop', 5, 8],
      circleColor: ['match', ['get', 'kind'], 'start', '#2E7D32', 'dest', '#C62828', '#3949AB'],
      circleStrokeColor: '#FFFFFF',
      circleStrokeWidth: 2,
      circlePitchAlignment: 'map',
    ));
    await map.addGeoJsonSource(
        'truck', _collection([_point(widget.position.point, _truckProps(widget.position.bearing))]));
    // Von oben: flach auf der Karte (dreht und neigt sich mit ihr).
    // Von hinten / seitlich: aufrecht zum Betrachter.
    final flat = widget.truckView == TruckView.top;
    await map.addSymbolLayer('truck', 'truck-symbol', ml.SymbolLayerProperties(
      iconImage: ['get', 'icon'],
      iconSize: ['match', ['get', 'icon'], 'truck-top', 0.3, 'truck-rear', 0.32, 0.55],
      iconRotate: ['get', 'rot'],
      iconRotationAlignment: flat ? 'map' : 'viewport',
      iconPitchAlignment: flat ? 'map' : 'viewport',
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
    ));
    _ready = true;
    _update(force: true);
    widget.onReady?.call();
  }

  /// Bild und Drehung des Fahrzeugs für die gewählte Ansicht.
  Map<String, dynamic> _truckProps(double heading) {
    final relative = angleDiff(_cameraBearing, heading); // zur Blickrichtung
    switch (widget.truckView) {
      case TruckView.top:
        return {'icon': 'truck-top', 'rot': heading}; // Kartenrichtung
      case TruckView.rear:
        // Fährt die Kamera hinterher (Regelfall), zeigt sie das Heck; leichte
        // Neigung in Kurven. Bei starker Abweichung seitlich.
        if (relative.abs() <= 50) return {'icon': 'truck-rear', 'rot': relative * 0.35};
        continue side;
      side:
      case TruckView.side:
        final pose = truckPose(relative);
        return {
          'icon': pose.mirrored ? 'truck-mirrored' : 'truck',
          'rot': pose.radians * 180 / math.pi,
        };
    }
  }

  Map<String, dynamic> _point(LatLng p, Map<String, dynamic> props) => {
        'type': 'Feature',
        'properties': props,
        'geometry': {'type': 'Point', 'coordinates': [p.longitude, p.latitude]},
      };

  @override
  void didUpdateWidget(TourAnimationSceneMapLibre old) {
    super.didUpdateWidget(old);
    if (widget.position.meters < old.position.meters - 1) {
      _rig.reset(); // Neustart
      _overviewShown = false;
    }
    _update();
  }

  void _update({bool force = false}) {
    final map = _map;
    if (!_ready || map == null) return;
    final now = DateTime.now();
    final dt = _lastFrame == null ? Duration.zero : now.difference(_lastFrame!);
    _lastFrame = now;
    final pos = widget.position;

    // Kamera: ruhig in Fahrtrichtung, am Ziel Übersicht von oben.
    if (widget.finished) {
      if (!_overviewShown) {
        _overviewShown = true;
        final pts = widget.path.points;
        var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
        for (final p in pts) {
          s = math.min(s, p.latitude);
          n = math.max(n, p.latitude);
          w = math.min(w, p.longitude);
          e = math.max(e, p.longitude);
        }
        map.moveCamera(ml.CameraUpdate.tiltTo(0));
        map.moveCamera(ml.CameraUpdate.bearingTo(0));
        _cameraBearing = 0;
        map.animateCamera(
          ml.CameraUpdate.newLatLngBounds(
            ml.LatLngBounds(southwest: ml.LatLng(s, w), northeast: ml.LatLng(n, e)),
            left: 60, top: 140, right: 60, bottom: 260,
          ),
          duration: const Duration(milliseconds: 1600),
        );
      }
    } else {
      _cameraBearing = _rig.step(pos.meters, dt);

      map.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(
        target: _ml(_rig.targetAt(pos.meters)),
        zoom: widget.manualZoom ?? _rig.zoom,
        bearing: _cameraBearing,
        tilt: _rig.pitch,
      )));
    }

    map.setGeoJsonSource('truck', _collection([_point(pos.point, _truckProps(pos.bearing))]));

    // Gefahrene Spur: höchstens etwa 12-mal pro Sekunde neu.
    if (force || widget.finished || now.difference(_lastTrail).inMilliseconds > 80) {
      _lastTrail = now;
      final trail = widget.path.trailUpTo(pos.meters, maxPointsPerLeg: 800);
      map.setGeoJsonSource('driven', _collection([
        for (final t in trail) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
      ]));
    }

    // Länder-Hervorhebung beim Grenzübertritt.
    final e = widget.frame.event;
    final iso = e?.kind == TourStoryKind.borderCrossing ? e!.toIso : null;
    if (iso != _highlightIso) {
      _highlightIso = iso;
      final shape = iso == null ? null : widget.countries?.byIso(iso);
      map.setGeoJsonSource('country', _collection([
        if (shape != null)
          {
            'type': 'Feature',
            'properties': const <String, dynamic>{},
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                for (final rings in shape.polygons)
                  [
                    for (final ring in rings)
                      [for (final p in [...ring, ring.first]) [p.longitude, p.latitude]],
                  ],
              ],
            },
          },
      ]));
    }
    final glow = iso == null ? 0.0 : storyFade(widget.frame.eventProgress);
    map.setLayerProperties('country-fill', ml.FillLayerProperties(fillOpacity: 0.16 * glow));
    map.setLayerProperties('country-line', ml.LineLayerProperties(lineOpacity: 0.75 * glow));
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final pos = widget.position;
    final frame = widget.frame;
    final progress = path.totalMeters <= 0 ? 0.0 : pos.meters / path.totalMeters;
    final planKm = widget.planKm;
    final km = planKm == null
        ? tourKmLabel(pos.roadMeters, path.roadMeters)
        : tourKmLabel(planKmAt(path, pos.meters, planKm) * 1000, planKm * 1000);
    final startIso = widget.summary?.startIso ?? widget.countries?.countryAt(path.start);
    final arrivalFade = frame.event?.kind == TourStoryKind.arrival
        ? (frame.eventProgress / 0.2).clamp(0.0, 1.0)
        : 0.0;

    return Stack(children: [
      Positioned.fill(
        child: FutureBuilder<String>(
          future: _style,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('Kartenstil nicht erreichbar (OpenFreeMap).'));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return ml.MapLibreMap(
              styleString: snap.data!,
              initialCameraPosition: ml.CameraPosition(
                target: _ml(_rig.targetAt(pos.meters)),
                zoom: _rig.zoom,
                bearing: _rig.headingAt(pos.meters),
                tilt: _rig.pitch,
              ),
              onMapCreated: (c) => _map = c,
              onStyleLoadedCallback: _onStyleLoaded,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              scrollGesturesEnabled: false,
              zoomGesturesEnabled: false,
              doubleClickZoomEnabled: false,
              compassEnabled: false,
              attributionButtonPosition: ml.AttributionButtonPosition.bottomLeft,
            );
          },
        ),
      ),
      Positioned.fill(
        child: TourStoryOverlay(
          frame: frame,
          summary: widget.summary,
          fromName: widget.fromName,
          toName: widget.toName,
          countrySequence: storyCountrySequence(widget.storyEvents, startIso),
        ),
      ),
      Positioned(
        left: 12,
        right: 12,
        top: 12,
        child: Opacity(
          opacity: 1 - arrivalFade,
          child: TourStoryHud(
            title: widget.title,
            km: km,
            progress: progress,
            frame: frame,
            events: widget.storyEvents,
            startIso: startIso,
          ),
        ),
      ),
    ]);
  }
}
