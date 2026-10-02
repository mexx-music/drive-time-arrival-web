import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:driverroute_eta/animation/articulation.dart';
import 'package:driverroute_eta/animation/cinematic_camera.dart';
import 'package:driverroute_eta/animation/tour_path.dart';
import 'package:driverroute_eta/ui/truck_sprites.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// Mittlere Deckkraft (0..255) je Bildzeile-Band des Kegels.
Future<List<double>> _alphaBands(int bands) async {
  final codec = await ui.instantiateImageCodec(await headlightConePng());
  final img = (await codec.getNextFrame()).image;
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final w = img.width, h = img.height;
  return [
    for (var b = 0; b < bands; b++)
      () {
        var sum = 0;
        final y0 = h * b ~/ bands, y1 = h * (b + 1) ~/ bands;
        for (var y = y0; y < y1; y++) {
          for (var x = 0; x < w; x++) {
            sum += data.getUint8((y * w + x) * 4 + 3);
          }
        }
        return sum / ((y1 - y0) * w);
      }(),
  ];
}

void main() {
  group('Lichtkegel', () {
    test('deutlich sichtbar am Ansatz, weich nach vorn auslaufend', () async {
      final bands = await _alphaBands(8); // Band 0 = vorn (Fahrtrichtung), 7 = am LKW
      expect(bands[6], greaterThan(60)); // vorher höchstens ≈ 47 im ganzen Bild
      expect(bands[0], lessThan(bands[4])); // nach vorn dunkler
      expect(bands[4], lessThan(bands[6]));
      // Von vorn bis kurz vor die Front stetig heller, ohne Absatz; im
      // letzten Achtel laufen beide Felder an der Front zusammen (unter der
      // Kabine) – dort darf es schmaler, aber nicht dunkel sein.
      for (var i = 1; i < 7; i++) {
        expect(bands[i], greaterThanOrEqualTo(bands[i - 1] - 6), reason: '$bands');
      }
      expect(bands[7], greaterThan(40), reason: '$bands');
    });

    test('folgt ausschließlich der Zugmaschine – auch bei Knick', () {
      // 90°-Kurve: Zugmaschine schon herum, Auflieger noch schräg.
      final pts = <LatLng>[const LatLng(48, 14)];
      for (var i = 0; i < 300; i++) {
        pts.add(destination(pts.last, 20, 0));
      }
      for (var a = 0; a <= 90; a += 3) {
        pts.add(destination(pts.last, 20, a.toDouble()));
      }
      for (var i = 0; i < 300; i++) {
        pts.add(destination(pts.last, 20, 90));
      }
      final path = TourPath([TourLeg(points: pts)]);
      var sawKnick = false;
      for (var m = 100.0; m < path.totalMeters; m += 37) {
        final pose = articulate(path, m, metersPerUnit: 40);
        final light = headlightPlacement(pose, metersPerUnit: 40);
        expect(light.heading, pose.tractorHeading);
        if (pose.knick.abs() > 5) sawKnick = true;
        // Ansatz vor der Vorderachse, genau in Zugmaschinenrichtung.
        const d = Distance(calculator: Haversine());
        final dir = (d.bearing(pose.frontAxle, light.apex) + 360) % 360;
        expect((dir - pose.tractorHeading + 540) % 360 - 180, closeTo(0, 0.01));
        expect(d(pose.frontAxle, light.apex), closeTo(0.9 * 40, 0.05));
      }
      expect(sawKnick, isTrue);
    });
  });

  group('Frontscheibe nachts', () {
    test('gleitend dunkler, nie schwarz', () {
      double lum(Color c) => c.computeLuminance();
      expect(windshieldColor(0), const Color(0xFF90CAF9));
      var last = lum(windshieldColor(0));
      for (var i = 1; i <= 8; i++) {
        final l = lum(windshieldColor(i / 8));
        expect(l, lessThan(last));
        last = l;
      }
      expect(last, greaterThan(0.01)); // dunkles Blau-Anthrazit, nicht schwarz
      final night = windshieldColor(1);
      expect(night.b, greaterThan(night.r)); // bläulich
    });

    test('Nachtfaktor in Achtelstufen – kleine, gleichmäßige Schritte', () {
      expect(nightStep(0), 0);
      expect(nightStep(1), 1);
      expect(nightStep(0.49), 0.5);
      expect(nightStep(0.07), 0.125);
      expect(nightStep(-1), 0);
      expect(nightStep(2), 1);
    });
  });

  group('Fahrzeuggröße', () {
    test('Normalfahrt kleiner, Shots über die Kamera wieder wie bisher', () {
      const follow = 0.62; // TourAnimationSceneMapLibre.followSize
      final plan = CinematicPlan.standard(const Duration(seconds: 33));
      // bisher: PASS +0,55 Zoom bei Größe 1
      final before = 1.0 * math.pow(2, 0.55);
      final now = follow * math.pow(2, plan.at(0.29).zoom);
      expect(now / before, closeTo(1, 0.05));
      expect(plan.at(0.1).zoom, 0); // Normalfahrt: kein Heranzoomen
    });
  });
}
