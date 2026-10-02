import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/models/nav_route.dart';
import 'package:open_maps/services/api_client.dart';
import 'package:open_maps/services/app_exception.dart';
import 'package:open_maps/services/routing_service.dart';

const _encodedLine = '_p~iF~ps|U_ulLnnqC_mqNvxq`@';

Map<String, dynamic> _step({
  required String instructions,
  required String maneuver,
  required int durationSeconds,
}) => {
  'staticDuration': '${durationSeconds}s',
  'distanceMeters': durationSeconds * 10,
  'polyline': {'encodedPolyline': _encodedLine},
  'navigationInstruction': {
    'instructions': instructions,
    'maneuver': maneuver,
  },
};

Map<String, dynamic> _route({
  required int durationSeconds,
  required int distanceMeters,
  required List<Map<String, dynamic>> steps,
}) => {
  'duration': '${durationSeconds}s',
  'distanceMeters': distanceMeters,
  'polyline': {'encodedPolyline': _encodedLine},
  'legs': [
    {
      'duration': '${durationSeconds}s',
      'steps': steps,
    },
  ],
};

String _fixture() => jsonEncode({
  'routes': [
    _route(
      durationSeconds: 195,
      distanceMeters: 2167,
      steps: [
        _step(
          instructions: 'Start',
          maneuver: 'DEPART',
          durationSeconds: 90,
        ),
        _step(
          instructions: 'Turn left onto Park Road',
          maneuver: 'TURN_LEFT',
          durationSeconds: 105,
        ),
      ],
    ),
    _route(
      durationSeconds: 220,
      distanceMeters: 2400,
      steps: [
        _step(
          instructions: 'Start',
          maneuver: 'DEPART',
          durationSeconds: 120,
        ),
        _step(
          instructions: 'Continue straight',
          maneuver: 'STRAIGHT',
          durationSeconds: 100,
        ),
      ],
    ),
    <String, dynamic>{},
  ],
});

void main() {
  final fixture = _fixture();

  group('parseGoogleRoutesResponse', () {
    test('stitches multi-step shapes and offsets maneuver indices', () {
      final routes = parseGoogleRoutesResponse((fixture, TravelMode.drive));
      final route = routes.first;

      expect(route.shape.length, 5);
      expect(route.shape.first, const LatLng(38.5, -120.2));
      expect(route.shape.last, const LatLng(43.252, -126.453));

      // Step-2 maneuvers are shifted by step-1's last index (2).
      expect(route.maneuvers.length, 2);
      expect(route.maneuvers[0].beginShapeIndex, 0);
      expect(route.maneuvers[1].type, 3);
      expect(route.maneuvers[1].beginShapeIndex, 2);

      expect(route.distanceMeters, closeTo(2167, 1));
      expect(route.timeSeconds, 195);
      expect(route.mode, TravelMode.drive);
      expect(route.hasToll, isFalse);
      expect(route.hasHighway, isFalse);
      expect(route.badges, isEmpty);

      // Cumulative table is built at parse time and monotonic.
      expect(route.cumulative.length, 5);
      expect(route.cumulative.first, 0);
      expect(route.cumulative.last, greaterThan(0));
      for (var i = 1; i < route.cumulative.length; i++) {
        expect(
          route.cumulative[i],
          greaterThanOrEqualTo(route.cumulative[i - 1]),
        );
      }
    });

    test('keeps good alternates and drops broken ones', () {
      final routes = parseGoogleRoutesResponse((fixture, TravelMode.drive));
      // Primary + one valid alternate; the empty third trip is skipped.
      expect(routes.length, 2);
      expect(routes[1].shape.length, 5);
      expect(routes[1].maneuvers.length, 2);
      expect(routes[1].hasToll, isFalse);
      expect(routes[1].badges, isEmpty);
    });

    test('rejects a primary route with no usable geometry', () {
      final json = jsonDecode(fixture) as Map<String, dynamic>;
      final routes = json['routes'] as List<dynamic>;
      for (final route in routes.take(1)) {
        final map = route as Map<String, dynamic>;
          map['legs'] = [
            {
              'duration': '10s',
              'steps': <dynamic>[],
            },
          ];
      }
        final parsed = parseGoogleRoutesResponse((jsonEncode(json), TravelMode.walk));
        expect(parsed.length, 1);
        expect(parsed.first.maneuvers.length, 2);
    });

    test('rejects non-JSON and a missing trip', () {
      expect(
        () => parseGoogleRoutesResponse(('<html>', TravelMode.walk)),
        throwsA(isA<BadResponseException>()),
      );
      expect(
        () => parseGoogleRoutesResponse(('{"error":"x"}', TravelMode.walk)),
        throwsA(isA<NoRouteException>()),
      );
    });
  });

  group('RoutingService', () {
    test(
      'posts a Google request with the User-Agent and parses routes',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(fixture, 200);
        });
        final service = RoutingService(client: ApiClient(client), apiKey: 'test-key');

        final routes = await service.getRoutes(
          from: const LatLng(17.4, 78.4),
          to: const LatLng(17.41, 78.41),
          mode: TravelMode.drive,
          options: const RouteOptions(avoidTolls: true),
          headingDegrees: 90,
        );

        expect(routes.length, 2);
        expect(captured.method, 'POST');
        expect(captured.headers['User-Agent'], kUserAgent);
        expect(captured.headers['X-Goog-Api-Key'], 'test-key');
        expect(
          captured.headers['X-Goog-FieldMask'],
          'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,routes.legs',
        );
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['travelMode'], 'DRIVE');
        expect(body['computeAlternativeRoutes'], isTrue);
        expect(body['routingPreference'], 'TRAFFIC_AWARE');
        expect(body['languageCode'], 'en-US');
        expect(
          (body['routeModifiers'] as Map<String, dynamic>)['avoidTolls'],
          isTrue,
        );
      },
    );

    test('maps Google no route errors to a non-retryable message', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 400,
              'message': 'No route could be found',
            },
          }),
          400,
        ),
      );
      final service = RoutingService(client: client, apiKey: 'test-key');
      try {
        await service.getRoutes(
          from: const LatLng(0, 0),
          to: const LatLng(1, 1),
          mode: TravelMode.walk,
        );
        fail('expected an exception');
      } on AppException catch (e) {
        expect(e, isA<NoRouteException>());
        expect(e.retryable, isFalse);
        expect(e.message, contains('No route'));
      }
    });

    test('maps a dropped connection to OfflineException', () async {
      final client = MockClient(
        (_) async => throw const SocketException('Failed host lookup'),
      );
      final service = RoutingService(client: client, apiKey: 'test-key');
      expect(
        () => service.getRoutes(
          from: const LatLng(0, 0),
          to: const LatLng(1, 1),
          mode: TravelMode.walk,
        ),
        throwsA(isA<OfflineException>()),
      );
    });

    test('5xx is a retryable ServerException', () async {
      final client = MockClient((_) async => http.Response('busy', 503));
      final service = RoutingService(client: client, apiKey: 'test-key');
      try {
        await service.getRoutes(
          from: const LatLng(0, 0),
          to: const LatLng(1, 1),
          mode: TravelMode.walk,
        );
        fail('expected an exception');
      } on ServerException catch (e) {
        expect(e.statusCode, 503);
        expect(e.retryable, isTrue);
      }
    });
  });
}
