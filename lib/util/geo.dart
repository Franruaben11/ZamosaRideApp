import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'units.dart';

/// Decodes a Google-encoded polyline with the given precision
/// (Valhalla uses 1e6, OSRM uses 1e5).
///
/// Throws [FormatException] on a truncated string.
List<LatLng> decodePolyline(String encoded, {int precision = 6}) {
  final factor = math.pow(10, precision).toDouble();
  final points = <LatLng>[];
  final length = encoded.length;
  var index = 0, lat = 0, lng = 0;

  int readDelta() {
    var shift = 0, result = 0;
    int byte;
    do {
      if (index >= length) {
        throw const FormatException('Truncated polyline');
      }
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (index < length) {
    lat += readDelta();
    lng += readDelta();
    points.add(LatLng(lat / factor, lng / factor));
  }
  return points;
}

/// Haversine is ~10x cheaper than Vincenty and accurate to ~0.3% — more
/// than enough for snapping, follow thresholds and ETAs. `roundResult:
/// false` keeps sub-metre precision (the default rounds to whole metres,
/// which turns a 1.5 m threshold into 2 m).
const Distance _distance = DistanceHaversine(roundResult: false);

/// Great-circle distance in meters.
double distanceMeters(LatLng a, LatLng b) => _distance(a, b);

/// Bearing from [a] to [b] in degrees (0–360).
double bearingDegrees(LatLng a, LatLng b) {
  final brng = _distance.bearing(a, b);
  return brng < 0 ? brng + 360 : brng;
}

/// Smallest absolute angle between two bearings, in degrees (0–180).
double bearingDiff(double a, double b) {
  var diff = (a - b).abs() % 360;
  if (diff > 180) diff = 360 - diff;
  return diff;
}

/// Ground meters represented by one logical pixel at [zoom] / [latitude]
/// (Web-Mercator, 256 px tiles).
double metersPerPixel(double zoom, double latitude) =>
    156543.03392 * math.cos(latitude * math.pi / 180) / math.pow(2, zoom);

/// The point [meters] away from [from] along [bearingDeg] (any angle; the
/// Haversine calculator itself only accepts −180…180).
LatLng offsetBy(LatLng from, double meters, double bearingDeg) {
  var b = bearingDeg % 360;
  if (b > 180) b -= 360;
  return _distance.offset(from, meters, b);
}

/// Result of projecting a point onto a route polyline.
class RouteProjection {
  final LatLng snapped;

  /// Index of the segment start vertex.
  final int segmentIndex;

  /// Distance in meters from the query point to the snapped point.
  final double offRouteMeters;

  /// Distance in meters traveled along the route up to the snapped point.
  final double alongRouteMeters;

  const RouteProjection({
    required this.snapped,
    required this.segmentIndex,
    required this.offRouteMeters,
    required this.alongRouteMeters,
  });
}

/// Longitude difference normalised to (-180, 180] so routes crossing the
/// antimeridian project correctly.
double _lngDelta(double from, double to) {
  var d = to - from;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
}

/// Projects [p] onto the polyline [shape]. [cumulative] must hold the
/// cumulative distance in meters at each vertex of [shape].
///
/// [hintIndex] (last known segment) limits the search window during
/// navigation so we don't snap backwards onto a distant loop of the route.
RouteProjection projectOntoRoute(
  LatLng p,
  List<LatLng> shape,
  List<double> cumulative, {
  int? hintIndex,
  int window = 40,
}) {
  assert(shape.length >= 2);
  var start = 0, end = shape.length - 2;
  if (hintIndex != null) {
    start = math.max(0, hintIndex - 5);
    end = math.min(shape.length - 2, hintIndex + window);
  }

  // Local equirectangular projection around p (accurate at city scale).
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double toX(LatLng q) => _lngDelta(p.longitude, q.longitude) * cosLat;
  double toY(LatLng q) => q.latitude - p.latitude;

  var bestDist = double.infinity;
  var bestIndex = start;
  var bestPoint = shape[start];

  for (var i = start; i <= end; i++) {
    final a = shape[i], b = shape[i + 1];
    final ax = toX(a), ay = toY(a), bx = toX(b), by = toY(b);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = 0.0;
    if (len2 > 0) {
      t = ((-ax) * dx + (-ay) * dy) / len2;
      t = t.clamp(0.0, 1.0);
    }
    final px = ax + t * dx, py = ay + t * dy;
    final d2 = px * px + py * py;
    if (d2 < bestDist) {
      bestDist = d2;
      bestIndex = i;
      bestPoint = LatLng(
        a.latitude + t * (b.latitude - a.latitude),
        a.longitude + t * _lngDelta(a.longitude, b.longitude),
      );
    }
  }

  final along =
      cumulative[bestIndex] + distanceMeters(shape[bestIndex], bestPoint);
  return RouteProjection(
    snapped: bestPoint,
    segmentIndex: bestIndex,
    offRouteMeters: distanceMeters(p, bestPoint),
    alongRouteMeters: along,
  );
}

/// Builds the cumulative-distance table for a polyline.
List<double> cumulativeDistances(List<LatLng> shape) {
  final result = List<double>.filled(shape.length, 0);
  for (var i = 1; i < shape.length; i++) {
    result[i] = result[i - 1] + distanceMeters(shape[i - 1], shape[i]);
  }
  return result;
}

/// Parses "lat, lon" (also "lat lon", "geo:lat,lon", "lat,lon?z=…") into a
/// coordinate, or null when [text] isn't a coordinate pair.
LatLng? parseCoordinates(String text) {
  var t = text.trim();
  if (t.toLowerCase().startsWith('geo:')) t = t.substring(4);
  final q = t.indexOf('?');
  if (q >= 0) t = t.substring(0, q);
  final m = RegExp(
    r'^\s*([+-]?\d{1,2}(?:\.\d+)?)\s*[,;\s]\s*([+-]?\d{1,3}(?:\.\d+)?)\s*$',
  ).firstMatch(t);
  if (m == null) return null;
  final lat = double.tryParse(m.group(1)!);
  final lon = double.tryParse(m.group(2)!);
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return LatLng(lat, lon);
}

// ───────────────────────────────────────── formatting

/// Formats a distance in the user's units ([Units.current] unless given).
String formatDistance(double meters, {Units? units}) {
  final u = units ?? Units.current;
  if (u == Units.imperial) {
    final feet = meters * 3.28084;
    if (feet < 1000) return '${(feet / 10).round() * 10} ft';
    final miles = meters / 1609.344;
    if (miles < 10) return '${miles.toStringAsFixed(1)} mi';
    return '${miles.round()} mi';
  }
  if (meters < 10) return '${meters.round()} m';
  if (meters < 1000) return '${(meters / 10).round() * 10} m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 1000).round()} km';
}

/// Speed as a rounded number plus unit label, e.g. ("42", "km/h").
({String value, String unit}) formatSpeed(double mps, {Units? units}) {
  final u = units ?? Units.current;
  return u == Units.imperial
      ? (value: '${(mps * 2.23694).round()}', unit: 'mph')
      : (value: '${(mps * 3.6).round()}', unit: 'km/h');
}

/// Temperature in the user's units, e.g. "23°C" / "73°F".
String formatTemperature(double celsius, {Units? units, int decimals = 0}) {
  final u = units ?? Units.current;
  final v = u == Units.imperial ? celsius * 9 / 5 + 32 : celsius;
  final s = decimals == 0 ? '${v.round()}' : v.toStringAsFixed(decimals);
  return '$s°${u == Units.imperial ? 'F' : 'C'}';
}

String formatDuration(double seconds) {
  final mins = (seconds / 60).round();
  if (mins < 60) return '$mins min';
  final h = mins ~/ 60, m = mins % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

String formatEta(double secondsFromNow, {DateTime? now}) {
  final eta = (now ?? DateTime.now()).add(
    Duration(seconds: secondsFromNow.round()),
  );
  final h = eta.hour % 12 == 0 ? 12 : eta.hour % 12;
  final m = eta.minute.toString().padLeft(2, '0');
  return '$h:$m ${eta.hour < 12 ? 'AM' : 'PM'}';
}
