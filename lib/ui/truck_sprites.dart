import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../animation/truck_projection.dart';

/// Wie das Fahrzeug in der geneigten (2.5D) Karte gezeigt wird.
enum TruckView {
  /// Von oben, flach auf der Karte: dreht und neigt sich mit der Karte und
  /// liegt dadurch perspektivisch richtig auf der Straße.
  top,

  /// Schräg von hinten (Heck), aufrecht zum Betrachter – „Verfolgerkamera“.
  rear,

  /// Seitlich, wie in 2D (bisheriges Symbol).
  side,

  /// 3/4 von oben, immer die linke Aufliegerseite sichtbar.
  threeQuarterLeft,

  /// 3/4 von oben, immer die rechte Aufliegerseite sichtbar.
  threeQuarterRight,

  /// 3/4 von oben, Seite automatisch nach Kurvenrichtung (mit Hysterese).
  threeQuarterAuto,
}

/// Farben – neutral, ohne Marke. Später austauschbar (Fahrzeugtyp, Firma).
const _cab = Color(0xFF0D47A1);
const _cabRoof = Color(0xFF1565C0);
const _trailer = Color(0xFFF5F7FA);
const _trailerEdge = Color(0xFF90A4AE);
const _shadow = Color(0x55000000);

Future<Uint8List> _png(Size size, void Function(Canvas c) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final image =
      await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

/// Sattelzug von oben, Fahrtrichtung nach oben (Norden des Bildes).
/// 72 × 200 Pixel; in der Karte etwa 20 × 56 Punkte groß.
Future<Uint8List> truckTopPng() => _png(const Size(72, 200), (c) {
      // weicher Schatten
      c.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(10, 14, 54, 180), const Radius.circular(10)),
        Paint()
          ..color = _shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      // Auflieger
      final trailer = RRect.fromRectAndRadius(
          const Rect.fromLTWH(8, 56, 56, 136), const Radius.circular(6));
      c.drawRRect(trailer, Paint()..color = _trailer);
      c.drawRRect(
          trailer,
          Paint()
            ..color = _trailerEdge
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      // Längsstreifen auf dem Dach des Aufliegers
      c.drawRect(const Rect.fromLTWH(30, 64, 12, 120), Paint()..color = const Color(0x221565C0));
      // Zugmaschine
      final cab = RRect.fromRectAndCorners(const Rect.fromLTWH(12, 6, 48, 44),
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: const Radius.circular(4),
          bottomRight: const Radius.circular(4));
      c.drawRRect(cab, Paint()..color = _cab);
      // Dach / Windschutz-Andeutung
      c.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(18, 18, 36, 24), const Radius.circular(5)),
          Paint()..color = _cabRoof);
      c.drawRect(const Rect.fromLTWH(16, 9, 40, 6), Paint()..color = const Color(0xFF90CAF9));
      // Spiegel
      final mirror = Paint()..color = _cab;
      c.drawRect(const Rect.fromLTWH(4, 14, 8, 4), mirror);
      c.drawRect(const Rect.fromLTWH(60, 14, 8, 4), mirror);
    });

/// Sattelzug schräg von hinten: Heck des Aufliegers mit Rückleuchten,
/// darüber die Kabine. 120 × 112 Pixel.
Future<Uint8List> truckRearPng() => _png(const Size(120, 112), (c) {
      c.drawOval(
        const Rect.fromLTWH(10, 92, 100, 16),
        Paint()
          ..color = _shadow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      // Kabine (leicht versetzt dahinter)
      c.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(30, 6, 60, 34), const Radius.circular(8)),
          Paint()..color = _cab);
      // Auflieger-Seite (Tiefe)
      final side = Path()
        ..moveTo(92, 22)
        ..lineTo(104, 30)
        ..lineTo(104, 92)
        ..lineTo(92, 96)
        ..close();
      c.drawPath(side, Paint()..color = const Color(0xFFCFD8DC));
      // Heck
      final back = RRect.fromRectAndRadius(
          const Rect.fromLTWH(16, 22, 78, 74), const Radius.circular(4));
      c.drawRRect(back, Paint()..color = _trailer);
      c.drawRRect(
          back,
          Paint()
            ..color = _trailerEdge
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3);
      // Türfuge und Verriegelung
      final line = Paint()
        ..color = _trailerEdge
        ..strokeWidth = 2;
      c.drawLine(const Offset(55, 26), const Offset(55, 92), line);
      c.drawLine(const Offset(40, 30), const Offset(40, 88), line);
      c.drawLine(const Offset(70, 30), const Offset(70, 88), line);
      // Rückleuchten und Stoßfänger
      c.drawRect(const Rect.fromLTWH(18, 84, 12, 6), Paint()..color = const Color(0xFFE53935));
      c.drawRect(const Rect.fromLTWH(80, 84, 12, 6), Paint()..color = const Color(0xFFE53935));
      c.drawRect(const Rect.fromLTWH(20, 96, 70, 4), Paint()..color = const Color(0xFF37474F));
      // Räder
      final wheel = Paint()..color = const Color(0xFF263238);
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 98, 18, 8), const Radius.circular(3)), wheel);
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(72, 98, 18, 8), const Radius.circular(3)), wheel);
    });

/// Seitlich wie in 2D: Lieferwagen-Symbol auf weißem Kreis.
Future<Uint8List> truckSidePng({required bool mirrored}) => _png(const Size(96, 96), (canvas) {
      const size = 96.0;
      const c = Offset(size / 2, size / 2);
      canvas.drawCircle(
          c + const Offset(0, 2),
          size / 2 - 6,
          Paint()
            ..color = Colors.black26
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
      canvas.drawCircle(c, size / 2 - 6, Paint()..color = Colors.white);
      if (mirrored) {
        canvas.translate(size, 0);
        canvas.scale(-1, 1);
      }
      const icon = Icons.local_shipping;
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: 56,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: _cab,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    });

// ------------------------------------------------------- 3/4-Ansicht (2.5D)

/// Aufliegertyp – getrennt vom Branding wählbar. (Tank folgt später.)
enum TrailerKind { box, curtain, reefer }

/// Farben und Beschriftung eines Fahrzeugs – getrennt vom Typ.
class TruckBranding {
  const TruckBranding({
    required this.id,
    this.sideText,
    this.cab = const Color(0xFF0D47A1),
    this.trailer = const Color(0xFFF5F7FA),
    this.text = const Color(0xFF1B2733),
  });

  final String id;

  /// Schriftzug auf beiden Aufliegerseiten; null = neutral.
  final String? sideText;
  final Color cab;
  final Color trailer;
  final Color text;

  static const neutral = TruckBranding(id: 'neutral');

  /// Testschriftzug zur Lesbarkeitsprüfung – KEIN echtes Firmen-Branding.
  static const gartnerTest = TruckBranding(id: 'gartner-test', sideText: 'GARTNER');
}

/// Fahrzeug = Typ + Branding.
class TruckModel {
  const TruckModel({this.trailer = TrailerKind.box, this.branding = TruckBranding.neutral});

  final TrailerKind trailer;
  final TruckBranding branding;

  String get id => '${trailer.name}-${branding.id}';

  List<TruckBox> get boxes => [
        ...standardTruck,
        if (trailer == TrailerKind.reefer)
          const TruckBox(name: 'reefer-unit', fromF: 5.4, toF: 5.8, halfWidth: 0.85, fromZ: 2.4, toZ: 3.6),
      ];
}

/// Sattelzug in 3/4-Ansicht für Gierwinkel [yawDeg] relativ zur Blickrichtung
/// und Kartenneigung [pitchDeg]. Bodenmitte des Zugs = Bildmitte, damit das
/// Symbol mit Anker „Mitte“ genau auf der Straße steht.
Future<Uint8List> truckThreeQuarterPng(
  TruckModel model, {
  required double yawDeg,
  double pitchDeg = 42,
  double pxPerMeter = 10,
}) {
  final proj = TruckProjection(pitchDeg: pitchDeg, yawDeg: yawDeg);
  final boxes = model.boxes;
  final faces = proj.visibleFaces(boxes);

  // Bildgröße: symmetrisch um die Bodenmitte.
  var ext = 0.0;
  for (final f in faces) {
    for (final c in f.corners) {
      ext = math.max(ext, math.max(c.x.abs(), c.y.abs()));
    }
  }
  final half = (ext * pxPerMeter).ceilToDouble() + 8;
  final size = Size(half * 2, half * 2);

  Offset px(ScreenPoint p) => Offset(half + p.x * pxPerMeter, half + p.y * pxPerMeter);

  return _png(size, (c) {
    // Schatten auf der Straße: Grundriss bei z = 0, weich.
    final shadow = Path();
    for (final b in boxes.where((b) => b.name != 'reefer-unit')) {
      final pts = [
        proj.world(b.toF, -b.halfWidth, 0),
        proj.world(b.toF, b.halfWidth, 0),
        proj.world(b.fromF, b.halfWidth, 0),
        proj.world(b.fromF, -b.halfWidth, 0),
      ].map((w) => px(proj.project(w))).toList();
      shadow.addPolygon(pts, true);
    }
    c.drawPath(
        shadow.shift(const Offset(1.5, 2)),
        Paint()
          ..color = const Color(0x55000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));

    for (final f in faces) {
      final base = switch (f.box.name) {
        'cab' => model.branding.cab,
        'trailer' => model.branding.trailer,
        'reefer-unit' => const Color(0xFFB0BEC5),
        _ => const Color(0xFF263238), // Fahrwerk
      };
      final color = Color.lerp(Colors.black, base, f.shade)!;
      final poly = Path()..addPolygon([for (final p in f.corners) px(p)], true);
      c.drawPath(poly, Paint()..color = color);
      c.drawPath(
          poly,
          Paint()
            ..color = const Color(0x33000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      if (f.box.name == 'trailer' && (f.side == FaceSide.left || f.side == FaceSide.right)) {
        _decorateSide(c, f, px, model);
      }
      if (f.box.name == 'cab' && f.side == FaceSide.front) {
        _windshield(c, f, px);
      }
    }
  });
}

/// Zeichnet auf eine Seitenfläche im Flächen-Koordinatensystem (u nach
/// rechts, v nach unten, je 0..1) – dadurch perspektivisch richtig und nie
/// gespiegelt (Ecken kommen in Leserichtung von außen).
void _inFace(Canvas c, ProjectedFace f, Offset Function(ScreenPoint) px, void Function(Canvas c) draw) {
  final o = px(f.corners[0]);
  final u = px(f.corners[1]) - o;
  final v = px(f.corners[3]) - o;
  c.save();
  c.transform(Float64List.fromList([
    u.dx, u.dy, 0, 0, //
    v.dx, v.dy, 0, 0, //
    0, 0, 1, 0, //
    o.dx, o.dy, 0, 1,
  ]));
  draw(c);
  c.restore();
}

void _decorateSide(Canvas c, ProjectedFace f, Offset Function(ScreenPoint) px, TruckModel model) {
  _inFace(c, f, px, (c) {
    if (model.trailer == TrailerKind.curtain) {
      final strap = Paint()
        ..color = const Color(0x22000000)
        ..strokeWidth = 0.004;
      for (var i = 1; i < 12; i++) {
        c.drawLine(Offset(i / 12, 0.02), Offset(i / 12, 0.98), strap);
      }
    }
    final text = model.branding.sideText;
    if (text == null) return;
    // Schrift in einem 1000 × 1000 Feld setzen und auf die Fläche skalieren.
    c.scale(1 / 1000, 1 / 1000);
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 520,
          fontWeight: FontWeight.w900,
          letterSpacing: 10,
          color: model.branding.text,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Breite füllt 84 % der Fläche, Höhe höchstens 60 %.
    final sx = 840 / tp.width;
    final sy = math.min(600 / tp.height, sx * 3.2);
    c.translate(80, 500 - tp.height * sy / 2);
    c.scale(sx, sy);
    tp.paint(c, Offset.zero);
  });
}

void _windshield(Canvas c, ProjectedFace f, Offset Function(ScreenPoint) px) {
  _inFace(c, f, px, (c) {
    c.drawRect(const Rect.fromLTWH(0.1, 0.12, 0.8, 0.32), Paint()..color = const Color(0xFF90CAF9));
  });
}
