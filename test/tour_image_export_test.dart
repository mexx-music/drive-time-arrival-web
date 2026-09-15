import 'package:driverroute_eta/services/tour_image_export.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Grafikexport nutzt für normale Touren doppelte Auflösung', () {
    expect(
      TourImageExport.recommendedPixelRatio(const Size(600, 3000)),
      2,
    );
  });

  test('Grafikexport begrenzt sehr lange Touren auf sichere Bildgrößen', () {
    final ratio = TourImageExport.recommendedPixelRatio(const Size(600, 12000));

    expect(ratio, lessThan(1));
    expect(12000 * ratio, lessThanOrEqualTo(8000));
  });
}
