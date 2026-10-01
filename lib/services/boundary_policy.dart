import 'dart:math' as math;

import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'india_boundary_data.dart';

/// How international boundaries are drawn.
///
/// ZamosaRide is distributed in India, where maps must show the country's
/// external boundaries as the Government of India depicts them (Survey of
/// India): the whole of Jammu & Kashmir, Ladakh (including Aksai Chin and the
/// Trans-Karakoram tract) and Arunachal Pradesh inside India's international
/// border, with no competing claim lines, Line of Control or Line of Actual
/// Control drawn as boundaries. See [indiaBoundaryPolicy].
///
/// Boundaries elsewhere in the world are left exactly as OpenStreetMap maps
/// them.
enum BoundaryWorldview { india }

/// The worldview the app ships with.
const kBoundaryWorldview = BoundaryWorldview.india;

/// Country whose claims are drawn as boundaries.
const _claimant = 'IN';

/// Countries whose claim lines in the disputed areas are hidden.
const _rivalClaimants = {'CN', 'PK'};

/// The areas India claims that are administered or claimed by others. Claim
/// lines of [_rivalClaimants] and unattributed disputed lines inside them are
/// hidden.
const kIndiaDisputedRegions = [
  // Jammu & Kashmir, Gilgit-Baltistan, Ladakh, Aksai Chin, Shaksgam.
  _Box(west: 72.0, south: 32.0, east: 80.5, north: 37.6),
  // Arunachal Pradesh.
  _Box(west: 91.6, south: 26.6, east: 97.6, north: 29.6),
];

/// Lines inside [kIndiaDisputedRegions] that are somebody else's dispute
/// and stay as OpenStreetMap maps them.
const _foreignDisputeWords = ['bhutan', 'nepal', 'afghan', 'tajik'];

/// De-facto lines (control lines, cease-fire lines, other countries'
/// internal boundaries) in the disputed areas. OpenStreetMap names them;
/// a line whose lower-cased, whitespace-free name contains any of these is
/// not drawn wherever it is.
const kHiddenBoundaryLineNames = [
  'india',
  'kashmir',
  'jammu',
  'ladakh',
  'arunachal',
  'gilgit',
  'azad',
  'khyber',
  'lineofcontrol',
  'lineofactualcontrol',
  'actualgroundposition',
  'chineseclaim',
  'chinaclaim',
  "china'sclaim",
  '(loc)',
  '(lac)',
  '藏新界', // Tibet–Xinjiang boundary through Aksai Chin
  'کشمیر', // Kashmir (Urdu)
];

/// First-level administrative units of other countries inside India's
/// boundary. Their `state` labels are not drawn (the cities are).
const kHiddenStateLabels = [
  'azad kashmir',
  'azad jammu',
  'gilgit-baltistan',
  'gilgit baltistan',
  'آزاد کشمیر',
  'گلگت بلتستان',
];

/// Degrees of latitude per kilometre.
const _degPerKm = 1 / 111.0;

/// A disputed or de-facto line this close to India's outline is the same
/// border in another dataset's geometry: it is dropped and the outline drawn
/// instead.
const _disputedMargin = 8 * _degPerKm;

/// An undisputed international boundary this close to India's outline is the
/// same border (Afghanistan, the Himachal–Tibet border, the tripoints, …):
/// OpenStreetMap's line is kept and the outline is not drawn beside it.
const _sharedMargin = 5 * _degPerKm;

/// The end of a drawn stretch of the outline is joined to a kept
/// international boundary this close to it. Larger than [_sharedMargin] plus
/// the outline's vertex spacing, and than the distance between the two
/// datasets' versions of a tripoint (7 km at the Wakhan corridor).
const _joinDistance = 12 * _degPerKm;

/// A [TileDataTransform] implementing [BoundaryWorldview.india] on the
/// OpenMapTiles `boundary` and `place` layers.
///
/// OpenStreetMap maps the de-facto lines (the Line of Control, the Line of
/// Actual Control, the 1963 China–Pakistan line, Pakistan's and China's
/// internal boundaries in the area) and tags them `disputed`, but it does not
/// contain India's claimed outline as a line, and the Natural Earth data used
/// below zoom 5 has no claim tags at all. So the rule is geometric: India's
/// outline in the two affected sectors ([kIndiaOutlineKashmir],
/// [kIndiaOutlineArunachal], from Natural Earth's India point-of-view data)
/// is embedded, and
///
/// * lines India claims (`claimed_by` includes `IN`) become ordinary
///   boundaries;
/// * disputed lines that India does not claim are dropped where they run
///   inside that outline or along it, where they are named for India's
///   disputes ([kHiddenBoundaryLineNames]), or where they are claims of China
///   or Pakistan (or unattributed) inside [kIndiaDisputedRegions];
/// * undisputed international boundaries inside the outline (the de-facto
///   lines in the Natural Earth data below zoom 5) are dropped, except along
///   the outline itself where they are the same border;
/// * the outline is drawn as an ordinary international boundary wherever no
///   kept international boundary already runs along it, and each drawn
///   stretch is joined to the nearest kept boundary at its ends, so
///   OpenStreetMap's more precise geometry is used wherever it exists;
/// * `state` labels of Pakistan's units in the area ([kHiddenStateLabels])
///   are dropped;
/// * every other feature, and every other layer, is untouched.
///
/// Top-level so it can be sent to the decoding isolates.
TileData indiaBoundaryPolicy(TileIdentity tile, String source, TileData data) {
  var changed = false;
  var hasBoundary = false;
  final layers = <TileDataLayer>[];
  for (final layer in data.layers) {
    final TileDataLayer? out;
    if (layer.name == 'boundary') {
      hasBoundary = true;
      out = _boundaryLayer(tile, layer);
    } else if (layer.name == 'place') {
      out = _placeLayer(layer);
    } else {
      out = null;
    }
    if (out != null) changed = true;
    layers.add(out ?? layer);
  }
  if (!hasBoundary) {
    // A source tile with no boundaries at all may still be crossed by the
    // outline (the Kunlun stretch north of Aksai Chin).
    final extent = data.layers.isEmpty ? 4096 : data.layers.first.extent;
    final out = _boundaryLayer(
      tile,
      TileDataLayer(name: 'boundary', extent: extent, features: const []),
    );
    if (out != null) {
      layers.add(out);
      changed = true;
    }
  }
  return changed ? TileData(layers: layers) : data;
}

TileDataLayer? _boundaryLayer(TileIdentity tile, TileDataLayer layer) {
  final proj = _Projection(tile, layer.extent);
  final tileBox = proj.tileBox(margin: 0.25);
  final core = proj.tileBox(margin: 0);
  final sectors = _sectors
      .where((s) => s.box.intersects(tileBox))
      .toList(growable: false);
  final kept = <TileDataFeature>[];
  // Kept international boundaries, for suppressing and joining the outline.
  final international = <_Polyline>[];
  var changed = false;

  for (final feature in layer.features) {
    final props = feature.properties;
    final claimants = _claimants(props['claimed_by']);
    var disputed = props['disputed'] == 1;
    if (disputed && claimants.contains(_claimant)) {
      // India's claim: an ordinary boundary.
      props['disputed'] = 0;
      props.remove('claimed_by');
      disputed = false;
      changed = true;
    }
    final level = props['admin_level'];
    final isInternational = level == 2 || level == null;

    bool Function(_LL)? drop;
    if (disputed) {
      final name = _name(props);
      if (kHiddenBoundaryLineNames.any(name.contains)) {
        changed = true;
        continue;
      }
      final foreign = _foreignDisputeWords.any(name.contains);
      final rival =
          claimants.isEmpty || claimants.any(_rivalClaimants.contains);
      drop = (p) =>
          sectors.any(
            (s) => s.contains(p) || s.nearOutline(p, _disputedMargin),
          ) ||
          (rival &&
              !foreign &&
              kIndiaDisputedRegions.any((r) => r.contains(p)));
    } else if (isInternational && sectors.isNotEmpty) {
      drop = (p) =>
          sectors.any((s) => s.contains(p) && !s.nearOutline(p, _sharedMargin));
    }

    Iterable<TileLine>? lines;
    if (drop != null && feature.hasLines) {
      final clipped = _clipLines(feature.lines, proj, drop);
      if (clipped != null) {
        changed = true;
        if (clipped.isEmpty) continue;
        lines = clipped;
        kept.add(
          TileDataFeature(
            type: TileFeatureType.linestring,
            properties: props,
            geometry: null,
            lines: clipped,
          ),
        );
      }
    }
    if (lines == null) {
      kept.add(feature);
      if (feature.hasLines) lines = feature.lines;
    }
    if (lines != null && isInternational && !disputed && sectors.isNotEmpty) {
      for (final line in lines) {
        if (line.points.length < 2) continue;
        international.add(
          _Polyline([for (final p in line.points) proj.toLonLat(p.x, p.y)]),
        );
      }
    }
  }

  for (final sector in sectors) {
    final lines = <TileLine>[];
    for (final piece in sector.clip(tileBox)) {
      for (final stretch in _unshared(piece, international, sector.cosLat)) {
        if (core.contains(stretch.first)) {
          final q = _nearestPoint(
            international,
            stretch.first,
            sector.cosLat,
            _joinDistance,
          );
          if (q != null) stretch.insert(0, q);
        }
        if (core.contains(stretch.last)) {
          final q = _nearestPoint(
            international,
            stretch.last,
            sector.cosLat,
            _joinDistance,
          );
          if (q != null) stretch.add(q);
        }
        lines.add(TileLine([for (final p in stretch) proj.toTile(p)]));
      }
    }
    if (lines.isEmpty) continue;
    kept.add(
      TileDataFeature(
        type: TileFeatureType.linestring,
        properties: {'admin_level': 2, 'disputed': 0, 'maritime': 0},
        geometry: null,
        lines: lines,
      ),
    );
    changed = true;
  }

  if (!changed) return null;
  return TileDataLayer(name: layer.name, extent: layer.extent, features: kept);
}

TileDataLayer? _placeLayer(TileDataLayer layer) {
  final kept = layer.features
      .where((f) {
        final props = f.properties;
        final cls = props['class'];
        if (cls != 'state' && cls != 'province') return true;
        final name = '${props['name:en'] ?? ''}|${props['name'] ?? ''}'
            .toLowerCase();
        return !kHiddenStateLabels.any(name.contains);
      })
      .toList(growable: false);
  if (kept.length == layer.features.length) return null;
  return TileDataLayer(name: layer.name, extent: layer.extent, features: kept);
}

/// Drops every segment whose midpoint [drop] accepts. Returns null when
/// nothing was dropped, otherwise the remaining lines (possibly none).
List<TileLine>? _clipLines(
  Iterable<TileLine> lines,
  _Projection proj,
  bool Function(_LL) drop,
) {
  final out = <TileLine>[];
  var changed = false;
  for (final line in lines) {
    final pts = line.points;
    List<TilePoint>? current;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final mid = proj.toLonLat((a.x + b.x) / 2, (a.y + b.y) / 2);
      if (drop(mid)) {
        changed = true;
        if (current != null) out.add(TileLine(current));
        current = null;
      } else {
        (current ??= [a]).add(b);
      }
    }
    if (current != null) out.add(TileLine(current));
  }
  return changed ? out : null;
}

/// The stretches of [piece] that do not run within [_sharedMargin] of a kept
/// international boundary.
List<List<_LL>> _unshared(
  List<_LL> piece,
  List<_Polyline> international,
  double cosLat,
) {
  if (international.isEmpty) return [piece];
  final out = <List<_LL>>[];
  List<_LL>? current;
  for (var i = 1; i < piece.length; i++) {
    final a = piece[i - 1], b = piece[i];
    final mid = _LL((a.lon + b.lon) / 2, (a.lat + b.lat) / 2);
    if (_nearestPoint(international, mid, cosLat, _sharedMargin) != null) {
      if (current != null) out.add(current);
      current = null;
    } else {
      (current ??= [a]).add(b);
    }
  }
  if (current != null) out.add(current);
  return out;
}

/// The point on [lines] nearest to [p], if within [maxDistance] degrees.
_LL? _nearestPoint(
  List<_Polyline> lines,
  _LL p,
  double cosLat,
  double maxDistance,
) {
  _LL? best;
  var bestD2 = maxDistance * maxDistance;
  final px = p.lon * cosLat, py = p.lat;
  for (final line in lines) {
    if (!line.box.grow(maxDistance).contains(p)) continue;
    final pts = line.points;
    for (var i = 1; i < pts.length; i++) {
      final ax = pts[i - 1].lon * cosLat, ay = pts[i - 1].lat;
      final bx = pts[i].lon * cosLat, by = pts[i].lat;
      final vx = bx - ax, vy = by - ay;
      final len2 = vx * vx + vy * vy;
      var t = len2 == 0 ? 0.0 : ((px - ax) * vx + (py - ay) * vy) / len2;
      t = t.clamp(0.0, 1.0);
      final qx = ax + t * vx, qy = ay + t * vy;
      final dx = qx - px, dy = qy - py;
      final d2 = dx * dx + dy * dy;
      if (d2 < bestD2) {
        bestD2 = d2;
        best = _LL(qx / cosLat, qy);
      }
    }
  }
  return best;
}

Set<String> _claimants(Object? value) {
  if (value is! String || value.isEmpty) return const {};
  return value
      .split(RegExp(r'[;,]'))
      .map((s) => s.trim().toUpperCase())
      .where((s) => s.isNotEmpty)
      .toSet();
}

String _name(Map<String, dynamic> props) =>
    '${props['disputed_name'] ?? ''} ${props['name'] ?? ''}'
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '');

class _LL {
  final double lon, lat;
  const _LL(this.lon, this.lat);
}

class _Box {
  final double west, south, east, north;
  const _Box({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  static _Box of(Iterable<_LL> pts) {
    var w = double.infinity, s = double.infinity;
    var e = double.negativeInfinity, n = double.negativeInfinity;
    for (final p in pts) {
      w = math.min(w, p.lon);
      e = math.max(e, p.lon);
      s = math.min(s, p.lat);
      n = math.max(n, p.lat);
    }
    return _Box(west: w, south: s, east: e, north: n);
  }

  bool contains(_LL p) =>
      p.lon >= west && p.lon <= east && p.lat >= south && p.lat <= north;

  bool intersects(_Box o) =>
      o.west <= east && o.east >= west && o.south <= north && o.north >= south;

  bool intersectsSegment(_LL a, _LL b) =>
      math.min(a.lon, b.lon) <= east &&
      math.max(a.lon, b.lon) >= west &&
      math.min(a.lat, b.lat) <= north &&
      math.max(a.lat, b.lat) >= south;

  _Box grow(double d) =>
      _Box(west: west - d, south: south - d, east: east + d, north: north + d);
}

class _Polyline {
  final List<_LL> points;
  final _Box box;
  _Polyline(this.points) : box = _Box.of(points);
}

/// A stretch of India's outline: drawn as an international boundary, and —
/// when [ring] closes it through Indian territory — the area inside which
/// other international lines are not.
class _Sector {
  final List<_LL> outline;
  final List<_LL>? ring;
  final _Box box;
  final double cosLat;

  _Sector(List<double> lonLat, {List<_LL> closing = const []})
    : this._(_pairs(lonLat), closing);

  _Sector._(this.outline, List<_LL> closing)
    : ring = closing.isEmpty ? null : [...outline, ...closing],
      box = _Box.of([...outline, ...closing]).grow(_disputedMargin),
      cosLat = math.cos(
        (_Box.of(outline).north + _Box.of(outline).south) / 2 * math.pi / 180,
      );

  static List<_LL> _pairs(List<double> v) => [
    for (var i = 0; i + 1 < v.length; i += 2) _LL(v[i], v[i + 1]),
  ];

  /// Whether [p] lies inside the closed ring (ray casting).
  bool contains(_LL p) {
    final ring = this.ring;
    if (ring == null || !box.contains(p)) return false;
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i], b = ring[j];
      if ((a.lat > p.lat) != (b.lat > p.lat)) {
        final x = (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon;
        if (p.lon < x) inside = !inside;
      }
    }
    return inside;
  }

  /// Whether [p] is within [d] degrees (latitude-equivalent) of the outline.
  bool nearOutline(_LL p, double d) {
    if (!box.contains(p)) return false;
    final d2 = d * d;
    final px = p.lon * cosLat, py = p.lat;
    for (var i = 1; i < outline.length; i++) {
      final ax = outline[i - 1].lon * cosLat, ay = outline[i - 1].lat;
      final bx = outline[i].lon * cosLat, by = outline[i].lat;
      final vx = bx - ax, vy = by - ay;
      final len2 = vx * vx + vy * vy;
      var t = len2 == 0 ? 0.0 : ((px - ax) * vx + (py - ay) * vy) / len2;
      t = t.clamp(0.0, 1.0);
      final dx = ax + t * vx - px, dy = ay + t * vy - py;
      if (dx * dx + dy * dy < d2) return true;
    }
    return false;
  }

  /// The runs of consecutive outline segments that touch [box].
  List<List<_LL>> clip(_Box box) {
    final pieces = <List<_LL>>[];
    List<_LL>? current;
    for (var i = 1; i < outline.length; i++) {
      final a = outline[i - 1], b = outline[i];
      if (box.intersectsSegment(a, b)) {
        (current ??= [a]).add(b);
      } else if (current != null) {
        pieces.add(current);
        current = null;
      }
    }
    if (current != null) pieces.add(current);
    return pieces;
  }
}

/// Built once per isolate.
final _sectors = [
  // Round Jammu & Kashmir, Gilgit-Baltistan, the Trans-Karakoram tract and
  // Aksai Chin, then down the Himachal Pradesh and Uttarakhand border with
  // Tibet to the Nepal border; closed back through Uttarakhand, Himachal
  // Pradesh and Punjab.
  _Sector(
    kIndiaOutlineKashmir,
    closing: const [
      _LL(80.0, 29.9), // Pithoragarh
      _LL(79.5, 30.1), // Bageshwar
      _LL(79.0, 30.6), // Chamoli
      _LL(78.5, 31.0), // Uttarkashi
      _LL(78.3, 31.8), // Kinnaur
      _LL(77.5, 32.1), // Kullu
      _LL(76.5, 32.35), // Kangra
      _LL(75.7, 32.33), // Pathankot
    ],
  ),
  // The McMahon line. India administers everything south of it, so there
  // is no interior to clear; China's claim lines carry `claimed_by=CN`.
  _Sector(kIndiaOutlineArunachal),
];

/// Web Mercator tile-local coordinates (0..extent) <-> WGS84.
class _Projection {
  final TileIdentity tile;
  final int extent;
  final double n;
  _Projection(this.tile, this.extent) : n = math.pow(2, tile.z).toDouble();

  _LL toLonLat(double x, double y) {
    final lon = (tile.x + x / extent) / n * 360 - 180;
    final t = math.pi * (1 - 2 * (tile.y + y / extent) / n);
    final lat = math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi;
    return _LL(lon, lat);
  }

  TilePoint toTile(_LL p) {
    final x = ((p.lon + 180) / 360 * n - tile.x) * extent;
    final phi = p.lat * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(phi) + 1 / math.cos(phi)) / math.pi) / 2 * n -
            tile.y) *
        extent;
    return TilePoint(x, y);
  }

  /// The tile's bounds, grown by [margin] tile widths on every side.
  _Box tileBox({required double margin}) {
    final sw = toLonLat(-margin * extent, (1 + margin) * extent);
    final ne = toLonLat((1 + margin) * extent, -margin * extent);
    return _Box(west: sw.lon, south: sw.lat, east: ne.lon, north: ne.lat);
  }
}
