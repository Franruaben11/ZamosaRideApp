import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/place.dart';
import 'api_client.dart';
import 'app_exception.dart';

/// Resolves a representative photo for a place from open sources:
/// the OSM `image` tag directly, Wikidata's image claim (P18) served via
/// Wikimedia Commons, or the lead image of a nearby Wikipedia article.
///
/// Results — including misses and failures — are cached per place so
/// re-selecting a place never re-queries Wikimedia.
class PhotoService {
  final http.Client _client;
  final Map<String, String?> _cache = {};

  /// Requested thumbnail width; the sheet shows it at ~150 px tall.
  static const thumbWidth = 640;

  PhotoService({http.Client? client}) : _client = client ?? ApiClient.shared;

  Future<String?> photoUrl(Place place) async {
    final direct = place.imageUrl;
    if (direct != null && direct.startsWith('http')) return direct;
    return await _wikidataPhoto(place) ?? await _wikipediaNearbyPhoto(place);
  }

  /// Wikipedia GeoSearch: find articles within ~300 m of the place and use
  /// the lead image of the one whose title matches best. Works purely from
  /// coordinates — no OSM tags needed.
  Future<String?> _wikipediaNearbyPhoto(Place place) async {
    final key =
        'geo:${place.point.latitude.toStringAsFixed(4)},${place.point.longitude.toStringAsFixed(4)}:${place.name}';
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
        'action': 'query',
        'format': 'json',
        'generator': 'geosearch',
        'ggscoord': '${place.point.latitude}|${place.point.longitude}',
        'ggsradius': '300',
        'ggslimit': '5',
        'prop': 'pageimages',
        'piprop': 'thumbnail',
        'pithumbsize': '$thumbWidth',
      });
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return _cache[key] = null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final pages =
          ((json['query'] as Map<String, dynamic>?)?['pages']
                  as Map<String, dynamic>?)
              ?.values
              .cast<Map<String, dynamic>>()
              .toList();
      if (pages == null || pages.isEmpty) return _cache[key] = null;

      final nameLower = place.name.toLowerCase();
      String? bestUrl;
      for (final page in pages) {
        final thumb =
            (page['thumbnail'] as Map<String, dynamic>?)?['source'] as String?;
        if (thumb == null) continue;
        final title = (page['title'] as String? ?? '').toLowerCase();
        final titleMatches =
            title.contains(nameLower) || nameLower.contains(title);
        if (titleMatches) return _cache[key] = thumb;
        bestUrl ??= thumb;
      }
      return _cache[key] = bestUrl;
    } on Exception catch (e, s) {
      logError('Wikipedia geosearch', e, s);
      // Cache the failure too: a flaky network shouldn't mean a request
      // per re-selection. The place is re-queried after an app restart.
      return _cache[key] = null;
    }
  }

  Future<String?> _wikidataPhoto(Place place) async {
    final wikidata = place.wikidata;
    if (wikidata == null) return null;
    if (_cache.containsKey(wikidata)) return _cache[wikidata];

    try {
      final uri = Uri.https(
        'www.wikidata.org',
        '/wiki/Special:EntityData/$wikidata.json',
      );
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return _cache[wikidata] = null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final entity =
          (json['entities'] as Map<String, dynamic>?)?[wikidata]
              as Map<String, dynamic>?;
      final claims = entity?['claims'] as Map<String, dynamic>?;
      final p18 = claims?['P18'] as List<dynamic>?;
      if (p18 == null || p18.isEmpty) return _cache[wikidata] = null;

      final mainsnak =
          (p18.first as Map<String, dynamic>)['mainsnak']
              as Map<String, dynamic>?;
      final datavalue = mainsnak?['datavalue'] as Map<String, dynamic>?;
      final file = datavalue?['value'] as String?;
      if (file == null) return _cache[wikidata] = null;

      final url =
          'https://commons.wikimedia.org/wiki/Special:FilePath/${Uri.encodeComponent(file)}?width=$thumbWidth';
      return _cache[wikidata] = url;
    } on Exception catch (e, s) {
      logError('Wikidata P18', e, s);
      return _cache[wikidata] = null;
    }
  }
}
