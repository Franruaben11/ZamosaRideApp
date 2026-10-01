import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/util/geo.dart';
import 'package:open_maps/util/units.dart';

void main() {
  group('parseCoordinates', () {
    test('accepts common pasted forms', () {
      expect(
        parseCoordinates('17.4456, 78.3497'),
        const LatLng(17.4456, 78.3497),
      );
      expect(
        parseCoordinates(' -33.8688 151.2093 '),
        const LatLng(-33.8688, 151.2093),
      );
      expect(
        parseCoordinates('geo:48.8584,2.2945?z=17'),
        const LatLng(48.8584, 2.2945),
      );
      expect(parseCoordinates('51.5;-0.12'), const LatLng(51.5, -0.12));
    });

    test('rejects text and out-of-range values', () {
      expect(parseCoordinates('Charminar'), isNull);
      expect(parseCoordinates('12'), isNull);
      expect(parseCoordinates('91, 0'), isNull);
      expect(parseCoordinates('0, 181'), isNull);
      expect(parseCoordinates('1st Street, 12'), isNull);
    });
  });

  group('units', () {
    test('imperial distance, speed and temperature', () {
      expect(formatDistance(100, units: Units.imperial), '330 ft');
      expect(formatDistance(1609.344, units: Units.imperial), '1.0 mi');
      expect(formatDistance(40000, units: Units.imperial), '25 mi');
      expect(formatSpeed(20, units: Units.imperial), (
        value: '45',
        unit: 'mph',
      ));
      expect(formatSpeed(20, units: Units.metric), (value: '72', unit: 'km/h'));
      expect(formatTemperature(30, units: Units.imperial), '86°F');
      expect(
        formatTemperature(30.04, units: Units.metric, decimals: 1),
        '30.0°C',
      );
    });

    test('locale default', () {
      expect(Units.forCountry('US'), Units.imperial);
      expect(Units.forCountry('IN'), Units.metric);
      expect(Units.forCountry(null), Units.metric);
    });
  });

  test('formatEta is deterministic given a clock', () {
    final now = DateTime(2026, 8, 21, 23, 50);
    expect(formatEta(15 * 60, now: now), '12:05 AM');
    expect(formatEta(0, now: DateTime(2026, 8, 21, 12)), '12:00 PM');
  });

  test('decodePolyline rejects a truncated string', () {
    expect(
      () => decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq'),
      throwsFormatException,
    );
  });

  test('projectOntoRoute works across the antimeridian', () {
    final shape = [const LatLng(0, 179.99), const LatLng(0, -179.99)];
    final projection = projectOntoRoute(
      const LatLng(0.0001, 179.999),
      shape,
      cumulativeDistances(shape),
    );
    expect(projection.offRouteMeters, lessThan(20));
    expect(projection.alongRouteMeters, closeTo(1000, 30));
  });
}
