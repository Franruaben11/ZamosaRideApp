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

void main() {
  final fixture = File('test/fixtures/valhalla_route.json').readAsStringSync();

  group('parseValhallaResponse', () {
    test('stitches multi-leg shapes and offsets maneuver indices', () {
      final routes = parseValhallaResponse((fixture, TravelMode.drive));
      final route = routes.first;

      // 11 + 11 points, boundary point shared once.
      expect(route.shape.length, 21);
      expect(route.shape.first, const LatLng(17.4, 78.4));
      expect(route.shape.last, const LatLng(17.41, 78.41));

      // Leg-2 maneuvers are shifted by leg-1's last index (10).
      expect(route.maneuvers.length, 4);
      expect(route.maneuvers[0].beginShapeIndex, 0);
      expect(route.maneuvers[1].type, 4);
      expect(route.maneuvers[1].beginShapeIndex, 10);
      expect(route.maneuvers[2].type, 1);
      expect(route.maneuvers[2].beginShapeIndex, 10);
      expect(route.maneuvers[3].beginShapeIndex, 20);

      expect(route.distanceMeters, closeTo(2167, 1));
      expect(route.timeSeconds, 195);
      expect(route.mode, TravelMode.drive);
      expect(route.hasHighway, isTrue);
      expect(route.hasToll, isFalse);
      expect(route.badges, ['Highway']);

      // Cumulative table is built at parse time and monotonic.
      expect(route.cumulative.length, 21);
      expect(route.cumulative.first, 0);
      expect(route.cumulative.last, closeTo(2167, 30));
      for (var i = 1; i < route.cumulative.length; i++) {
        expect(
          route.cumulative[i],
          greaterThanOrEqualTo(route.cumulative[i - 1]),
        );
      }
    });

    test('keeps good alternates and drops broken ones', () {
      final routes = parseValhallaResponse((fixture, TravelMode.drive));
      // Primary + one valid alternate; the empty third trip is skipped.
      expect(routes.length, 2);
      expect(routes[1].shape.length, 21);
      expect(routes[1].maneuvers.length, 3);
      expect(routes[1].hasToll, isTrue);
      expect(routes[1].badges, ['Tolls']);
    });

    test('rejects a primary route with no maneuvers', () {
      final json = jsonDecode(fixture) as Map<String, dynamic>;
      final trip = json['trip'] as Map<String, dynamic>;
      for (final leg in trip['legs'] as List) {
        (leg as Map<String, dynamic>)['maneuvers'] = <dynamic>[];
      }
      expect(
        () => parseValhallaResponse((
          jsonEncode({'trip': trip}),
          TravelMode.walk,
        )),
        throwsA(isA<BadResponseException>()),
      );
    });

    test('rejects non-JSON and a missing trip', () {
      expect(
        () => parseValhallaResponse(('<html>', TravelMode.walk)),
        throwsA(isA<BadResponseException>()),
      );
      expect(
        () => parseValhallaResponse(('{"error":"x"}', TravelMode.walk)),
        throwsA(isA<BadResponseException>()),
      );
    });
  });

  group('RoutingService', () {
    test(
      'posts a Valhalla request with the User-Agent and parses routes',
      () async {
        late http.Request captured;
        final client = MockClient((request) async {
          captured = request;
          return http.Response(fixture, 200);
        });
        final service = RoutingService(client: ApiClient(client));

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
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['costing'], 'auto');
        expect(body['alternates'], 2);
        final origin =
            (body['locations'] as List).first as Map<String, dynamic>;
        expect(origin['heading'], 90);
        expect(
          ((body['costing_options'] as Map)['auto'] as Map)['use_tolls'],
          0.0,
        );
        expect((body['directions_options'] as Map)['language'], 'en-US');
      },
    );

    test('maps Valhalla "no path" errors to a non-retryable message', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'error_code': 442, 'error': 'No path could be found'}),
          400,
        ),
      );
      final service = RoutingService(client: client);
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
      final service = RoutingService(client: client);
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
      final service = RoutingService(client: client);
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
