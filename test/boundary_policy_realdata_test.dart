import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/basemap_style.dart';
import 'package:open_maps/services/boundary_policy.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

/// Real OpenFreeMap tiles (planet 2026-08-23) covering the areas the policy
/// is about; see README "International boundaries". `outline` says whether
/// India's embedded outline certainly crosses the tile's core.
const _fixtures = {
  '6_45_25': (name: 'Kashmir (z6)', outline: true),
  '6_46_25': (name: 'Aksai Chin (z6)', outline: true),
  '6_48_26': (name: 'Arunachal Pradesh (z6)', outline: true),
  '8_182_102': (name: 'Kashmir / LoC (z8)', outline: false),
  '8_184_101': (name: 'Aksai Chin / LAC (z8)', outline: true),
  '8_194_107': (name: 'Arunachal Pradesh (z8)', outline: false),
};

const _indiaWords = [
  'india',
  'kashmir',
  'jammu',
  'ladakh',
  'arunachal',
  'gilgit',
  'azad',
  'khyber',
  'control',
];

/// The app's own theme (liberty through the same transforms the app applies),
/// so the decoded tile is exactly what the renderer would see.
final _theme = ThemeReader().read(
  prepareStyleJson(
    jsonDecode(File('test/fixtures/liberty.json').readAsStringSync())
        as Map<String, dynamic>,
  ),
);

TileData _decode(Uint8List bytes) => TileFactory(
  _theme,
  const Logger.noop(),
).createTileData(VectorTileReader().read(bytes));

TileData _fixture(String key) =>
    _decode(File('test/fixtures/boundary/$key.pbf').readAsBytesSync());

List<TileDataFeature> _boundaries(TileData d) => d.layers
    .where((l) => l.name == 'boundary')
    .expand((l) => l.features)
    .toList();

String _norm(Map<String, dynamic> p) =>
    '${p['disputed_name'] ?? ''} ${p['name'] ?? ''}'.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );

/// The injected outline: an international boundary with none of
/// OpenStreetMap's tags.
bool _isOutline(TileDataFeature f) =>
    f.properties['admin_level'] == 2 &&
    f.properties['disputed'] == 0 &&
    !f.properties.containsKey('adm0_l') &&
    !f.properties.containsKey('adm0_r') &&
    !f.properties.containsKey('name') &&
    !f.properties.containsKey('disputed_name');

int _pointCount(TileDataFeature f) =>
    f.hasLines ? f.lines.fold(0, (n, l) => n + l.points.length) : 0;

void main() {
  for (final entry in _fixtures.entries) {
    test('India boundary policy on real tile ${entry.value.name}', () {
      final parts = entry.key.split('_').map(int.parse).toList();
      final tile = TileIdentity(parts[0], parts[1], parts[2]);
      final before = _boundaries(_fixture(entry.key));
      final after = _boundaries(
        indiaBoundaryPolicy(tile, 'openmaptiles', _fixture(entry.key)),
      );
      final outline = after.where(_isOutline).toList();
      final rest = after.where((f) => !_isOutline(f)).toList();

      // ignore: avoid_print
      print(
        '${entry.value.name}: ${before.length} -> ${after.length} boundary '
        'features, outline ${outline.map(_pointCount).toList()} points\n'
        '  still disputed: '
        '${rest.where((f) => f.properties['disputed'] == 1).map((f) => f.properties['disputed_name'] ?? f.properties['name']).toList()}',
      );

      // At most one outline feature per sector; where the outline crosses
      // the tile it is there and substantial.
      expect(outline.length, lessThanOrEqualTo(2));
      if (entry.value.outline) {
        expect(outline, isNotEmpty);
        expect(
          outline.map(_pointCount).reduce((a, b) => a + b),
          greaterThan(20),
        );
      }

      // Nothing India-related is still marked disputed or claimed (India's
      // own claim lines survive as plain boundaries), and rival claims that
      // survive are somebody else's dispute (China's on Bhutan).
      for (final f in rest) {
        final p = f.properties;
        expect(p['claimed_by'], isNot('IN'));
        if (p['disputed'] != 1) continue;
        expect(
          _indiaWords.any(_norm(p).contains),
          isFalse,
          reason: 'still drawn as disputed: ${p['disputed_name'] ?? p['name']}',
        );
        if (const ['CN', 'PK'].contains(p['claimed_by'])) {
          expect(
            _norm(p).contains('bhutan') || _norm(p).contains('bt-cn'),
            isTrue,
            reason: 'rival claim kept: ${p['disputed_name']}',
          );
        }
      }

      // Undisputed state and district lines are untouched.
      int minor(Iterable<TileDataFeature> fs) => fs
          .where((f) => f.properties['disputed'] != 1)
          .where((f) => (f.properties['admin_level'] as int? ?? 2) > 2)
          .map(_pointCount)
          .fold(0, (a, b) => a + b);
      expect(minor(rest), greaterThanOrEqualTo(minor(before)));
    });
  }

  test('Pakistan\'s state labels inside the outline are not drawn', () {
    final tile = TileIdentity(6, 45, 25);
    List<String> states(TileData d) => d.layers
        .where((l) => l.name == 'place')
        .expand((l) => l.features)
        .where((f) => f.properties['class'] == 'state')
        .map((f) => f.properties['name:en'] as String)
        .toList();
    final before = states(_fixture('6_45_25'));
    final after = states(
      indiaBoundaryPolicy(tile, 'openmaptiles', _fixture('6_45_25')),
    );
    expect(before, containsAll(['Azad Kashmir', 'Gilgit-Baltistan']));
    expect(after, isNot(contains('Azad Kashmir')));
    expect(after, isNot(contains('Gilgit-Baltistan')));
    expect(after, containsAll(['Jammu and Kashmir', 'Ladakh', 'Punjab']));
  });

  test('the fixtures contain what the policy is for', () {
    var inClaims = 0, rivals = 0, deFacto = 0;
    for (final key in _fixtures.keys) {
      for (final f in _boundaries(_fixture(key))) {
        final p = f.properties;
        if (p['disputed'] != 1) continue;
        final c = p['claimed_by'] as String?;
        if (c == 'IN') inClaims++;
        if (c == 'CN' || c == 'PK') rivals++;
        if (c == null && _indiaWords.any(_norm(p).contains)) deFacto++;
      }
    }
    expect(inClaims, greaterThan(0));
    expect(rivals, greaterThan(0));
    expect(deFacto, greaterThan(0));
  });
}
