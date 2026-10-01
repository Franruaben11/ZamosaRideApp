import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../util/geo.dart';
import 'api_client.dart';
import 'app_exception.dart';

/// A nearby-POI category, mapped to OSM tags queried via the Overpass API.
class PoiCategory {
  final String label;
  final String key;
  final String value;

  const PoiCategory(this.label, this.key, this.value);

  static const all = <PoiCategory>[
    PoiCategory('Restaurants', 'amenity', 'restaurant'),
    PoiCategory('Cafés', 'amenity', 'cafe'),
    PoiCategory('Fuel', 'amenity', 'fuel'),
    PoiCategory('Hotels', 'tourism', 'hotel'),
    PoiCategory('ATMs', 'amenity', 'atm'),
    PoiCategory('Pharmacies', 'amenity', 'pharmacy'),
    PoiCategory('Hospitals', 'amenity', 'hospital'),
    PoiCategory('Groceries', 'shop', 'supermarket'),
    PoiCategory('Parking', 'amenity', 'parking'),
    PoiCategory('EV charging', 'amenity', 'charging_station'),
  ];
}

/// Live nearby-place search against OpenStreetMap via the Overpass API.
///
/// Public Overpass instances are community-run and individually flaky, so a
/// request is hedged: the primary mirror gets a head start, then the others
/// race it; the first 200 wins and the rest are abandoned.
class OverpassService {
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
  ];

  static const _perMirrorTimeout = Duration(seconds: 8);
  static const _hedgeDelay = Duration(milliseconds: 2500);

  final http.Client _client;
  final List<String> _mirrors;

  OverpassService({http.Client? client, List<String>? mirrors})
    : _client = client ?? ApiClient.shared,
      _mirrors = mirrors ?? _endpoints;

  /// Finds up to [limit] places of [category] within [radiusMeters] of
  /// [center], nearest first.
  Future<List<Place>> findNearby(
    PoiCategory category,
    LatLng center, {
    int radiusMeters = 3000,
    int limit = 40,
  }) => guarded('Overpass $category', () async {
    final around =
        'around:$radiusMeters,'
        '${center.latitude.toStringAsFixed(6)},'
        '${center.longitude.toStringAsFixed(6)}';
    final tag = '["${category.key}"="${category.value}"]';
    final query =
        '[out:json][timeout:8];'
        '(node$tag($around);way$tag($around););'
        'out center $limit;';

    final body = await _hedged(query);
    final places = parseElements(body, category);
    places.sort(
      (a, b) => distanceMeters(
        center,
        a.point,
      ).compareTo(distanceMeters(center, b.point)),
    );
    return places;
  });

  /// Starts the next mirror either when the previous one fails or after
  /// [_hedgeDelay] without an answer; resolves with the first successful
  /// body, or throws the last error once every mirror has failed.
  Future<String> _hedged(String query) {
    final completer = Completer<String>();
    var next = 0;
    var inFlight = 0;
    Object lastError = const AppException('No Overpass mirror responded');
    Timer? hedge;

    void startNext() {
      hedge?.cancel();
      if (completer.isCompleted || next >= _mirrors.length) return;
      final endpoint = _mirrors[next++];
      inFlight++;
      if (next < _mirrors.length) hedge = Timer(_hedgeDelay, startNext);
      unawaited(() async {
        try {
          final r = await _client
              .post(Uri.parse(endpoint), body: {'data': query})
              .timeout(_perMirrorTimeout);
          if (r.statusCode == 200) {
            if (!completer.isCompleted) completer.complete(r.body);
            return;
          }
          lastError = ServerException(r.statusCode);
        } on Exception catch (e) {
          lastError = e;
        } finally {
          inFlight--;
          if (!completer.isCompleted) {
            if (next < _mirrors.length) {
              startNext();
            } else if (inFlight == 0) {
              completer.completeError(lastError);
            }
          }
        }
      }());
    }

    startNext();
    return completer.future.whenComplete(() => hedge?.cancel());
  }

  static List<Place> parseElements(String body, PoiCategory category) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final elements = json['elements'] as List<dynamic>? ?? const [];
    final places = <Place>[];
    for (final e in elements) {
      final el = e as Map<String, dynamic>;
      final tags = el['tags'] as Map<String, dynamic>? ?? const {};
      final lat = (el['lat'] ?? (el['center'] as Map?)?['lat']) as num?;
      final lon = (el['lon'] ?? (el['center'] as Map?)?['lon']) as num?;
      if (lat == null || lon == null) continue;

      final addr = <String?>[
        [
          tags['addr:housenumber'],
          tags['addr:street'],
        ].whereType<String>().join(' '),
        tags['addr:city'] as String?,
      ].whereType<String>().where((s) => s.isNotEmpty).join(', ');

      places.add(
        Place(
          name: tags['name'] as String? ?? category.label,
          address: addr.isEmpty ? null : addr,
          point: LatLng(lat.toDouble(), lon.toDouble()),
          category: category.value,
          phone: (tags['phone'] ?? tags['contact:phone']) as String?,
          website: (tags['website'] ?? tags['contact:website']) as String?,
          openingHours: tags['opening_hours'] as String?,
          wikidata: tags['wikidata'] as String?,
          imageUrl: tags['image'] as String?,
        ),
      );
    }
    return places;
  }
}
