import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/models/nav_route.dart';
import 'package:open_maps/models/place.dart';
import 'package:open_maps/navigation/navigation_engine.dart';
import 'package:open_maps/navigation/speaker.dart';
import 'package:open_maps/services/routing_service.dart';
import 'package:open_maps/util/geo.dart';

class FakeSpeaker implements Speaker {
  final spoken = <String>[];
  int stops = 0;

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stops++;
}

class FakeRouting extends RoutingService {
  final Future<List<NavRoute>> Function() onRoute;
  int calls = 0;

  FakeRouting(this.onRoute);

  @override
  Future<List<NavRoute>> getRoutes({
    required LatLng from,
    required LatLng to,
    required TravelMode mode,
    RouteOptions options = const RouteOptions(),
    int alternates = 2,
    double? headingDegrees,
  }) {
    calls++;
    return onRoute();
  }
}

Position fix(
  LatLng at, {
  double speed = 12,
  double heading = 90,
  double accuracy = 5,
}) => Position(
  latitude: at.latitude,
  longitude: at.longitude,
  timestamp: DateTime(2026, 8, 21, 9),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: heading,
  headingAccuracy: 0,
  speed: speed,
  speedAccuracy: 0,
);

/// Points every [stepMeters] along [from] → [to].
List<LatLng> walk(LatLng from, LatLng to, {double stepMeters = 40}) {
  final total = distanceMeters(from, to);
  final bearing = bearingDegrees(from, to);
  final n = (total / stepMeters).floor();
  return [for (var i = 1; i <= n; i++) offsetBy(from, i * stepMeters, bearing)];
}

void main() {
  final fixture = File('test/fixtures/valhalla_route.json').readAsStringSync();
  late NavRoute route;
  late FakeSpeaker speaker;
  late FakeRouting routing;
  late StreamController<Position> positions;

  NavigationEngine engineFor(NavRoute r) => NavigationEngine(
    route: r,
    destination: Place(name: 'Park', point: r.shape.last),
    routing: routing,
    speaker: speaker,
    positionStream: () => positions.stream,
    currentPosition: () async => fix(r.shape.first, speed: 0),
  );

  setUp(() {
    // The single-leg alternate: start → left turn at index 10 → arrive.
    route = parseValhallaResponse((fixture, TravelMode.drive))[1];
    speaker = FakeSpeaker();
    routing = FakeRouting(() async => [route]);
    positions = StreamController<Position>();
  });

  // Not returned: `close()` only completes once someone has listened.
  tearDown(() => unawaited(positions.close()));

  test('initial state comes from the route', () {
    final engine = engineFor(route);
    expect(engine.remainingDistanceMeters, route.distanceMeters);
    expect(engine.remainingTimeSeconds, route.timeSeconds);
    expect(engine.nextManeuverIndex, 1);
    expect(
      engine.distanceToNextManeuver,
      closeTo(
        route.distanceAtShapeIndex(route.maneuvers[1].beginShapeIndex),
        0.01,
      ),
    );
    engine.dispose();
  });

  test('start announces the first instruction and seeds a fix', () async {
    final engine = engineFor(route);
    await engine.start();
    expect(speaker.spoken.first, startsWith('Starting navigation.'));
    expect(engine.rawPosition, route.shape.first);
    expect(engine.snappedPosition, isNotNull);
    engine.dispose();
  });

  test(
    'a trace along the route progresses, announces the turn and arrives',
    () async {
      final engine = engineFor(route);
      var notifications = 0;
      engine.addListener(() => notifications++);
      await engine.start();

      final corner = route.shape[10];
      final end = route.shape.last;
      final distances = <double>[];

      for (final p in walk(route.shape.first, corner)) {
        engine.onPosition(fix(p));
        distances.add(engine.remainingDistanceMeters);
        expect(engine.offRoute, isFalse);
        expect(engine.rerouting, isFalse);
      }
      // Remaining distance only ever shrinks.
      for (var i = 1; i < distances.length; i++) {
        expect(distances[i], lessThanOrEqualTo(distances[i - 1] + 0.01));
      }
      // Approaching the corner: the left turn is the next maneuver.
      expect(engine.nextManeuver?.type, 15);
      expect(
        speaker.spoken.where((s) => s.contains('Turn left onto Park Road')),
        isNotEmpty,
      );
      expect(engine.heading, closeTo(90, 1));

      for (final p in walk(corner, end)) {
        engine.onPosition(fix(p, heading: 0));
      }
      engine.onPosition(fix(end, heading: 0, speed: 0));

      expect(engine.arrived, isTrue);
      expect(engine.remainingDistanceMeters, lessThan(30));
      expect(speaker.spoken.last, 'You have arrived at your destination.');
      // One heads-up, one arrival — not doubled by the "now" cue.
      expect(
        speaker.spoken
            .where((s) => s == 'You will arrive at your destination.')
            .length,
        1,
      );
      expect(
        speaker.spoken
            .where((s) => s.contains('arrived at your destination'))
            .length,
        1,
      );
      expect(routing.calls, 0);
      expect(notifications, greaterThan(20));
      engine.dispose();
    },
  );

  test(
    'at low speed the heading follows the route, not the noisy GPS course',
    () async {
      final engine = engineFor(route);
      await engine.start();
      engine.onPosition(fix(route.shape[2], speed: 0.5, heading: 237));
      expect(engine.heading, closeTo(90, 1));
      engine.dispose();
    },
  );

  test('leaving the route reroutes once, then follows the new route', () async {
    final rerouted = Completer<List<NavRoute>>();
    routing = FakeRouting(() => rerouted.future);
    final engine = engineFor(route);
    await engine.start();

    // 120 m south of the first segment: clearly gone → instant reroute.
    final off = offsetBy(route.shape[3], 120, 180);
    engine.onPosition(fix(off, heading: 180));
    expect(engine.offRoute, isTrue);
    expect(engine.snappedPosition, isNull);
    expect(engine.rerouting, isTrue);
    expect(routing.calls, 1);
    expect(speaker.spoken.last, 'Rerouting.');

    // Further fixes while rerouting don't pile up requests.
    engine.onPosition(fix(offsetBy(off, 40, 180), heading: 180));
    expect(routing.calls, 1);

    final alt = parseValhallaResponse((fixture, TravelMode.drive))[0];
    rerouted.complete([alt]);
    await Future<void>.delayed(Duration.zero);

    expect(engine.rerouting, isFalse);
    expect(identical(engine.route, alt), isTrue);
    expect(engine.offRoute, isFalse);
    expect(engine.remainingDistanceMeters, alt.distanceMeters);
    expect(speaker.spoken.last, alt.maneuvers[1].instruction);
    engine.dispose();
  });

  test(
    'a failed reroute surfaces a message and allows another attempt',
    () async {
      routing = FakeRouting(() async => throw const SocketException('down'));
      final engine = engineFor(route);
      await engine.start();

      engine.onPosition(fix(offsetBy(route.shape[3], 120, 180), heading: 180));
      await Future<void>.delayed(Duration.zero);
      expect(engine.rerouting, isFalse);
      expect(engine.error, contains('Reroute failed'));
      expect(identical(engine.route, route), isTrue);
      engine.dispose();
    },
  );

  test('disposing mid-reroute never notifies afterwards', () async {
    final rerouted = Completer<List<NavRoute>>();
    routing = FakeRouting(() => rerouted.future);
    final engine = engineFor(route);
    await engine.start();
    engine.onPosition(fix(offsetBy(route.shape[3], 120, 180), heading: 180));
    expect(engine.rerouting, isTrue);

    engine.dispose();
    rerouted.complete([route]);
    // Would throw "used after being disposed" if the guard were missing.
    await Future<void>.delayed(Duration.zero);
    expect(speaker.stops, 1);
  });

  test('disposing during the initial fix is safe', () async {
    final fixCompleter = Completer<Position>();
    final engine = NavigationEngine(
      route: route,
      destination: Place(name: 'Park', point: route.shape.last),
      routing: routing,
      speaker: speaker,
      positionStream: () => positions.stream,
      currentPosition: () => fixCompleter.future,
    );
    final started = engine.start();
    engine.dispose();
    fixCompleter.complete(fix(route.shape.first));
    await started;
    expect(engine.rawPosition, isNull);
  });

  test('mute stops speech and suppresses further prompts', () async {
    final engine = engineFor(route);
    engine.setMuted(muted: true);
    await engine.start();
    expect(speaker.spoken, isEmpty);
    expect(speaker.stops, 1);
    engine.setMuted(muted: false);
    engine.onPosition(fix(route.shape[9]));
    expect(speaker.spoken, isNotEmpty);
    engine.dispose();
  });

  test('stream errors are reported, not thrown', () async {
    final engine = engineFor(route);
    await engine.start();
    positions.addError(const LocationServiceDisabledException());
    await Future<void>.delayed(Duration.zero);
    expect(engine.error, 'Location unavailable');
    engine.dispose();
  });
}
