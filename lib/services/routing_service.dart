import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/nav_route.dart';
import '../util/geo.dart';
import 'api_client.dart';
import 'app_exception.dart';

/// Routing via the public Valhalla instance run by FOSSGIS on
/// OpenStreetMap data (https://valhalla1.openstreetmap.de).
class RoutingService {
  static const _endpoint = 'https://valhalla1.openstreetmap.de/route';

  final http.Client _client;

  /// BCP-47 tag for Valhalla's spoken/written instructions.
  final String language;

  RoutingService({http.Client? client, this.language = 'en-US'})
    : _client = client ?? ApiClient.shared;

  /// Returns the primary route plus up to [alternates] alternatives.
  Future<List<NavRoute>> getRoutes({
    required LatLng from,
    required LatLng to,
    required TravelMode mode,
    RouteOptions options = const RouteOptions(),
    int alternates = 2,
    double? headingDegrees,
  }) => guarded('Valhalla route', () async {
    // Soft-avoidance weights understood by Valhalla's costing models.
    final costingOptions = <String, dynamic>{
      if (options.avoidTolls && mode.motorized) 'use_tolls': 0.0,
      if (options.avoidHighways && mode.motorized) 'use_highways': 0.0,
      if (options.avoidFerries) 'use_ferry': 0.0,
    };

    final body = {
      'locations': [
        {
          'lat': from.latitude,
          'lon': from.longitude,
          if (headingDegrees != null) 'heading': headingDegrees.round(),
          if (headingDegrees != null) 'heading_tolerance': 90,
        },
        {'lat': to.latitude, 'lon': to.longitude},
      ],
      'costing': mode.valhallaCosting,
      if (costingOptions.isNotEmpty)
        'costing_options': {mode.valhallaCosting: costingOptions},
      // Alternates are only supported for some costings/regions; the
      // server simply omits them when unavailable.
      if (alternates > 0) 'alternates': alternates,
      'units': 'kilometers',
      'directions_options': {'language': language},
    };

    final response = await _client
        .post(
          Uri.parse(_endpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw _errorFor(response);
    }
    // Several hundred KB of JSON and tens of thousands of polyline
    // points: parse off the UI isolate so a mid-navigation reroute
    // never stalls the camera animation.
    return compute(parseValhallaResponse, (response.body, mode));
  });

  static AppException _errorFor(http.Response response) {
    String? message;
    int? code;
    try {
      final err = jsonDecode(response.body) as Map<String, dynamic>;
      message = err['error'] as String?;
      code = (err['error_code'] as num?)?.toInt();
    } on FormatException {
      // Not JSON — fall through to the generic message.
    } on TypeError {
      // JSON but not an object — same.
    }
    // Valhalla error codes: 442 no path, 171/170 no edges near location,
    // 154 path distance exceeds the max.
    return switch (code) {
      442 ||
      171 ||
      170 => const NoRouteException('No route found between these points'),
      154 => const NoRouteException('Route is too long for this travel mode'),
      _ => ServerException(
        response.statusCode,
        message: response.statusCode == 400 && message != null
            ? _humanize(message)
            : null,
      ),
    };
  }

  static String _humanize(String valhallaMessage) {
    final m = valhallaMessage.toLowerCase();
    if (m.contains('no path')) return 'No route found between these points';
    if (m.contains('no data') || m.contains('no edge')) {
      return 'One of the points is outside the routable map';
    }
    return 'Routing failed: $valhallaMessage';
  }
}

/// Parses a Valhalla `/route` response body into routes (primary first).
/// Top-level and [compute]-compatible: the argument and the result cross an
/// isolate boundary.
List<NavRoute> parseValhallaResponse((String, TravelMode) input) {
  final (body, mode) = input;
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(body) as Map<String, dynamic>;
  } on FormatException catch (e) {
    throw BadResponseException(
      message: 'Routing response was not JSON',
      cause: e,
    );
  } on TypeError catch (e) {
    throw BadResponseException(
      message: 'Routing response was not JSON',
      cause: e,
    );
  }
  final trip = json['trip'];
  if (trip is! Map<String, dynamic>) {
    throw const BadResponseException(message: 'Routing response had no trip');
  }
  final routes = <NavRoute>[parseValhallaTrip(trip, mode)];
  final alts = json['alternates'] as List<dynamic>? ?? const [];
  for (final alt in alts) {
    final altTrip = (alt as Map<String, dynamic>)['trip'];
    if (altTrip is Map<String, dynamic>) {
      try {
        routes.add(parseValhallaTrip(altTrip, mode));
      } on BadResponseException {
        // A broken alternate shouldn't take the primary route down with it.
      }
    }
  }
  return routes;
}

/// Parses one Valhalla trip (possibly multi-leg) into a [NavRoute].
@visibleForTesting
NavRoute parseValhallaTrip(Map<String, dynamic> trip, TravelMode mode) {
  final shape = <LatLng>[];
  final maneuvers = <RouteManeuver>[];
  var shapeOffset = 0;

  for (final legRaw in trip['legs'] as List<dynamic>? ?? const []) {
    final leg = legRaw as Map<String, dynamic>;
    final encoded = leg['shape'] as String?;
    if (encoded == null) continue;
    final legShape = decodePolyline(encoded);
    if (legShape.isEmpty) continue;
    // Consecutive legs share their boundary point.
    final start = shape.isEmpty ? 0 : 1;
    shape.addAll(legShape.sublist(start.clamp(0, legShape.length)));

    for (final mRaw in leg['maneuvers'] as List<dynamic>? ?? const []) {
      final m = mRaw as Map<String, dynamic>;
      maneuvers.add(
        RouteManeuver(
          type: (m['type'] as num?)?.toInt() ?? 0,
          instruction: m['instruction'] as String? ?? '',
          verbalAlert: m['verbal_transition_alert_instruction'] as String?,
          verbalPre: m['verbal_pre_transition_instruction'] as String?,
          verbalPost: m['verbal_post_transition_instruction'] as String?,
          lengthMeters: ((m['length'] as num?)?.toDouble() ?? 0) * 1000,
          timeSeconds: (m['time'] as num?)?.toDouble() ?? 0,
          beginShapeIndex:
              ((m['begin_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
          endShapeIndex:
              ((m['end_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
        ),
      );
    }
    shapeOffset = shape.length - 1;
  }

  // The engine indexes `maneuvers.first`, `shape[i + 1]` and
  // `clamp(0, maneuvers.length - 1)`: reject anything it can't navigate.
  if (shape.length < 2 || maneuvers.isEmpty) {
    throw const BadResponseException(message: 'Route has no usable geometry');
  }

  final summary = trip['summary'] as Map<String, dynamic>? ?? const {};
  final cumulative = cumulativeDistances(shape);
  return NavRoute(
    shape: shape,
    maneuvers: maneuvers,
    distanceMeters:
        ((summary['length'] as num?)?.toDouble() ?? cumulative.last / 1000) *
        1000,
    timeSeconds: (summary['time'] as num?)?.toDouble() ?? 0,
    mode: mode,
    hasToll: summary['has_toll'] == true,
    hasHighway: summary['has_highway'] == true,
    hasFerry: summary['has_ferry'] == true,
    cumulative: cumulative,
  );
}

/// Valhalla could not find a path; retrying won't help.
class NoRouteException extends AppException {
  const NoRouteException(super.message);

  @override
  bool get retryable => false;
}

/// Kept for callers that match on the old name.
typedef RoutingException = AppException;
