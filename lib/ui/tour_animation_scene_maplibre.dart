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
import '../animation/ferry_cinematic.dart';
import '../animation/ship_model.dart';
import '../animation/tour_camera.dart';
import '../logic/eta_calculator.dart';
import '../animation/tour_path.dart';
import '../animation/tour_motion.dart';
import '../animation/tour_outro.dart';
import '../animation/tour_story.dart';
import 'map_label_style.dart';
import 'tour_animation_view.dart' show tourKmLabel;
import 'ship_sprites.dart';
import 'tour_outro_overlay.dart';
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
    this.onUnavailable,
    this.outro,
    this.outroTimeline,
    this.outroTime,
    this.cinematicPlan,
    this.cinematicHeading,
    this.frameDt,
    this.onPendingProbe,
    this.heroPhoto,
    this.heroCutout,
  });

  /// Test/Export: freigestellter Hero-Lkw im Outro.
  final String? heroCutout;

  /// Test/Export: echtes Foto des Lkw im Outro.
  final String? heroPhoto;

  /// Videoexport: fester Bildtakt statt Uhrzeit (deterministisch).
  final Duration? frameDt;

  /// Videoexport: meldet eine Abfrage „wie viele Bilder entstehen noch“.
  final void Function(int Function() pending)? onPendingProbe;

  /// Filmische Richtungsstabilisierung des Sattelzugs (null = Fahrspur ohne).
  final CinematicHeading? cinematicHeading;

  /// Kameraregie passend zum Filmtempo (siehe [cinematicMotionFor]); null =
  /// Regie wie bisher aus der Fahrdauer.
  final CinematicPlan? cinematicPlan;

  /// Cinematic-Outro: Daten der fertigen Tour; null = bisherige Abschlusskarte.
  final OutroData? outro;
  final OutroTimeline? outroTimeline;

  /// Outro-Zeit in Sekunden ab Ankunft; null vor der Ankunft.
  final double? outroTime;

  /// Vektorkarte (Stil) nicht erreichbar – die Ansicht fällt auf 2D zurück.
  final VoidCallback? onUnavailable;

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
            : widget.cinematicPlan != null
            ? widget.cinematicPlan!
            // Mit Fähre: Straßen-Regie plus Fährablauf; ohne Fähre unverändert.
            : ferryAwarePlan(
                widget.cinematicDemo
                    ? CinematicPlan.demo()
                    : CinematicPlan.standard(tourAnimationDuration(widget.path.totalMeters)),
                widget.path,
                tourAnimationDuration(widget.path.totalMeters)),
        aspect: size.height <= 0 ? 1.6 : size.width / size.height,
        zoomOffset: widget.cinematicPlan != null ? cinematicCameraZoomOffset : 0,
      );
  /// Fährabschnitte der Tour (leer: Tour ohne Fähre – alles wie bisher).
  late final List<FerryCrossing> _crossings = ferryCrossings(widget.path);
  VehicleMix? _mix;
  int _shipYawFrame = 0;
  String? _shownShip;
  bool _shipVisible = false;

  // ------------------------------------------------------------- Outro

  /// Outro läuft (Ziel erreicht, Cinematic-Ansicht).
  bool get _inOutro => widget.outro != null && widget.outroTimeline != null && widget.outroTime != null;

  /// Bisheriges Ende (Übersicht von oben) nur ohne Outro.
  bool get _endOverview => widget.finished && widget.outro == null;

  OutroCamera? _outroCam;
  OutroLights? _outroLights;
  bool _outroPrewarmed = false;
  double _shownCone = -1;
  double _shownOutroVeil = -1;

  /// Auflösung der Fahrzeugbilder im Outro (näher dran → schärfer).
  static const _outroSpritePx = 24.0;

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
    await map.addFillLayer('veil', 'night-veil', _veilProps(0));
    await map.addImage('headlights', await headlightConePng());
    // Outro: Umgebung ruhiger und dunkler (nie schwarz), Ziel bleibt erkennbar.
    await map.addFillLayer('veil', 'outro-veil', _outroVeilProps(0));

    await map.addGeoJsonSource('country', _collection(const []));
    await map.addFillLayer('country', 'country-fill', _countryFillProps(0));
    await map.addLineLayer('country', 'country-line', _countryLineProps(0));

    // Die ganze Route mit ALLEN Punkten der Berechnung (Etappen-Geometrie),
    // nicht ausgedünnt – MapLibre vereinfacht je Zoomstufe selbst passend.
    await map.addGeoJsonSource('route', _collection([
      for (final leg in path.legs) _line(leg.points, {'ferry': leg.kind != TourLegKind.road}),
    ]));
    // Cinematic: keine Vorschau der Strecke – nur die Spur, die der Lkw
    // hinter sich herzieht (wie ein Roadmovie, die Reise entsteht).
    await map.addLineLayer('route', 'route-line', ml.LineLayerProperties(
      lineColor: const ['case', ['get', 'ferry'], '#26A69A', '#3F51B5'],
      lineOpacity: widget.cinematicHeading != null ? 0.0 : 0.45,
      lineWidth: 5,
      lineCap: 'round',
      lineJoin: 'round',
    ));
    await map.addGeoJsonSource('driven', _collection(const []));
    await map.addLineLayer('driven', 'driven-glow', _drivenGlowProps(0));
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
        // Deckkraft je Feature (Überblendung LKW ↔ Fähre), sonst voll.
        iconOpacity: ['coalesce', ['get', 'op'], 1],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      ), filter: ['==', ['get', 'flat'], flat]);
    }
    // Fähre: aufrecht zum Betrachter wie der Sattelzug, über ihm.
    await map.addGeoJsonSource('ship', _collection(const []));
    await map.addSymbolLayer('ship', 'ship-upright', const ml.SymbolLayerProperties(
      iconImage: ['get', 'icon'],
      iconSize: ['get', 'size'],
      iconRotationAlignment: 'viewport',
      iconPitchAlignment: 'viewport',
      iconOpacity: ['get', 'op'],
      iconAllowOverlap: true,
      iconIgnorePlacement: true,
    ));
    // Lichtkegel: flach auf der Straße, gedreht mit der ZUGMASCHINE (nicht mit
    // der Kamera) – unter dem Fahrzeug.
    await map.addGeoJsonSource('lights', _collection(const []));
    await map.addSymbolLayer('lights', 'headlight-cone', _coneProps(0), belowLayerId: 'truck-flat');
    _ready = true;
    widget.onPendingProbe?.call(() => _framesPending.length);
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

  /// In der Normalfahrt kleiner (62 % des bisherigen Symbols): der LKW fügt
  /// sich in die Karte, Route und Landschaft bekommen Raum. Nah wird er nur,
  /// wenn die Kamera in einem Shot heranfährt (Zoom), nie durch Vergrößern.
  static const followSize = 0.62;
  double get _pointsPerMeter => 5 * widget.truckScale * followSize;

  /// Kartenmeter je Fahrzeugmeter – aus dem FOLGE-Zoom, nicht aus dem Zoom
  /// der aktuellen Kamerafahrt: die Kamera verändert die Fahrzeuggeometrie nie.
  /// Fahrzeugpose: im Cinematic-Filmtempo mit Trägheit ([ArticulatedTrack],
  /// einmal je Tour berechnet), sonst wie bisher. Hängt nur von der
  /// Streckenposition ab – nie von der Kamera.
  ArticulatedPose _poseAt(double meters) {
    final unit = _unitAt(widget.path.at(meters).point);
    if (widget.cinematicPlan == null) return articulate(widget.path, meters, metersPerUnit: unit);
    final heading = widget.cinematicHeading;
    if (heading != null) return heading.pose(meters, metersPerUnit: unit);
    final track = _track ??= ArticulatedTrack(widget.path, unitAt: _unitAt, inertia: cinematicTruckInertia);
    return track.pose(meters, metersPerUnit: unit);
  }

  ArticulatedTrack? _track;

  double _unitAt(LatLng p) =>
      _pointsPerMeter * metersPerScreenPoint(_cam?.followZoom ?? _rig.zoom, p.latitude);

  int _yawFrame = 0, _knickFrame = 0;
  double _shownFramePx = _spritePx;

  String _articulatedName(int yaw, int knick, int pitch, double night) =>
      'art-${widget.truckModel.id}-p$pitch-y$yaw-k$knick-n${(night * 8).round()}';

  /// Fahrzeugbild anfordern (einmal erzeugen und behalten); liefert den Namen.
  String _requestArticulated(int yaw, int knick, int pitch, double night, OutroLights? lights) {
    final name = _articulatedName(yaw, knick, pitch, night) + (lights == null ? '' : '-o${lights.key}');
    // Im Outro höchstens zwei Bilder gleichzeitig erzeugen – viele parallel
    // blockierten die Seite (gemessen mehrere Sekunden); bis dahin zeigt die
    // Szene das nächstliegende fertige Bild.
    // Normale Fahrbilder nie bremsen – sonst springt der Lkw beim Zielanflug.
    final busy = widget.outro != null && _framesPending.length >= 2 && (lights != null || _inOutro);
    if (!_framesReady.contains(name) && !_framesPending.contains(name) && !busy) {
      _framesPending.add(name);
      truckArticulatedPng(widget.truckModel,
              tractorYaw: yaw * 4.0,
              knick: knick * 3.0,
              pitchDeg: pitch.toDouble(),
              pxPerMeter: lights == null ? _spritePx : _outroSpritePx,
              night: night,
              tailLights: lights == null ? null : math.max(lights.tail, night),
              headLights: lights == null ? null : math.max(lights.head, night),
              sweep: lights?.sweep)
          .then((png) async {
        await _map?.addImage(name, png);
        _framesPending.remove(name);
        _framesReady.add(name);
        (_readyYaws[_poseKey(knick, pitch, night, lights)] ??= {})[yaw] = name;
      });
    }
    return name;
  }

  /// Fertige Bilder je Pose ohne Gierwinkel – für den nächstliegenden Ersatz.
  final Map<String, Map<int, String>> _readyYaws = {};
  String _poseKey(int knick, int pitch, double night, OutroLights? lights) =>
      'k$knick-p$pitch-n${(night * 8).round()}-${lights?.key}';

  /// Nächstliegendes fertiges Bild derselben Pose (Gierwinkel), sonst null.
  String? _nearestReady(int yaw, int knick, int pitch, double night, OutroLights? lights) {
    final m = _readyYaws[_poseKey(knick, pitch, night, lights)];
    if (m == null || m.isEmpty) return null;
    var best = m.keys.first;
    int dist(int a) => ((a - yaw) % 90 + 90) % 90 > 45 ? 90 - ((a - yaw) % 90 + 90) % 90 : ((a - yaw) % 90 + 90) % 90;
    for (final k in m.keys) {
      if (dist(k) < dist(best)) best = k;
    }
    return m[best];
  }

  /// Zu Beginn des Outros die Bilder des Licht-Reveals (Endperspektive)
  /// vorbereiten, damit sie bereitliegen, wenn das Licht angeht.
  void _prewarmOutro(OutroCamera oc, OutroTimeline tl, ArticulatedPose pose) {
    final night = nightStep(_night);
    final seen = <String>{};
    // Zuerst die Endperspektive (Ende des Schwenks und erstes Licht), dann
    // alles in zeitlicher Reihenfolge.
    for (final t in [tl.lightsOn - 0.25, tl.lightsOn, ...[for (var t = 0.0; t <= tl.end; t += 1 / 30) t]]) {
      final st = oc.at(t);
      final (yaw, pitch) = _outroFrame(angleDiff(st.bearing, pose.tractorHeading), st.pitch, t);
      final lights = t >= tl.lightsOn - 0.2 ? OutroLights.at(tl, t) : null;
      final key = '$yaw-$pitch-${lights?.key}';
      if (seen.add(key)) _prewarmQueue.add((yaw, (pose.knick / 3).round(), pitch, night, lights));
    }
  }

  /// Bildstufen im Outro: während des Schwenks gröber (8° Gier, 10°
  /// Neigung) – die Bewegung verdeckt es, und es braucht halb so viele Bilder.
  (int, int) _outroFrame(double yawDeg, double pitchDeg, double t) {
    return ((yawDeg / 4).round(), ((pitchDeg / 5).round() * 5).clamp(30, 60));
  }

  OutroCamera _makeOutroCamera(OutroTimeline tl) {
    final cam = _cam ?? _cameraFor(const Size(1000, 700));
    final end = widget.path.totalMeters;
    final pose = _poseAt(end);
    final size = (context.findRenderObject() as RenderBox?)?.size ?? MediaQuery.sizeOf(context);
    return OutroCamera(
      // Exakt der letzte Zustand der Fahrt – kein Sprung.
      from: _camState ?? cam.step(end, Duration.zero),
      truck: pose.kingpin,
      heading: pose.tractorHeading,
      followZoom: cam.followZoom,
      truckPointsPerMeter: _pointsPerMeter,
      width: size.width,
      height: size.height,
      timeline: tl,
      routeSouthWest: _routeBounds.$1,
      routeNorthEast: _routeBounds.$2,
    );
  }

  /// Ausdehnung der ganzen Route (für die Übersicht am Ziel).
  late final (LatLng, LatLng) _routeBounds = () {
    final pts = widget.path.points;
    var s = pts.first.latitude, n = s, w = pts.first.longitude, e = w;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    return (LatLng(s, w), LatLng(n, e));
  }();

  double _shownGlowRoute = -1;

  /// Dezentes Aufleuchten der gefahrenen Strecke (Übersicht am Ziel).
  static ml.LineLayerProperties _drivenGlowProps(double opacity) => ml.LineLayerProperties(
        lineColor: '#DCEB4B',
        lineWidth: 14,
        lineBlur: 8,
        lineOpacity: opacity,
        lineCap: 'round',
        lineJoin: 'round',
      );

  /// Vorbereitete Outro-Bilder: höchstens eines je Bild anstoßen – alle auf
  /// einmal blockierten die Seite gemessen mehrere Sekunden.
  final List<(int, int, int, double, OutroLights?)> _prewarmQueue = [];

  Map<String, dynamic>? _articulatedProps(TourPosition pos) {
    final pose = _pose = _poseAt(pos.meters);
    // Bild nach Winkel der Zugmaschine zur Blickrichtung und Knick (mit
    // Hysterese gegen Flackern), Neigung wie die Kamera.
    _yawFrame = frameFor(angleDiff(_cameraBearing, pose.tractorHeading), _yawFrame, step: 4);
    _knickFrame = frameFor(pose.knick, _knickFrame, step: 3);
    final pitch = ((_cameraPitch / 5).round() * 5).clamp(30, 60);
    // Nacht in Achtelstufen: Scheibe, Karosserie, Lichter gleitend.
    final night = nightStep(_night);
    // Outro: während des Kameraschwenks normale Bilder (sie müssen schnell
    // folgen), ab dem Licht-Reveal scharfe Bilder mit Lichtzustand.
    final lights = _inOutro && widget.outroTime! >= widget.outroTimeline!.lightsOn - 0.2 ? _outroLights : null;
    final spritePx = lights == null ? _spritePx : _outroSpritePx;
    var yaw = _yawFrame, pitchFrame = pitch;
    if (_inOutro) {
      (yaw, pitchFrame) = _outroFrame(angleDiff(_cameraBearing, pose.tractorHeading), _cameraPitch, widget.outroTime!);
    }
    final name = _requestArticulated(yaw, _knickFrame, pitchFrame, night, lights);
    if (_framesReady.contains(name)) {
      _shownFrame = name;
      _shownFramePx = spritePx;
    } else if (_inOutro) {
      // Im Outro lieber das nächstliegende fertige Bild als ein veraltetes.
      final near = _nearestReady(yaw, _knickFrame, pitchFrame, night, lights);
      if (near != null) {
        _shownFrame = near;
        _shownFramePx = spritePx;
      }
    }
    final shown = _shownFrame;
    if (shown == null) return null;
    // Größe skaliert mit dem Kamerazoom – der LKW gehört zur Karte.
    final size = _pointsPerMeter / _shownFramePx * math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
    // Zwischen zwei Bildstufen (4°) dreht die Karte weich weiter, das Bild
    // nicht – bei großem Lkw wirkte das wie Zittern. Den Rest zur echten
    // Richtung als Bilddrehung ausgleichen.
    final m = RegExp(r'-y(-?\d+)-').firstMatch(shown);
    final shownYaw = m == null ? 0.0 : int.parse(m.group(1)!) * 4.0;
    final residual = angleDiff(shownYaw, angleDiff(_cameraBearing, pose.tractorHeading)).clamp(-6.0, 6.0);
    return {'icon': shown, 'rot': residual, 'flat': false, 'size': size};
  }

  /// Fähre an ihrer Stelle: Bild nach Kurs zur Blickrichtung, Neigung und
  /// Nachtstufe (bei Bedarf erzeugt und behalten), Größe wie der LKW über
  /// den Kamerazoom.
  void _updateShip(ml.MapLibreMapController map, VehicleMix? mix) {
    if (mix == null || mix.ship <= 0.001) {
      if (_shipVisible) {
        _shipVisible = false;
        map.setGeoJsonSource('ship', _collection(const []));
      }
      return;
    }
    final heading = shipHeading(widget.path, mix.crossing!, mix.shipMeters);
    _shipYawFrame = frameFor(angleDiff(_cameraBearing, heading), _shipYawFrame, step: 4);
    final pitch = ((_cameraPitch / 5).round() * 5).clamp(20, 60);
    final night = nightStep(_night);
    final name = 'ship-p$pitch-y$_shipYawFrame-n${(night * 8).round()}';
    if (!_framesReady.contains(name) && !_framesPending.contains(name)) {
      _framesPending.add(name);
      ferryShipPng(yawDeg: _shipYawFrame * 4.0, pitchDeg: pitch.toDouble(), night: night).then((png) async {
        await _map?.addImage(name, png);
        _framesPending.remove(name);
        _framesReady.add(name);
      });
    }
    if (_framesReady.contains(name)) _shownShip = name;
    final shown = _shownShip;
    if (shown == null) return;
    final size = shipPointsPerMeter(_pointsPerMeter, FerryShipModel.length) /
        shipSpritePx *
        math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
    _shipVisible = true;
    map.setGeoJsonSource('ship', _collection([
      _point(widget.path.at(mix.shipMeters).point, {'icon': shown, 'size': size, 'op': mix.ship}),
    ]));
  }

  Map<String, dynamic> _truckProps(double heading) {
    final relative = angleDiff(_cameraBearing, heading); // zur Blickrichtung
    if (_endOverview) {
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

  // ------------------------------------------------------ Ebenen-Eigenschaften
  //
  // Immer VOLLSTÄNDIG übergeben: maplibre_gl schickt bei setLayerProperties
  // alle nicht gesetzten Eigenschaften als null mit und setzt sie damit auf
  // den Standard zurück (Bild, Größe, Farbe …). Nur die Deckkraft zu setzen,
  // hatte Lichtkegel, Länderfarbe und Nachtblau gelöscht.

  double _shownGlow = -1;

  static ml.FillLayerProperties _outroVeilProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#06120C', fillOpacity: opacity);

  static ml.FillLayerProperties _veilProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#0B1730', fillOpacity: opacity);

  static ml.FillLayerProperties _countryFillProps(double opacity) =>
      ml.FillLayerProperties(fillColor: '#1565C0', fillOpacity: opacity);

  static ml.LineLayerProperties _countryLineProps(double opacity) =>
      ml.LineLayerProperties(lineColor: '#1565C0', lineWidth: 2, lineOpacity: opacity);

  /// Lichtkegel: flach auf der Straße, gedreht mit der Zugmaschine.
  static ml.SymbolLayerProperties _coneProps(double opacity) => ml.SymbolLayerProperties(
        iconImage: 'headlights',
        iconSize: ['get', 'size'],
        iconRotate: ['get', 'rot'],
        iconRotationAlignment: 'map',
        iconPitchAlignment: 'map',
        iconAnchor: 'bottom',
        // Mit dem LKW ausgeblendet, wenn er am Hafen der Fähre Platz macht.
        iconOpacity: ['*', opacity, ['coalesce', ['get', 'op'], 1]],
        iconAllowOverlap: true,
        iconIgnorePlacement: true,
      );

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
      _outroCam = null;
      _outroPrewarmed = false;
      _prewarmQueue.clear();
    }
    _update();
  }

  void _update({bool force = false}) {
    final map = _map;
    if (!_ready || map == null) return;
    final now = DateTime.now();
    final fixed = widget.frameDt;
    final dt = fixed != null
        ? (_lastFrame == null ? Duration.zero : fixed)
        : (_lastFrame == null ? Duration.zero : now.difference(_lastFrame!));
    _lastFrame = now;
    _dt = dt;
    final pos = widget.position;

    // Kamera: ruhig in Fahrtrichtung, am Ziel Übersicht von oben – oder
    // das Cinematic-Outro.
    if (!_inOutro) _outroCam = null;
    // Outro-Bilder vorbereiten: schon beim Heranfahren ans Ziel (letzte
    // ≈ 5 % der Strecke), je Bild höchstens eines.
    if (_prewarmQueue.isNotEmpty && _framesPending.isEmpty) {
      final (y, k, p, n, l) = _prewarmQueue.removeAt(0);
      _requestArticulated(y, k, p, n, l);
    }
    final outroTl = widget.outroTimeline;
    if (widget.outro != null && outroTl != null && !_outroPrewarmed &&
        (_inOutro || pos.meters >= widget.path.totalMeters * 0.95)) {
      _outroPrewarmed = true;
      final end = widget.path.totalMeters;
      _prewarmOutro(_makeOutroCamera(outroTl), outroTl,
          _poseAt(end));
    }
    if (_inOutro) {
      final tl = widget.outroTimeline!;
      final t = widget.outroTime!;
      _outroLights = OutroLights.at(tl, t);
      final oc = _outroCam ??= _makeOutroCamera(tl);
      final glow = 0.7 * tl.routeGlow(t);
      if ((glow - _shownGlowRoute).abs() > 0.01 || (glow == 0 && _shownGlowRoute != 0)) {
        _shownGlowRoute = glow;
        map.setLayerProperties('driven-glow', _drivenGlowProps(glow));
      }
      final st = _camState = oc.at(t);
      _cameraBearing = st.bearing;
      _cameraZoom = st.zoom;
      _cameraPitch = st.pitch;
      map.moveCamera(ml.CameraUpdate.newCameraPosition(ml.CameraPosition(
        target: _ml(st.target),
        zoom: st.zoom,
        bearing: st.bearing,
        tilt: st.pitch,
      )));
      // Nachts ist es schon dunkel – dann weniger zusätzlich abdunkeln.
      final veil = 0.42 * tl.dim(t) * (1 - 0.6 * _night);
      if ((veil - _shownOutroVeil).abs() > 0.004) {
        _shownOutroVeil = veil;
        map.setLayerProperties('outro-veil', _outroVeilProps(veil));
      }
    } else if (_endOverview) {
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
      _night = _endOverview ? 0 : _daylight.update(target, dt);
      if ((_night - _shownVeil).abs() > 0.004) {
        _shownVeil = _night;
        map.setLayerProperties('night-veil', _veilProps(0.55 * _night));
      }
    }
    // Lichtkegel: nachts nach Dunkelheit, im Outro zusätzlich mit dem
    // Einschalten der Scheinwerfer.
    final cone = math.max(widget.dayNight == DayNightMode.off ? 0.0 : headlightOpacity(_night),
        _inOutro ? 0.85 * widget.outroTimeline!.headLights(widget.outroTime!) : 0.0);
    if ((cone - _shownCone).abs() > 0.004) {
      _shownCone = cone;
      map.setLayerProperties('headlight-cone', _coneProps(cone));
    }

    if (widget.truckView == TruckView.articulated && !_endOverview) {
      // Fähre: LKW hält am Hafen und blendet aus, die Fähre übernimmt – und
      // am Zielhafen umgekehrt. Ohne Fähre ist mix null und alles wie bisher.
      final mix = _mix = _crossings.isEmpty ? null : vehicleAt(widget.path, _crossings, pos.meters);
      final truckPos = mix == null || mix.truckMeters == pos.meters ? pos : widget.path.at(mix.truckMeters);
      // Mit freigestelltem Hero-Bild: Modell gleichzeitig ausblenden.
      final cutFade = widget.heroCutout != null && _inOutro ? widget.outroTimeline!.photo(widget.outroTime!) : 0.0;
      final truckOp = (mix?.truck ?? 1.0) * (1 - cutFade);
      final props = _articulatedProps(truckPos);
      final pose = _pose!;
      map.setGeoJsonSource('truck', _collection([
        if (truckOp > 0.001)
          props == null
              ? _point(truckPos.point, {
                  'icon': 'truck-top', 'rot': pose.tractorHeading, 'flat': true, 'size': 0.3,
                  if (mix != null) 'op': truckOp,
                })
              : _point(pose.kingpin, {...props, if (mix != null || cutFade > 0) 'op': truckOp}),
      ]));
      if (_shownCone > 0.01) {
        // Abblendlicht ab der Kabinenfront, headlightConeMeters Fahrzeugmeter
        // lang, gedreht mit der Zugmaschine; wächst wie der LKW mit dem
        // Kamerazoom.
        final unit = _unitAt(truckPos.point);
        final light = headlightPlacement(pose, metersPerUnit: unit);
        final scale = math.pow(2, _cameraZoom - (_cam?.followZoom ?? _rig.zoom));
        final coneSize = headlightConeMeters * _pointsPerMeter * scale / headlightConeSize.height;
        map.setGeoJsonSource('lights', _collection([
          if (truckOp > 0.001)
            _point(light.apex, {'rot': light.heading, 'size': coneSize, if (mix != null) 'op': truckOp}),
        ]));
      }
      _updateShip(map, mix);
    } else {
      map.setGeoJsonSource('truck', _collection([_point(pos.point, _truckProps(_localHeading(pos.meters)))]));
    }

    // Gefahrene Spur: höchstens etwa 12-mal pro Sekunde neu.
    if (force || widget.finished || fixed != null || now.difference(_lastTrail).inMilliseconds > 80) {
      _lastTrail = now;
      // Cinematic: die Spur endet an der Achsgruppe des Aufliegers – der
      // Sattelzug zieht die Linie hinter sich her.
      final pose = _pose;
      final heading = widget.cinematicHeading;
      if (heading != null && heading.rearOnRoute && pose != null && _mix?.crossing == null) {
        // Heck klebt auf der (geglätteten) Darstellungslinie: die Spur ist
        // genau diese Linie bis zum Heck – im Outro die ganze Strecke.
        final u = _unitAt(pos.point);
        final dp = heading.displayPath;
        final upTo = _inOutro ? dp.totalMeters : heading.rearMetersAt(pos.meters, pose.kingpin, u);
        map.setGeoJsonSource('driven', _collection([
          for (final t in dp.trailUpTo(upTo)) _line(t.points, {'ferry': t.kind != TourLegKind.road}),
        ]));
      } else if (widget.cinematicHeading != null && cinematicTrailRearDefine && pose != null && _mix?.crossing == null) {
        final u = _unitAt(pos.point);
        final back = (pos.meters - 14.0 * u).clamp(0.0, widget.path.totalMeters);
        final features = _drivenFeatures(widget.path.at(back));
        if (features.isNotEmpty) {
          final last = features.last;
          final coords = (last['geometry'] as Map)['coordinates'] as List;
          coords.add([pose.trailerAxle.longitude, pose.trailerAxle.latitude]);
        }
        map.setGeoJsonSource('driven', _collection(features));
      } else {
        map.setGeoJsonSource('driven', _collection(_drivenFeatures(pos)));
      }
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
    if ((glow - _shownGlow).abs() > 0.004 || (glow == 0 && _shownGlow != 0)) {
      _shownGlow = glow;
      map.setLayerProperties('country-fill', _countryFillProps(0.16 * glow));
      map.setLayerProperties('country-line', _countryLineProps(0.75 * glow));
    }
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
              final fallback = widget.onUnavailable;
              if (fallback != null) WidgetsBinding.instance.addPostFrameCallback((_) => fallback());
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
          // Mit Outro ersetzt das Finale die bisherige Abschlusskarte.
          frame: widget.outro != null && frame.event?.kind == TourStoryKind.arrival
              ? TourFrame(meters: frame.meters)
              : frame,
          summary: widget.summary,
          fromName: widget.fromName,
          toName: widget.toName,
          countrySequence: storyCountrySequence(widget.storyEvents, startIso),
        ),
      ),
      if (_inOutro)
        Positioned.fill(
          child: TourOutroOverlay(
              data: widget.outro!,
              timeline: widget.outroTimeline!,
              t: widget.outroTime!,
              heroPhoto: widget.heroPhoto,
              heroCutout: widget.heroCutout),
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
                'Knick ${(_pose?.knick ?? 0).toStringAsFixed(1)}°  Nacht ${(_night * 100).round()} %'
                '${_mix == null ? '' : '\nFähre ${(_mix!.ship * 100).round()} %'}',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      Positioned(
        left: 12,
        right: 12,
        // Export: Sicherheitsabstand oben (Player-Leisten, Social-Media-UI).
        top: widget.frameDt != null ? MediaQuery.sizeOf(context).height * 0.065 : 12,
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
