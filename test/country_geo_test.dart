import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:driverroute_eta/services/country_geo.dart';

import 'helpers/fake_directions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => CountryGeo.ensureLoaded());

  test('erkennt Länder anhand von Koordinaten', () {
    expect(CountryGeo.countryAt(const LatLng(46.948, 7.447)), 'CH'); // Bern
    expect(CountryGeo.countryAt(const LatLng(48.137, 11.575)), 'DE'); // München
    expect(CountryGeo.countryAt(const LatLng(44.787, 20.449)), 'RS'); // Belgrad
    expect(CountryGeo.countryAt(const LatLng(45.464, 9.190)), 'IT'); // Mailand
    expect(CountryGeo.countryAt(const LatLng(47.263, 11.395)), 'AT'); // Innsbruck
    expect(CountryGeo.countryAt(const LatLng(42.0, 17.0)), isNull); // Adria
  });

  test('offenes Meer gilt nicht als Land', () {
    expect(CountryGeo.isOnLand(const LatLng(42.0, 17.0)), isFalse);
    expect(CountryGeo.isOnLand(const LatLng(48.137, 11.575)), isTrue);
  });

  test('meldet gesperrtes Land auf der Strecke', () {
    // München → Zürich → Lugano → Mailand
    final path = densify([
      [48.137, 11.575],
      [47.55, 9.68],
      [47.37, 8.54],
      [46.00, 8.95],
      [45.46, 9.19],
    ]).map((p) => LatLng(p[0], p[1])).toList();

    expect(CountryGeo.blockedCountriesOnPath(path, {'CH'}), contains('CH'));
    expect(CountryGeo.blockedCountriesOnPath(path, {'RS'}), isEmpty);
  });

  test('meldet kein gesperrtes Land auf der Brenner-Route', () {
    // München → Innsbruck → Bozen → Verona → Mailand
    final path = densify([
      [48.137, 11.575],
      [47.263, 11.395],
      [46.50, 11.35],
      [45.44, 10.99],
      [45.46, 9.19],
    ]).map((p) => LatLng(p[0], p[1])).toList();

    expect(CountryGeo.blockedCountriesOnPath(path, {'CH'}), isEmpty);
    final km = CountryGeo.kmPerCountry(path);
    expect(km['AT'], greaterThan(50));
    expect(km['IT'], greaterThan(100));
  });
}
