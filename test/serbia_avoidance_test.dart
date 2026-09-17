import 'package:driverroute_eta/logic/serbia_avoidance.dart';
import 'package:driverroute_eta/services/map_launcher.dart' as map_launcher;
import 'package:flutter_test/flutter_test.dart';

String encodePolyline(List<(double, double)> points) {
  final output = StringBuffer();
  var oldLat = 0;
  var oldLng = 0;
  void append(int difference) {
    var value = difference < 0 ? ~(difference << 1) : difference << 1;
    while (value >= 0x20) {
      output.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    output.writeCharCode(value + 63);
  }

  for (final point in points) {
    final lat = (point.$1 * 1e5).round();
    final lng = (point.$2 * 1e5).round();
    append(lat - oldLat);
    append(lng - oldLng);
    oldLat = lat;
    oldLng = lng;
  }
  return output.toString();
}

Map<String, dynamic> responseFor(List<(double, double)> points) => {
      'routes': <Map<String, dynamic>>[
        <String, dynamic>{
          'overview_polyline': <String, dynamic>{
            'points': encodePolyline(points)
          }
        }
      ]
    };

void main() {
  test('Belgrad liegt im Prüfpolygon', () {
    expect(SerbiaAvoidance.containsCoordinate(44.7866, 20.4489), isTrue);
  });

  test('Griechenland nach Österreich erhält Transitkorridor', () {
    expect(
      SerbiaAvoidance.corridorFor('Athen, Griechenland', 'Wien, Österreich'),
      [
        'Sofia, Bulgaria',
        'Ruse, Bulgaria',
        'Sibiu, Romania',
        'Arad, Romania',
        'Budapest, Hungary'
      ],
    );
    expect(
      SerbiaAvoidance.corridorFor('Vienna, Austria', 'Athens, Greece')!.first,
      'Budapest, Hungary',
    );
    expect(SerbiaAvoidance.corridorFor('Berlin, Germany', 'Paris, France'),
        isNull);
  });

  test('Route durch Belgrad wird als Serbien-Durchfahrt erkannt', () {
    expect(SerbiaAvoidance.containsCoordinate(44.7866, 20.4489), isTrue);
    final response = responseFor([
      (42.6977, 23.3219), // Sofia
      (44.7866, 20.4489), // Belgrade
      (47.4979, 19.0402), // Budapest
    ]);
    final encoded = ((response['routes'] as List).first
        as Map<String, dynamic>)['overview_polyline']['points'] as String;
    final decoded = SerbiaAvoidance.decodeCoordinates(encoded);
    expect(decoded[1].$1, closeTo(44.7866, 0.0001));
    expect(decoded[1].$2, closeTo(20.4489, 0.0001));
    expect(map_launcher.decodePolyline(encoded)[1].longitude,
        closeTo(20.4489, 0.0001));
    expect(SerbiaAvoidance.routeCrossesSerbia(response), isTrue);
  });

  test('Korridor über Bulgarien und Rumänien bleibt außerhalb Serbiens', () {
    final response = responseFor([
      (37.9838, 23.7275), // Athens
      (42.6977, 23.3219), // Sofia
      (43.8356, 25.9657), // Ruse
      (45.7983, 24.1256), // Sibiu
      (46.1866, 21.3123), // Arad
      (47.4979, 19.0402), // Budapest
      (48.2082, 16.3738), // Vienna
    ]);
    expect(SerbiaAvoidance.routeCrossesSerbia(response), isFalse);
  });

  test('Detaillierte Straßenlinien haben Vorrang vor der groben Übersicht', () {
    final response = responseFor([
      (42.6977, 23.3219),
      (44.7866, 20.4489),
      (47.4979, 19.0402),
    ]);
    final route = (response['routes'] as List).first as Map<String, dynamic>;
    route['legs'] = [
      {
        'steps': [
          {
            'polyline': {
              'points': encodePolyline([
                (42.6977, 23.3219),
                (43.8356, 25.9657),
                (45.7983, 24.1256),
                (46.1866, 21.3123),
                (47.4979, 19.0402),
              ]),
            }
          }
        ]
      }
    ];
    expect(SerbiaAvoidance.routeCrossesSerbia(response), isFalse);
  });

  test('Ohne Streckenlinie ist eine Ländersperre nicht verifizierbar', () {
    expect(
        SerbiaAvoidance.routeCrossesSerbia({
          'routes': [{}]
        }),
        isNull);
  });
}
