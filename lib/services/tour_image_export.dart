import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class TourImageExport {
  static const double _maxDimension = 8000;
  static const double _maxPixels = 12000000;

  static Future<Uint8List> capture(GlobalKey boundaryKey) async {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw StateError('Die Tourgrafik ist noch nicht bereit.');
    }
    if (renderObject.size.isEmpty) {
      throw StateError('Die Tourgrafik hat keine gültige Größe.');
    }

    final pixelRatio = recommendedPixelRatio(renderObject.size);

    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Die Tourgrafik konnte nicht erzeugt werden.');
      }
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static double recommendedPixelRatio(Size size) {
    if (size.isEmpty) return 1;
    final width = size.width;
    final height = size.height;
    var pixelRatio = 2.0;
    pixelRatio = math.min(pixelRatio, _maxDimension / width);
    pixelRatio = math.min(pixelRatio, _maxDimension / height);
    pixelRatio = math.min(
      pixelRatio,
      math.sqrt(_maxPixels / (width * height)),
    );
    return pixelRatio;
  }
}
