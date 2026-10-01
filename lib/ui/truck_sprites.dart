import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Wie das Fahrzeug in der geneigten (2.5D) Karte gezeigt wird.
enum TruckView {
  /// Von oben, flach auf der Karte: dreht und neigt sich mit der Karte und
  /// liegt dadurch perspektivisch richtig auf der Straße.
  top,

  /// Schräg von hinten (Heck), aufrecht zum Betrachter – „Verfolgerkamera“.
  rear,

  /// Seitlich, wie in 2D (bisheriges Symbol).
  side,
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
