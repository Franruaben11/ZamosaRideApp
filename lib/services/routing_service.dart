import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart' as polyline_points;

import '../models/nav_route.dart';
import '../util/geo.dart';
import 'api_client.dart';
import 'app_exception.dart';

/// Routing via Google Routes API.
class RoutingService {
  static const _endpoint = 'https://routes.googleapis.com/directions/v2:computeRoutes';
  static const _fieldMask =
      'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs';

  final http.Client _client;

  /// BCP-47 tag for Google's spoken/written instructions.
  final String language;
  final String apiKey;

  RoutingService({
    http.Client? client,
    this.language = 'en-US',
    String? apiKey,
  }) : _client = client ?? ApiClient.shared,
       apiKey = apiKey ?? const String.fromEnvironment(
         'GOOGLE_MAPS_API_KEY',
         defaultValue: '',
       );

  /// Returns the primary route plus up to [alternates] alternatives.
  Future<List<NavRoute>> getRoutes({
    required LatLng from,
    required LatLng to,
    required TravelMode mode,
    RouteOptions options = const RouteOptions(),
    int alternates = 2,
    double? headingDegrees,
  }) => guarded('Google route', () async {
    if (apiKey.isEmpty) {
      throw const AppException(
        'Missing Google Maps API key. Set GOOGLE_MAPS_API_KEY.',
      );
    }

    final body = {
      'origin': {
        'location': {
          'latLng': {
            'latitude': from.latitude,
            'longitude': from.longitude,
          },
        },
      },
      'destination': {
        'location': {
          'latLng': {
            'latitude': to.latitude,
            'longitude': to.longitude,
          },
        },
      },
      'travelMode': _travelMode(mode),
      'polylineQuality': 'HIGH_QUALITY',
      'polylineEncoding': 'ENCODED_POLYLINE',
      'languageCode': language,
      if (mode.motorized) 'routingPreference': 'TRAFFIC_AWARE',
      if (alternates > 0) 'computeAlternativeRoutes': true,
      if (options.any)
        'routeModifiers': {
          if (options.avoidTolls) 'avoidTolls': true,
          if (options.avoidHighways) 'avoidHighways': true,
          if (options.avoidFerries) 'avoidFerries': true,
        },
    };

    if (headingDegrees != null) {
      body['origin'] = {
        'location': {
          'latLng': {
            'latitude': from.latitude,
            'longitude': from.longitude,
          },
        },
        'heading': headingDegrees.round(),
      };
    }

    final response = await _client
        .post(
          Uri.parse(_endpoint),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': apiKey,
            'X-Goog-FieldMask': _fieldMask,
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw _errorFor(response);
    }
    // Google responses still need polyline decoding, so keep parsing off
    // the UI isolate to avoid jank during reroutes.
    return compute(parseGoogleRoutesResponse, (response.body, mode));
  });

  static AppException _errorFor(http.Response response) {
    String? message;
    int? code;
    try {
      final err = jsonDecode(response.body) as Map<String, dynamic>;
      final error = err['error'];
      if (error is Map<String, dynamic>) {
        message = error['message'] as String?;
        code = (error['code'] as num?)?.toInt();
      }
    } on FormatException {
      // Not JSON — fall through to the generic message.
    } on TypeError {
      // JSON but not an object — same.
    }
    final lower = message?.toLowerCase() ?? '';
    if (response.statusCode == 400 &&
        (lower.contains('no route') ||
            lower.contains('could not be found') ||
            lower.contains('not be calculated'))) {
      return const NoRouteException('No route found between these points');
    }
    return switch (code) {
      400 => NoRouteException(
        message ?? 'No route found between these points',
      ),
      _ => ServerException(
        response.statusCode,
        message: message,
      ),
    };
  }

  static String _travelMode(TravelMode mode) => switch (mode) {
    TravelMode.drive => 'DRIVE',
    TravelMode.twoWheeler => 'TWO_WHEELER',
    TravelMode.bike => 'BICYCLE',
    TravelMode.walk => 'WALK',
  };

}

String _humanizeManeuver(String maneuver) {
  final value = maneuver.toUpperCase();
  if (value == 'DEPART') return 'Start';
  if (value == 'STRAIGHT') return 'Continue straight';
  if (value.contains('LEFT')) return 'Turn left';
  if (value.contains('RIGHT')) return 'Turn right';
  if (value.contains('MERGE')) return 'Merge';
  if (value.contains('FORK')) return 'Take the fork';
  if (value.contains('RAMP')) return 'Take the ramp';
  if (value.contains('ROUNDABOUT')) return 'Enter the roundabout';
  if (value.contains('FERRY')) return 'Take the ferry';
  return 'Continue';
}

/// Parses a Google Routes response body into routes (primary first).
/// Top-level and [compute]-compatible: the argument and the result cross an
/// isolate boundary.
List<NavRoute> parseGoogleRoutesResponse((String, TravelMode) input) {
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
  final rawRoutes = json['routes'] as List<dynamic>? ?? const [];
  if (rawRoutes.isEmpty) {
    throw const NoRouteException('No route found between these points');
  }

  final routes = <NavRoute>[];
  for (final raw in rawRoutes) {
    if (raw is! Map<String, dynamic>) continue;
    try {
      routes.add(parseGoogleRoute(raw, mode));
    } on BadResponseException {
      // A broken alternate shouldn't take the primary route down with it.
    }
  }
  if (routes.isEmpty) {
    throw const BadResponseException(message: 'Routing response had no usable routes');
  }
  return routes;
}

/// Parses one Google route (possibly multi-leg) into a [NavRoute].
@visibleForTesting
NavRoute parseGoogleRoute(Map<String, dynamic> route, TravelMode mode) {
  final shape = <LatLng>[];
  final maneuvers = <RouteManeuver>[];
  var shapeOffset = 0;
  final routeDurationSeconds = _parseDurationSeconds(route['duration']);
  final routePolyline =
      (route['polyline'] as Map<String, dynamic>?)?['encodedPolyline'] as String?;

  for (final legRaw in route['legs'] as List<dynamic>? ?? const []) {
    final leg = legRaw as Map<String, dynamic>;
    final legDurationSeconds = _parseDurationSeconds(leg['duration']);
    final steps = leg['steps'] as List<dynamic>? ?? const [];
    final stepDurations = <double>[];
    for (final stepRaw in steps) {
      final step = stepRaw as Map<String, dynamic>;
      stepDurations.add(_parseDurationSeconds(step['staticDuration']));
    }
    final totalStepDuration = stepDurations.fold<double>(0, (a, b) => a + b);
    final scale = totalStepDuration > 0 && legDurationSeconds > 0
        ? legDurationSeconds / totalStepDuration
        : routeDurationSeconds > 0 && totalStepDuration > 0
        ? routeDurationSeconds / totalStepDuration
        : 1.0;

    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final encoded =
          (step['polyline'] as Map<String, dynamic>?)?['encodedPolyline'] as String?;
      if (encoded == null || encoded.isEmpty) continue;

      final stepShape = _decodePolyline(encoded);
      if (stepShape.isEmpty) continue;

      final start = shape.isEmpty ? 0 : 1;
      shape.addAll(stepShape.sublist(start.clamp(0, stepShape.length)));

      final instruction =
          (step['navigationInstruction'] as Map<String, dynamic>?)?['instructions']
              as String?;
      final maneuver =
          (step['navigationInstruction'] as Map<String, dynamic>?)?['maneuver']
              as String?;
      maneuvers.add(
        RouteManeuver(
          type: _googleManeuverType(maneuver),
          instruction: (instruction != null && instruction.isNotEmpty)
              ? instruction
              : _humanizeManeuver(maneuver ?? ''),
          verbalAlert: (instruction != null && instruction.isNotEmpty)
              ? instruction
              : _humanizeManeuver(maneuver ?? ''),
          verbalPre: (instruction != null && instruction.isNotEmpty)
              ? instruction
              : _humanizeManeuver(maneuver ?? ''),
          verbalPost: (instruction != null && instruction.isNotEmpty)
              ? instruction
              : _humanizeManeuver(maneuver ?? ''),
          lengthMeters: _stepDistanceMeters(step, stepShape),
          timeSeconds: stepDurations[i] * scale,
          beginShapeIndex: shapeOffset,
          endShapeIndex: shape.length - 1,
        ),
      );
      shapeOffset = shape.length - 1;
    }
  }

  if (shape.length < 2 && routePolyline != null) {
    shape.addAll(_decodePolyline(routePolyline));
  }

  if (shape.length < 2 || maneuvers.isEmpty) {
    throw const BadResponseException(message: 'Route has no usable geometry');
  }

  final cumulative = cumulativeDistances(shape);
  return NavRoute(
    shape: shape,
    maneuvers: maneuvers,
    distanceMeters:
        (route['distanceMeters'] as num?)?.toDouble() ?? cumulative.last,
    timeSeconds: routeDurationSeconds,
    mode: mode,
    cumulative: cumulative,
  );
}

List<LatLng> _decodePolyline(String encoded) {
  final points = polyline_points.PolylinePoints.decodePolyline(encoded);
  return points
      .map((point) => LatLng(point.latitude, point.longitude))
      .toList(growable: false);
}

double _parseDurationSeconds(Object? value) {
  if (value is! String || value.isEmpty || !value.endsWith('s')) return 0;
  return double.tryParse(value.substring(0, value.length - 1)) ?? 0;
}

double _stepDistanceMeters(Map<String, dynamic> step, List<LatLng> stepShape) {
  final explicit = (step['distanceMeters'] as num?)?.toDouble();
  if (explicit != null) return explicit;
  if (stepShape.length < 2) return 0;
  return cumulativeDistances(stepShape).last;
}

int _googleManeuverType(String? maneuver) {
  switch (maneuver?.toUpperCase()) {
    case 'DEPART':
      return 0;
    case 'STRAIGHT':
      return 1;
    case 'TURN_SLIGHT_LEFT':
      return 2;
    case 'TURN_LEFT':
      return 3;
    case 'TURN_SHARP_LEFT':
      return 4;
    case 'TURN_SLIGHT_RIGHT':
      return 5;
    case 'TURN_RIGHT':
      return 6;
    case 'TURN_SHARP_RIGHT':
      return 7;
    case 'UTURN_LEFT':
      return 8;
    case 'UTURN_RIGHT':
      return 9;
    case 'RAMP_LEFT':
      return 10;
    case 'RAMP_RIGHT':
      return 11;
    case 'MERGE':
      return 12;
    case 'FORK_LEFT':
      return 13;
    case 'FORK_RIGHT':
      return 14;
    case 'ROUNDABOUT_LEFT':
      return 15;
    case 'ROUNDABOUT_RIGHT':
      return 16;
    case 'FERRY':
      return 17;
    case 'FERRY_TRAIN':
      return 18;
    case 'NAME_CHANGE':
      return 19;
    default:
      return 99;
  }
}

/// Valhalla could not find a path; retrying won't help.
class NoRouteException extends AppException {
  const NoRouteException(super.message);

  @override
  bool get retryable => false;
}

/// Kept for callers that match on the old name.
typedef RoutingException = AppException;
