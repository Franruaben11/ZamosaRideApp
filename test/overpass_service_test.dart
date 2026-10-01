import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:open_maps/services/app_exception.dart';
import 'package:open_maps/services/overpass_service.dart';

const _mirrors = ['https://a/x', 'https://b/x', 'https://c/x'];

String _body(List<(double, double, String)> nodes) => jsonEncode({
  'elements': [
    for (final (lat, lon, name) in nodes)
      {
        'type': 'node',
        'id': name.hashCode,
        'lat': lat,
        'lon': lon,
        'tags': {'name': name, 'amenity': 'cafe'},
      },
  ],
});

void main() {
  const cafe = PoiCategory('Cafés', 'amenity', 'cafe');
  const center = LatLng(17.4, 78.4);

  test('parses elements and sorts by distance from the centre', () async {
    final client = MockClient(
      (_) async => http.Response(
        _body([
          (17.41, 78.41, 'far'),
          (17.4001, 78.4001, 'near'),
          (17.405, 78.405, 'mid'),
        ]),
        200,
      ),
    );
    final service = OverpassService(client: client, mirrors: _mirrors);
    final places = await service.findNearby(cafe, center);
    expect(places.map((p) => p.name), ['near', 'mid', 'far']);
    expect(places.first.category, 'cafe');
  });

  test('falls over to the next mirror immediately when one fails', () async {
    final hits = <String>[];
    final client = MockClient((request) async {
      hits.add(request.url.host);
      if (request.url.host == 'a') throw const SocketException('reset');
      if (request.url.host == 'b') return http.Response('busy', 504);
      return http.Response(_body([(17.4, 78.4, 'ok')]), 200);
    });
    final service = OverpassService(client: client, mirrors: _mirrors);
    final places = await service.findNearby(cafe, center);
    expect(places.single.name, 'ok');
    expect(hits, ['a', 'b', 'c']);
  });

  test('hedges a slow primary with the next mirror after 2.5 s', () {
    fakeAsync((async) {
      final hits = <String>[];
      final client = MockClient((request) async {
        hits.add(request.url.host);
        if (request.url.host == 'a') {
          // Never answers within the test window.
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        return http.Response(_body([(17.4, 78.4, request.url.host)]), 200);
      });
      final service = OverpassService(client: client, mirrors: _mirrors);
      String? winner;
      unawaited(
        service.findNearby(cafe, center).then((p) => winner = p.single.name),
      );

      async.elapse(const Duration(seconds: 2));
      expect(hits, ['a']);
      expect(winner, isNull);
      async.elapse(const Duration(seconds: 1));
      expect(hits, ['a', 'b']);
      expect(winner, 'b');
    });
  });

  test('throws an AppException once every mirror has failed', () async {
    final client = MockClient((_) async => http.Response('nope', 500));
    final service = OverpassService(client: client, mirrors: _mirrors);
    expect(
      () => service.findNearby(cafe, center),
      throwsA(isA<ServerException>()),
    );
  });

  test('offline everywhere is reported as OfflineException', () async {
    final client = MockClient(
      (_) async => throw const SocketException('no route'),
    );
    final service = OverpassService(client: client, mirrors: _mirrors);
    expect(
      () => service.findNearby(cafe, center),
      throwsA(isA<OfflineException>()),
    );
  });
}
