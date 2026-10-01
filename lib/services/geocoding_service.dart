import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import 'api_client.dart';
import 'app_exception.dart';

/// Forward search via Photon (Komoot) and reverse geocoding via Nominatim —
/// both free, open-source, OpenStreetMap-backed services.
class GeocodingService {
  final http.Client _client;

  GeocodingService({http.Client? client})
    : _client = client ?? ApiClient.shared;

  /// Typo-tolerant autocomplete search, biased toward [near] when given.
  Future<List<Place>> search(String query, {LatLng? near}) =>
      guarded('Photon search', () async {
        final uri = Uri.https('photon.komoot.io', '/api/', {
          'q': query,
          'limit': '10',
          if (near != null) 'lat': near.latitude.toStringAsFixed(5),
          if (near != null) 'lon': near.longitude.toStringAsFixed(5),
        });
        final response = await _client
            .get(uri)
            .timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) {
          throw ServerException(response.statusCode);
        }
        return parsePhoton(response.body);
      });

  /// Resolves a coordinate to the nearest address / place name.
  Future<Place> reverse(LatLng point) => guarded('Nominatim reverse', () async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': point.latitude.toString(),
      'lon': point.longitude.toString(),
      'zoom': '18',
      'addressdetails': '1',
      'extratags': '1',
    });
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw ServerException(response.statusCode);
    }
    return parseNominatimReverse(response.body, point);
  });

  static List<Place> parsePhoton(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final features = json['features'] as List<dynamic>? ?? const [];
    final places = <Place>[];
    for (final f in features) {
      final feature = f as Map<String, dynamic>;
      final props = feature['properties'] as Map<String, dynamic>? ?? const {};
      final coords =
          (feature['geometry'] as Map<String, dynamic>?)?['coordinates']
              as List<dynamic>?;
      if (coords == null || coords.length < 2) continue;

      final name =
          props['name'] as String? ??
          [props['street'], props['housenumber']].whereType<String>().join(' ');
      if (name.isEmpty) continue;

      final addressParts = <String?>[
        if (props['name'] != null)
          [props['street'], props['housenumber']].whereType<String>().join(' '),
        props['district'] as String?,
        props['city'] as String?,
        props['state'] as String?,
        props['country'] as String?,
      ];
      final address = addressParts
          .whereType<String>()
          .where((s) => s.isNotEmpty && s != name)
          .toSet()
          .join(', ');

      places.add(
        Place(
          name: name,
          address: address.isEmpty ? null : address,
          point: LatLng(
            (coords[1] as num).toDouble(),
            (coords[0] as num).toDouble(),
          ),
          category: props['osm_value'] as String?,
        ),
      );
    }
    return places;
  }

  static Place parseNominatimReverse(String body, LatLng point) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final displayName = json['display_name'] as String?;
    final name = json['name'] as String?;
    final firstLine = (name != null && name.isNotEmpty)
        ? name
        : (displayName?.split(',').first.trim() ?? 'Dropped pin');

    var address = displayName;
    if (address != null && address.startsWith(firstLine)) {
      address = address.substring(firstLine.length).trim();
      if (address.startsWith(',')) address = address.substring(1).trim();
    }

    final extra = json['extratags'] as Map<String, dynamic>? ?? const {};
    return Place(
      name: firstLine,
      address: address,
      point: point,
      category: json['type'] as String?,
      phone: (extra['phone'] ?? extra['contact:phone']) as String?,
      website: (extra['website'] ?? extra['contact:website']) as String?,
      openingHours: extra['opening_hours'] as String?,
      wikidata: extra['wikidata'] as String?,
      imageUrl: extra['image'] as String?,
    );
  }
}
