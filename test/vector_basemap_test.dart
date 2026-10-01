import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/basemap_style.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

void main() {
  late Map<String, dynamic> liberty;

  setUpAll(() {
    liberty =
        jsonDecode(File('test/fixtures/liberty.json').readAsStringSync())
            as Map<String, dynamic>;
  });

  test('liberty style re-grades to a parsable night theme', () {
    final night = nightifyStyleJson(prepareStyleJson(liberty));
    final theme = ThemeReader().read(night);
    expect(theme.layers.length, greaterThan(80));
    final layers = (night['layers'] as List).cast<Map<String, dynamic>>();
    final ids = layers.map((l) => l['id']).toList();
    expect(
      ids,
      containsAll([
        'poi_dots',
        'housenumber',
        'overture_poi_a',
        'overture_poi_c',
      ]),
    );
    final poi1 = layers.firstWhere((l) => l['id'] == 'poi_r1');
    expect(poi1['minzoom'], 13.5);
  });

  test('night re-grade darkens ground and lightens text', () {
    final night = nightifyStyleJson(prepareStyleJson(liberty));
    final layers = (night['layers'] as List).cast<Map<String, dynamic>>();

    final water = layers.firstWhere((l) => l['id'] == 'water');
    final waterColor = (water['paint'] as Map)['fill-color'] as String;
    expect(_lightness(waterColor), lessThan(0.25));

    final label = layers.firstWhere((l) => l['id'] == 'poi_r1');
    final textColor = (label['paint'] as Map)['text-color'] as String;
    expect(_lightness(textColor), greaterThan(0.5));
  });

  test('day and night styles keep the same layer ids in the same order', () {
    final day = prepareStyleJson(liberty);
    final night = nightifyStyleJson(day);
    List<Object?> ids(Map<String, dynamic> s) =>
        (s['layers'] as List).map((l) => (l as Map)['id']).toList();
    expect(ids(night), ids(day));
  });

  test('transforms do not mutate their input', () {
    final before = jsonEncode(liberty);
    nightifyStyleJson(prepareStyleJson(liberty));
    expect(jsonEncode(liberty), before);
  });
}

/// Perceived lightness (0–1) of an `rgba(r,g,b,a)` string.
double _lightness(String rgba) {
  final m = RegExp(r'rgba\((\d+),(\d+),(\d+)').firstMatch(rgba)!;
  final r = int.parse(m.group(1)!),
      g = int.parse(m.group(2)!),
      b = int.parse(m.group(3)!);
  final max = [r, g, b].reduce((a, b) => a > b ? a : b);
  final min = [r, g, b].reduce((a, b) => a < b ? a : b);
  return (max + min) / 2 / 255;
}
