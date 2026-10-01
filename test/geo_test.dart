import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/util/geo.dart';

void main() {
  group('decodePolyline', () {
    test('decodes the classic Google example (precision 5)', () {
      final points = decodePolyline(
        '_p~iF~ps|U_ulLnnqC_mqNvxq`@',
        precision: 5,
      );
      expect(points.length, 3);
      expect(points[0].latitude, closeTo(38.5, 1e-5));
      expect(points[0].longitude, closeTo(-120.2, 1e-5));
      expect(points[2].latitude, closeTo(43.252, 1e-5));
      expect(points[2].longitude, closeTo(-126.453, 1e-5));
    });

    test('round-trips a precision-6 encoding', () {
      // "_izlhA~rlgdF" encodes (38.5, -120.2) at 1e6 precision.
      final points = decodePolyline('_izlhA~rlgdF');
      expect(points.single.latitude, closeTo(38.5, 1e-6));
      expect(points.single.longitude, closeTo(-120.2, 1e-6));
    });
  });

  group('projectOntoRoute', () {
    final shape = [
      const LatLng(0, 0),
      const LatLng(0, 0.01), // ~1113 m east
      const LatLng(0.01, 0.01), // then ~1106 m north
    ];
    final cumulative = cumulativeDistances(shape);

    test('snaps a point beside the first segment', () {
      final projection = projectOntoRoute(
        const LatLng(0.0005, 0.005), // slightly north of segment midpoint
        shape,
        cumulative,
      );
      expect(projection.segmentIndex, 0);
      expect(projection.snapped.latitude, closeTo(0, 1e-9));
      expect(projection.snapped.longitude, closeTo(0.005, 1e-6));
      expect(projection.offRouteMeters, closeTo(55.3, 2));
      expect(projection.alongRouteMeters, closeTo(556.6, 3));
    });

    test('clamps to a vertex past the corner', () {
      final projection = projectOntoRoute(
        const LatLng(-0.001, 0.02), // beyond the east end, south side
        shape,
        cumulative,
      );
      expect(projection.segmentIndex, 0);
      expect(projection.snapped.longitude, closeTo(0.01, 1e-6));
    });

    test('respects the search window hint', () {
      final projection = projectOntoRoute(
        const LatLng(0.005, 0.0101),
        shape,
        cumulative,
        hintIndex: 1,
      );
      expect(projection.segmentIndex, 1);
      expect(projection.alongRouteMeters, greaterThan(cumulative[1]));
    });
  });

  group('formatting', () {
    test('formatDistance', () {
      expect(formatDistance(7), '7 m');
      expect(formatDistance(432), '430 m');
      expect(formatDistance(1250), '1.3 km');
      expect(formatDistance(23400), '23 km');
    });

    test('formatDuration', () {
      expect(formatDuration(90), '2 min');
      expect(formatDuration(3600), '1 hr');
      expect(formatDuration(4500), '1 hr 15 min');
    });
  });

  test('bearingDiff returns smallest angle between bearings', () {
    expect(bearingDiff(10, 350), closeTo(20, 1e-9));
    expect(bearingDiff(350, 10), closeTo(20, 1e-9));
    expect(bearingDiff(0, 180), closeTo(180, 1e-9));
    expect(bearingDiff(90, 90), closeTo(0, 1e-9));
    expect(bearingDiff(45, 225), closeTo(180, 1e-9));
    // Right turn suggested (090) but user went left (270) → 180° opposition.
    expect(bearingDiff(270, 90) > 100, isTrue);
  });

  test('offsetBy accepts bearings in any range', () {
    const origin = LatLng(17.4, 78.4);
    final west = offsetBy(origin, 1000, 270);
    expect(west.longitude, lessThan(origin.longitude));
    expect(distanceMeters(origin, west), closeTo(1000, 1));
    // Equivalent angles land on the same point.
    final a = offsetBy(origin, 500, 275.8);
    final b = offsetBy(origin, 500, -84.2);
    expect(distanceMeters(a, b), lessThan(0.01));
    expect(
      distanceMeters(origin, offsetBy(origin, 300, 720)),
      closeTo(300, 0.5),
    );
  });

  test('bearingDegrees is normalized to 0–360', () {
    final west = bearingDegrees(const LatLng(0, 0), const LatLng(0, -1));
    expect(west, closeTo(270, 0.5));
    final north = bearingDegrees(const LatLng(0, 0), const LatLng(1, 0));
    expect(north, closeTo(0, 0.5));
  });
}
