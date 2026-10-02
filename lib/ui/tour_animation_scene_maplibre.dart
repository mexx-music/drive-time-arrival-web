import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../animation/articulation.dart';
import '../animation/cinematic_camera.dart';
import '../animation/country_borders.dart';
import '../animation/daylight.dart';
import '../animation/tour_camera.dart';
import '../logic/eta_calculator.dart';
import '../animation/tour_path.dart';
import '../animation/tour_story.dart';
import 'map_label_style.dart';
import 'tour_animation_view.dart' show tourKmLabel;
import 'tour_story_overlay.dart';
import 'truck_sprites.dart';
import '../animation/truck_projection.dart';

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
    this.truckModel = const TruckModel(),
    this.truckBias = 22,
    this.truckPitch = 42,
    this.truckScale = 1,
    this.cameraMode = CameraMode.follow,
    this.cinematicDemo = false,
    this.cameraDebug = false,
    this.dayNight = DayNightMode.off,
    this.eta,
  });

  /// Kamera: ruhige Folgekamera oder mit wenigen Drohnenfahrten.
  final CameraMode cameraMode;

  /// Demo: Kamerafahrten gedrängt, um sie schnell nacheinander zu sehen.
  final bool cinematicDemo;

  /// Entwicklung: Kamerawerte einblenden.
  final bool cameraDebug;

  /// Tag/Nacht: aus, aus der Planung oder simuliert (Demo).
  final DayNightMode dayNight;

  /// Planung für Tag/Nacht (Uhrzeit entlang der Strecke).
  final EtaResult? eta;

  /// Fahrzeugtyp und Branding (getrennt wählbar).
  final TruckModel truckModel;

  /// 3/4: Schrägstellung in Grad, die die Aufliegerseite zeigt.
  final double truckBias;

  /// 3/4: Neigung, mit der das Fahrzeug gezeichnet wird (Karte: 42°).
  final double truckPitch;

  /// 3/4: Größenfaktor des Fahrzeugs.
  final double truckScale;

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

  /// Kamera (Regie) – erst im ersten build angelegt, wenn das Bildformat
  /// bekannt ist.
  CinematicCamera? _cam;
  CameraState? _camState;
  double _cameraZoom = 0;
  double _cameraPitch = 42;

  /// Tag/Nacht.
  late final TourClock? _clock =
      widget.eta == null ? null : TourClock.fromEta(widget.eta!, widget.path);
  final DaylightEaser _daylight = DaylightEaser();
  double _night = 0;
  double _shownVeil = -1;
  ArticulatedPose? _pose;

  CinematicCamera _cameraFor(Size size) => _cam ??= CinematicCamera(
        widget.path,
        plan: widget.cameraMode == CameraMode.follow
            ? CinematicPlan.followOnly
            : (widget.cinematicDemo
                ? CinematicPlan.demo()
                : CinematicPlan.standard(tourAnimationDuration(widget.path.totalMeters))),
        aspect: size.height <= 0 ? 1.6 : size.width / size.height,
      );
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

    // Nacht: dunkler Schleier über der Grundkarte, unter Route und LKW.
    await map.addGeoJsonSource('veil', _collection([
      {
        'type': 'Feature',
        'properties': const <String, dynamic>{},
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [[-180, -85], [180, -85], [180, 85], [-180, 85], [-180, -85]]
          ],
        },
      },
    ]));
    await map.addFillLayer('veil', 'night-veil',
        const ml.FillLayerProperties(fillColor: '#0B1730', fillOpacity: 0.0));
    await map.addImage('headlights', await headlightConePng());

    await map.addGeoJsonSource('country', _collection(const []));
    await map.addFillLayer('country', 'country-fill',
        const ml.FillLayerProperties(fillColor: '#1565C0', fillOpacity: 0.0));
    await map.addLineLayer('country', 'country-line',
        const ml.LineLayerProperties(lineColor: '#1565C0', lineWidth: 2, lineOpacity: 0.0));

    // Die ganze Route mit ALLEN Punkten der Berechnung (Etappen-Geometrie),
    // nicht ausgedünnt – MapLibre vereinfacht je Zoomstufe selbst passend.
    await map.addGeoJsonSource('route', _collection([
      for (final leg in path.legs) _line(leg.points, {'ferry': leg.kind != TourLegKind.road}),
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
        'truck', _collection([_point(widget.position.point, _truckProps(_localHeading(widget.position.meters)))]));
    // Zwei Ebenen, je Feature gewählt: flach auf der Karte (von oben; dreht
    // und neigt sich mit ihr) oder aufrecht zum Betrachter (Heck, seitlich,
    // 3/4 – das Bild bringt die Perspektive selbst mit).
    for (final flat in [true, false]) {
      await map.addSymbolLayer('truck', flat ? 'truck-flat' : 'truck-upright', ml.SymbolLayerProperties(
        iconImage: ['get', 'icon'],
        iconSize: ['get', 'size'],
        iconRotate: ['get', 'rot'],
        iconRotationAlignment: flat ? 'map' : 'viewport',
        iconPitchAlignment: flat ? 'map' : 'viewport',
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ), filter: ['==', ['get', 'flat'], flat]);
    }
    // Lichtkegel: flach auf der Straße, gedreht mit der ZUGMASCHINE (nicht mit
    // der Kamera) – unter dem Fahrzeug.
    await map.addGeoJsonSource('lights', _collection(const []));
    await map.addSymbolLayer('lights', 'headlight-cone', const ml.SymbolLayerProperties(
      iconImage: 'headlights',
      iconSize: ['get', 'size'],
      iconRotate: ['get', 'rot'],
      iconRotationAlignment: 'map',
      iconPitchAlignment: 'map',
      iconAnchor: 'bottom',
      iconOpacity: 0.0,
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
    ), belowLayerId: 'truck-flat');
    _ready = true;
    _update(force: true);
    widget.onReady?.call();
  }

  // ------------------------------------------------ Geometrie, unvereinfacht

  /// Alle Punkte der Linie und ihre Strecke ab Start – einmal berechnet.
  late final List<LatLng> _pts = widget.path.points;
  late final List<double> _cum = () {
    const d = Distance(calculator: Haversine());
    final out = <double>[0];
    for (var i = 1; i < _pts.length; i++) {
      out.add(out.last + d(_pts[i - 1], _pts[i]));
    }
    return out;
  }();

  int _indexAt(double meters) {
    var lo = 0, hi = _cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_cum[mid] <= meters) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Gefahrene Spur: die letzten [window] Meter punktgenau aus der vollen
  /// Geometrie (Kreuze, Umfahrungen, enge Kurven), weiter hinten leicht
  /// ausgedünnt – die Spur wird etwa 12-mal pro Sekunde neu übergeben.
  List<Map<String, dynamic>> _drivenFeatures(TourPosition pos, {double window = 60000}) {
    final m = pos.meters;
    final split = math.max(0.0, m - window);
    final older = split > 0
        ? widget.path.trailUpTo(split, maxPointsPerLeg: 1500)
        : const <TourTrail>[];
    final from = _indexAt(split);
    final to = _indexAt(m);
    final recent = <LatLng>[
      if (split > 0) widget.path.at(split).point,
      for (var i = from + 1; i <= to; i++) _pts[i],
      pos.point,
    ];
    return [
      for (final t in older) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
      if (recent.length >= 2) _line(recent, {'ferry': pos.kind != TourLegKind.road}),
    ];
  }

  /// Fahrtrichtung des Fahrzeugs: lokal über ±150 m der vollen Geometrie,
  /// damit es auch in Kreuzen und engen Kurven der Straße folgt. (Die
  /// Kamera nutzt ihre eigene, bewusst weiche Richtung.)
  double _localHeading(double meters) {
    const span = 150.0;
    final a = widget.path.at(math.max(0, meters - span)).point;
    final b = widget.path.at(math.min(widget.path.totalMeters, meters + span)).point;
    if (a == b) return widget.position.bearing;
    return (const Distance(calculator: Haversine()).bearing(a, b) + 360) % 360;
  }

  /// Bild und Drehung des Fahrzeugs für die gewählte Ansicht.
  // ------------------------------------------------------ 3/4-Fahrzeug

  /// Aktuell gezeigte Seite (Auto mit Hysterese) und weicher Seitenwinkel.
  final SideChooser _sideChooser = SideChooser();
  double? _bias;
  int _frame = 0;
  String? _shownFrame;
  final Set<String> _framesReady = {};
  final Set<String> _framesPending = {};
  Duration _dt = Duration.zero;

  String _frameName(int frame) =>
      '34-${widget.truckModel.id}-p${widget.truckPitch.round()}-$frame';

  /// Bild für einen Gierwinkel bei Bedarf erzeugen und der Karte geben.
  void _ensureFrame(int frame) {
    final name = _frameName(frame);
    if (_framesReady.contains(name) || _framesPending.contains(name)) return;
    _framesPending.add(name);
    truckThreeQuarterPng(widget.truckModel,
            yawDeg: frame * _frameStep, pitchDeg: widget.truckPitch, pxPerMeter: 10)
        .then((png) async {
      await _map?.addImage(name, png);
      _framesPending.remove(name);
      _framesReady.add(name);
    });
  }

  static const _frameStep = 4.0;

  // --------------------------------------------- gekoppelter Sattelzug

  /// Sprite: Bildpunkte je Fahrzeugmeter; Anzeige: Punkte je Meter bei
  /// Folge-Zoom (mit [truckScale]).
  static const _spritePx = 12.0;
  double get _pointsPerMeter => 5 * widget.truckScale;

  /// Kartenmeter je Fahrzeugmeter – aus dem FOLGE-Zoom, nicht aus dem Zoom
  /// der aktuellen Kamerafahrt: die Kamera verändert die Fahrzeuggeometrie nie.
  double _unitAt(LatLng p) =>
      _pointsPerMeter * metersPerScreenPoint(_cam?.followZoom ?? _rig.zoom, p.latitude);

  int _yawFrame = 0, _knickFrame = 0;

  String _articulatedName(int yaw, int knick, int pitch, bool night) =>
      'art-${widget.truckModel.id}-p$pitch-y$yaw-k$knick-${night ? 'n' : 'd'}';

  Map<String, dynamic>? _articulatedProps(TourPosition pos) {
    final pose = _pose = articulate(widget.path, pos.meters, metersPerUnit: _unitAt(pos.point));
    // Bild nach Winkel der Zugmaschine zur Blickrichtung und Knick (mit
    // Hysterese gegen Flackern), Neigung wie die Kamera.
    _yawFrame = frameFor(angleDiff(_cameraBearing, pose.tractorHeading), _yawFrame, step: 4);
    _knickFrame = frameFor(pose.knick, _knickFrame, step: 3);
    final pitch = ((_cameraPitch / 5).round() * 5).clamp(30, 60);
    final night = _night > 0.5;
    final name = _articulatedName(_yawFrame, _knickFrame, pitch, night);
    if (!_framesReady.contains(name) && !_framesPending.contains(name)) {
      _framesPending.add(name);
      truckArticulatedPng(widget.truckModel,
              tractorYaw: _yawFrame * 4.0,
              knick: _knickFrame * 3.0,
              pitchDeg: pitch.toDouble(),
              pxPerMeter: _spritePx,
              night: night)
          .then((png) async {
        await _map?.addImage(name, png);
        _framesPending.remove(name);
        _framesReady.add(name);
      });
    }
    if (_framesReady.contains(name)) _shownFrame = name;
    final shown = _shownFrame;
    if (shown == null) return null;
    // Größe skaliert mit dem Kamerazoom – der LKW gehört zur Karte.
    final size = _pointsPerMeter / _spritePx * math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
    return {'icon': shown, 'rot': 0.0, 'flat': false, 'size': size};
  }

  Map<String, dynamic> _truckProps(double heading) {
    final relative = angleDiff(_cameraBearing, heading); // zur Blickrichtung
    if (widget.finished) {
      // Übersicht von oben am Ziel: flach.
      return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3};
    }
    switch (widget.truckView) {
      case TruckView.articulated:
        // Wird über [_articulatedProps] gesetzt (eigener Ankerpunkt).
        return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3};
      case TruckView.top:
        return {'icon': 'truck-top', 'rot': heading, 'flat': true, 'size': 0.3}; // Kartenrichtung
      case TruckView.threeQuarterLeft:
      case TruckView.threeQuarterRight:
      case TruckView.threeQuarterAuto:
        final TruckSide side;
        if (widget.truckView == TruckView.threeQuarterAuto) {
          side = _sideChooser.update(relative, _dt);
        } else {
          side = widget.truckView == TruckView.threeQuarterLeft ? TruckSide.left : TruckSide.right;
        }
        final target = biasFor(side, widget.truckBias);
        _bias = _bias == null ? target : easeBias(_bias!, target, _dt);
        _frame = frameFor(relative + _bias!, _frame, step: _frameStep);
        _ensureFrame(_frame);
        final name = _frameName(_frame);
        if (_framesReady.contains(name)) _shownFrame = name;
        // Solange das neue Bild entsteht, bleibt das vorige stehen.
        final icon = _shownFrame ?? 'truck-top';
        return {
          'icon': icon,
          'rot': _shownFrame == null ? heading : 0.0,
          'flat': _shownFrame == null,
          'size': _shownFrame == null ? 0.3 : 0.5 * widget.truckScale,
        };
      case TruckView.rear:
        // Fährt die Kamera hinterher (Regelfall), zeigt sie das Heck; leichte
        // Neigung in Kurven. Bei starker Abweichung seitlich.
        if (relative.abs() <= 50) {
          return {'icon': 'truck-rear', 'rot': relative * 0.35, 'flat': false, 'size': 0.32};
        }
        continue side;
      side:
      case TruckView.side:
        final pose = truckPose(relative);
        return {
          'icon': pose.mirrored ? 'truck-mirrored' : 'truck',
          'rot': pose.radians * 180 / math.pi,
          'flat': false,
          'size': 0.55,
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
      _cam?.reset();
      _daylight.reset();
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
    _dt = dt;
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
      // Regie: Folgekamera plus festgelegte Fahrten um den LKW – alles relativ
      // zur aktuellen Fahrzeugposition; manueller Zoom schaltet sie ab.
      final cam = _cam ?? _cameraFor(const Size(1000, 700));
      final st = _camState = cam.step(pos.meters, dt, manualZoom: widget.manualZoom);
      _cameraBearing = st.bearing;
      _cameraZoom = st.zoom;
      _cameraPitch = st.pitch;
      map.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(
        target: _ml(st.target),
        zoom: st.zoom,
        bearing: st.bearing,
        tilt: st.pitch,
      )));
    }

    // Tag/Nacht: Sonnenstand an der Fahrzeugposition zur Planzeit (lokal).
    if (widget.dayNight != DayNightMode.off) {
      final p = widget.path.totalMeters <= 0 ? 0.0 : pos.meters / widget.path.totalMeters;
      final DateTime? when = switch (widget.dayNight) {
        DayNightMode.plan => _clock?.at(pos.meters).toUtc(),
        DayNightMode.simulated =>
          DateTime.utc(2026, 10, 5, 13).add(Duration(minutes: (24 * 60 * p).round())),
        DayNightMode.off => null,
      };
      final target = when == null ? 0.0 : nightLevel(sunElevation(pos.point.latitude, pos.point.longitude, when));
      _night = widget.finished ? 0 : _daylight.update(target, dt);
      if ((_night - _shownVeil).abs() > 0.004) {
        _shownVeil = _night;
        map.setLayerProperties('night-veil', ml.FillLayerProperties(fillOpacity: 0.55 * _night));
        map.setLayerProperties('headlight-cone', ml.SymbolLayerProperties(iconOpacity: _night));
      }
    }

    if (widget.truckView == TruckView.articulated && !widget.finished) {
      final props = _articulatedProps(pos);
      final pose = _pose!;
      map.setGeoJsonSource('truck', _collection([
        props == null
            ? _point(pos.point, {'icon': 'truck-top', 'rot': pose.tractorHeading, 'flat': true, 'size': 0.3})
            : _point(pose.kingpin, props),
      ]));
      if (widget.dayNight != DayNightMode.off) {
        // Kegel an der Fahrzeugfront, so lang wie ≈ 2 Zugmaschinen.
        final coneSize = _pointsPerMeter * 9 / 320 * math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
        map.setGeoJsonSource('lights', _collection([
          _point(pose.frontAxle, {'rot': pose.tractorHeading, 'size': coneSize}),
        ]));
      }
    } else {
      map.setGeoJsonSource('truck', _collection([_point(pos.point, _truckProps(_localHeading(pos.meters)))]));
    }

    // Gefahrene Spur: höchstens etwa 12-mal pro Sekunde neu.
    if (force || widget.finished || now.difference(_lastTrail).inMilliseconds > 80) {
      _lastTrail = now;
      map.setGeoJsonSource('driven', _collection(_drivenFeatures(pos)));
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
    _cameraFor(MediaQuery.sizeOf(context));
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
      if (widget.cameraDebug && _camState != null)
        Positioned(
          left: 12,
          bottom: 40,
          child: IgnorePointer(
            child: Container(
              key: const Key('camera-debug'),
              padding: const EdgeInsets.all(8),
              color: const Color(0xCC000000),
              child: Text(
                'Shot ${_camState!.shot}\n'
                'Bahn ${_camState!.orbit.toStringAsFixed(0)}°  Richtung ${_camState!.bearing.toStringAsFixed(0)}°\n'
                'Neigung ${_camState!.pitch.toStringAsFixed(0)}°  Zoom ${_camState!.zoom.toStringAsFixed(2)}\n'
                'Knick ${(_pose?.knick ?? 0).toStringAsFixed(1)}°  Nacht ${(_night * 100).round()} %',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
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
