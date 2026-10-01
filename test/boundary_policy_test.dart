import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/boundary_policy.dart';
import 'package:open_maps/services/india_boundary_data.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

/// z6 tiles over Kashmir (lon 73–79, lat 32–37), Arunachal Pradesh
/// (lon 90–96, lat 27–32) and Spain; a z8 tile north of Aksai Chin that has
/// no boundaries in OpenStreetMap but is crossed by India's outline.
final kashmir = TileIdentity(6, 45, 25);
final arunachal = TileIdentity(6, 48, 26);
final spain = TileIdentity(6, 31, 24);
final kunlun = TileIdentity(8, 184, 100);

const _extent = 4096;

/// WGS84 -> tile-local coordinates of [tile].
TilePoint _tilePoint(TileIdentity tile, double lon, double lat) {
  final n = math.pow(2, tile.z).toDouble();
  final x = ((lon + 180) / 360 * n - tile.x) * _extent;
  final phi = lat * math.pi / 180;
  final y =
      ((1 - math.log(math.tan(phi) + 1 / math.cos(phi)) / math.pi) / 2 * n -
          tile.y) *
      _extent;
  return TilePoint(x, y);
}

TileDataFeature _line(
  Map<String, dynamic> props, {
  required TileIdentity tile,
  required List<(double, double)> lonLat,
}) => TileDataFeature(
  type: TileFeatureType.linestring,
  properties: props,
  geometry: null,
  lines: [
    TileLine([for (final (lon, lat) in lonLat) _tilePoint(tile, lon, lat)]),
  ],
);

TileDataFeature _point(Map<String, dynamic> props) => TileDataFeature(
  type: TileFeatureType.point,
  properties: props,
  geometry: null,
  points: [const TilePoint(100, 100)],
);

TileData _tile({
  List<TileDataFeature> boundaries = const [],
  List<TileDataFeature>? places,
  bool boundaryLayer = true,
}) => TileData(
  layers: [
    if (boundaryLayer)
      TileDataLayer(name: 'boundary', extent: _extent, features: boundaries),
    if (places != null)
      TileDataLayer(name: 'place', extent: _extent, features: places),
    TileDataLayer(
      name: 'water',
      extent: _extent,
      features: [
        _line(
          {'class': 'river', 'disputed': 1},
          tile: spain,
          lonLat: _spainLine,
        ),
      ],
    ),
  ],
);

const _spainLine = [(-4.0, 40.0), (-3.0, 41.0)];

List<TileDataFeature> _boundaries(TileData data) =>
    data.layers.firstWhere((l) => l.name == 'boundary').features;

List<Map<String, dynamic>> _props(TileData data) =>
    _boundaries(data).map((f) => f.properties).toList();

/// The injected outline: an international boundary with no OpenStreetMap
/// country tags.
bool _isOutline(TileDataFeature f) =>
    f.properties['admin_level'] == 2 &&
    f.properties['disputed'] == 0 &&
    !f.properties.containsKey('adm0_l') &&
    !f.properties.containsKey('claimed_by') &&
    !f.properties.containsKey('name');

/// Vertices of [outline] inside the tile's core.
List<(double, double)> _outlineIn(TileIdentity tile, List<double> outline) => [
  for (var i = 0; i + 1 < outline.length; i += 2)
    if (_inCore(tile, outline[i], outline[i + 1])) (outline[i], outline[i + 1]),
];

bool _inCore(TileIdentity tile, double lon, double lat) {
  final p = _tilePoint(tile, lon, lat);
  return p.x >= 0 && p.x <= _extent && p.y >= 0 && p.y <= _extent;
}

void main() {
  group('tag rules, away from the outline', () {
    test('India-claimed lines become regular boundaries', () {
      final out = indiaBoundaryPolicy(
        spain,
        'openmaptiles',
        _tile(
          boundaries: [
            for (final level in [2, 4, 2])
              _line(
                {
                  'admin_level': level,
                  'disputed': 1,
                  'claimed_by': level == 4 ? 'IN' : 'IN;PK',
                },
                tile: spain,
                lonLat: _spainLine,
              ),
          ],
        ),
      );
      final props = _props(out);
      expect(props, hasLength(3));
      for (final p in props) {
        expect(p['disputed'], 0);
        expect(p.containsKey('claimed_by'), isFalse);
      }
    });

    test('lines named for India\'s disputes are hidden anywhere', () {
      final out = indiaBoundaryPolicy(
        spain,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {
                'admin_level': 2,
                'disputed': 1,
                'disputed_name': 'Line of Control',
              },
              tile: spain,
              lonLat: _spainLine,
            ),
            _line(
              {'admin_level': 4, 'disputed': 1, 'name': 'Jammu and Kashmir'},
              tile: spain,
              lonLat: _spainLine,
            ),
            _line(
              {
                'admin_level': 2,
                'disputed': 1,
                'disputed_name': 'Western Sahara',
                'claimed_by': 'MA',
              },
              tile: spain,
              lonLat: _spainLine,
            ),
          ],
        ),
      );
      expect(_props(out).map((p) => p['disputed_name']), ['Western Sahara']);
    });

    test('rival claims inside the disputed regions are hidden', () {
      // The foothills of Arunachal Pradesh: far from the McMahon line.
      const foothills = [(93.0, 27.0), (94.0, 27.05)];
      final out = indiaBoundaryPolicy(
        arunachal,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {
                'admin_level': 2,
                'disputed': 1,
                'claimed_by': 'CN',
                'disputed_name': 'Arunachal Pradesh',
              },
              tile: arunachal,
              lonLat: foothills,
            ),
            _line(
              {'admin_level': 2, 'disputed': 1},
              tile: arunachal,
              lonLat: foothills,
            ),
            // Somebody else's dispute stays.
            _line(
              {
                'admin_level': 2,
                'disputed': 1,
                'claimed_by': 'CN',
                'disputed_name': 'Bhutan-China',
              },
              tile: arunachal,
              lonLat: [(91.0, 27.5), (91.1, 27.55)],
            ),
            _line(
              {
                'admin_level': 2,
                'disputed': 0,
                'adm0_l': 'IND',
                'adm0_r': 'BTN',
              },
              tile: arunachal,
              lonLat: [(91.8, 27.0), (91.9, 27.3)],
            ),
          ],
        ),
      );
      final names = _boundaries(out)
          .where((f) => !_isOutline(f))
          .map((f) => f.properties['disputed_name'])
          .toList();
      expect(names, ['Bhutan-China', null]);
    });
  });

  group('geometry rules', () {
    test('disputed lines along the outline are hidden', () {
      // The Line of Actual Control, a few kilometres inside Aksai Chin, and
      // a de-facto line right on the outline.
      final onOutline = _outlineIn(kashmir, kIndiaOutlineKashmir);
      final out = indiaBoundaryPolicy(
        kashmir,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {'admin_level': 2, 'disputed': 1},
              tile: kashmir,
              lonLat: [(78.7, 34.0), (78.9, 34.6)],
            ),
            _line(
              {'admin_level': 2, 'disputed': 1},
              tile: kashmir,
              lonLat: onOutline.sublist(0, 20),
            ),
          ],
        ),
      );
      expect(_boundaries(out).where((f) => !_isOutline(f)), isEmpty);
    });

    test('de-facto international lines inside the outline are hidden, '
        'state lines are not', () {
      // Roughly the Line of Control from Jammu to the Siachen area (the
      // Natural Earth data below zoom 5 has no `disputed` tag on it).
      const loc = [(74.3, 33.0), (74.0, 34.0), (75.0, 34.6), (77.0, 35.3)];
      final out = indiaBoundaryPolicy(
        kashmir,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {'admin_level': 2, 'disputed': 0},
              tile: kashmir,
              lonLat: loc,
            ),
            _line(
              {'admin_level': 4, 'disputed': 0},
              tile: kashmir,
              lonLat: loc,
            ),
          ],
        ),
      );
      final kept = _boundaries(out).where((f) => !_isOutline(f)).toList();
      expect(kept, hasLength(1));
      expect(kept.single.properties['admin_level'], 4);
    });

    test('a line crossing the outline is cut, not dropped', () {
      // Punjab's border with Pakistan, continuing north into the outline.
      final out = indiaBoundaryPolicy(
        kashmir,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {
                'admin_level': 2,
                'disputed': 0,
                'adm0_l': 'IND',
                'adm0_r': 'PAK',
              },
              tile: kashmir,
              lonLat: [(74.6, 32.0), (75.3, 32.3), (74.5, 33.5), (74.5, 34.5)],
            ),
          ],
        ),
      );
      final kept = _boundaries(out).where((f) => !_isOutline(f)).single;
      final line = kept.lines.single;
      expect(line.points, hasLength(2));
      expect(line.points.first, _tilePoint(kashmir, 74.6, 32.0));
    });

    test('the outline is drawn as an international boundary', () {
      final out = indiaBoundaryPolicy(kashmir, 'openmaptiles', _tile());
      final outline = _boundaries(out).where(_isOutline).single;
      expect(outline.properties, {
        'admin_level': 2,
        'disputed': 0,
        'maritime': 0,
      });
      final points = outline.lines.expand((l) => l.points).toList();
      // Through Gilgit-Baltistan and along the Kunlun north of Aksai Chin.
      expect(points.length, greaterThan(200));
      for (final (lon, lat) in [(73.98, 36.82), (79.96, 35.84)]) {
        expect(
          points.any((p) => (p - _tilePoint(kashmir, lon, lat)).magnitude < 50),
          isTrue,
          reason: 'outline misses ($lon, $lat)',
        );
      }
    });

    test('the outline is drawn even where the tile has no boundary layer', () {
      final out = indiaBoundaryPolicy(
        kunlun,
        'openmaptiles',
        _tile(boundaryLayer: false),
      );
      expect(_boundaries(out).where(_isOutline), hasLength(1));
    });

    test('the outline is not drawn beside an OpenStreetMap boundary', () {
      final vertices = _outlineIn(kunlun, kIndiaOutlineKashmir);
      final out = indiaBoundaryPolicy(
        kunlun,
        'openmaptiles',
        _tile(
          boundaries: [
            _line(
              {
                'admin_level': 2,
                'disputed': 0,
                'adm0_l': 'IND',
                'adm0_r': 'CHN',
              },
              tile: kunlun,
              lonLat: vertices,
            ),
          ],
        ),
      );
      final outline = _boundaries(out).where(_isOutline).toList();
      // Whatever is left is outside the tile (its buffer) or joins the
      // OpenStreetMap line's ends.
      for (final f in outline) {
        for (final line in f.lines) {
          for (final p in line.points) {
            final inCore =
                p.x >= 0 && p.x <= _extent && p.y >= 0 && p.y <= _extent;
            final nearEnd =
                (p - _tilePoint(kunlun, vertices.first.$1, vertices.first.$2))
                        .magnitude <
                    200 ||
                (p - _tilePoint(kunlun, vertices.last.$1, vertices.last.$2))
                        .magnitude <
                    200;
            expect(!inCore || nearEnd, isTrue, reason: 'outline drawn at $p');
          }
        }
      }
    });

    test(
      'a drawn stretch of the outline is joined to the boundary it meets',
      () {
        // The Radcliffe line, ending 3 km from where the outline starts.
        const end = (75.36, 32.34);
        final out = indiaBoundaryPolicy(
          kashmir,
          'openmaptiles',
          _tile(
            boundaries: [
              _line(
                {
                  'admin_level': 2,
                  'disputed': 0,
                  'adm0_l': 'IND',
                  'adm0_r': 'PAK',
                },
                tile: kashmir,
                lonLat: [(74.6, 31.9), (75.0, 32.1), end],
              ),
            ],
          ),
        );
        final outline = _boundaries(out).where(_isOutline).single;
        // Some drawn stretch starts or ends on the Radcliffe line's last
        // segment (the outline's own start is 3 km beside it, not on it).
        final a = _tilePoint(kashmir, 75.0, 32.1);
        final b = _tilePoint(kashmir, end.$1, end.$2);
        double toSegment(TilePoint p) {
          final v = b - a, w = p - a;
          final t = ((w.x * v.x + w.y * v.y) / (v.x * v.x + v.y * v.y)).clamp(
            0.0,
            1.0,
          );
          return (p - (a + v * t)).magnitude;
        }

        expect(
          outline.lines.any(
            (l) =>
                toSegment(l.points.first) < 1 || toSegment(l.points.last) < 1,
          ),
          isTrue,
        );
        expect(
          outline.lines
              .expand((l) => [l.points.first, l.points.last])
              .every((p) => toSegment(p) > 1 || (p - b).magnitude < 500),
          isTrue,
          reason: 'joined far from the end of the Radcliffe line',
        );
      },
    );
  });

  group('labels and untouched data', () {
    test('state labels of Pakistan\'s units inside the outline are hidden', () {
      final out = indiaBoundaryPolicy(
        kashmir,
        'openmaptiles',
        _tile(
          places: [
            _point({
              'class': 'state',
              'name': 'آزاد کشمیر',
              'name:en': 'Azad Kashmir',
            }),
            _point({'class': 'state', 'name:en': 'Gilgit-Baltistan'}),
            _point({'class': 'state', 'name:en': 'Jammu and Kashmir'}),
            _point({'class': 'city', 'name:en': 'Gilgit'}),
          ],
        ),
      );
      final names = out.layers
          .firstWhere((l) => l.name == 'place')
          .features
          .map((f) => f.properties['name:en'])
          .toList();
      expect(names, ['Jammu and Kashmir', 'Gilgit']);
    });

    test('nothing to change returns the same object', () {
      final input = _tile(
        boundaries: [
          _line(
            {'admin_level': 2, 'disputed': 0},
            tile: spain,
            lonLat: _spainLine,
          ),
        ],
        places: [
          _point({'class': 'state', 'name:en': 'Andalusia'}),
        ],
      );
      expect(
        identical(indiaBoundaryPolicy(spain, 'openmaptiles', input), input),
        isTrue,
      );
    });

    test('other layers are never touched', () {
      final out = indiaBoundaryPolicy(kashmir, 'openmaptiles', _tile());
      final water = out.layers.firstWhere((l) => l.name == 'water');
      expect(water.features, hasLength(1));
      expect(water.features.single.properties['disputed'], 1);
    });
  });
}
