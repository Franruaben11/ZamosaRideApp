import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Theme;
import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../services/api_client.dart';
import '../services/app_exception.dart';
import '../services/basemap_style.dart';
import '../services/boundary_policy.dart';
import '../services/pmtiles_provider.dart';
import '../services/render_quality.dart';

/// Subset of a style a [VectorBasemap.layer] draws. Used by foveated
/// rendering, which foveates geometry but draws labels full-screen so they
/// are never clipped at the window edge.
enum BasemapPart { all, geometry, symbols }

/// On-device rendered OpenStreetMap basemap (OpenFreeMap vector tiles,
/// free, no API key). Crisp at any DPI and carries the full OSM dataset:
/// POIs, building/road names, coloured road hierarchy, transit, etc.
///
/// Light mode uses the `liberty` style as-is. Dark mode takes the same
/// style JSON and re-grades every colour into a night palette on device,
/// so it keeps all the data the purpose-built dark styles drop.
///
/// The style JSON is fetched exactly once per process; the JSON transforms
/// run in a background isolate; per-part themes for foveated rendering are
/// compiled on first use.
class VectorBasemap {
  VectorBasemap._();

  static const styleUrl = 'https://tiles.openfreemap.org/styles/liberty';
  static const attribution =
      '© OpenMapTiles © OpenStreetMap contributors · Places & buildings © Overture Maps Foundation';

  /// Overture Maps hosted PMTiles (CDLA-Permissive-2.0 / ODbL). Places merge
  /// Meta, Microsoft, Foursquare and more — ~15x the POI density of OSM in
  /// Indian cities; buildings add Google/Microsoft open footprints.
  static const overtureRelease = '2026-08-19.0';
  static const _overtureBase =
      'https://overturemaps-extras-us-west-2.s3.us-west-2.amazonaws.com/tiles/$overtureRelease';

  static const _fetchTimeout = Duration(seconds: 15);

  static http.Client _client = ApiClient.shared;

  /// Test hook.
  @visibleForTesting
  static set client(http.Client c) => _client = c;

  static Future<Style>? _light;
  static Future<Style>? _dark;

  static Future<Style> light() =>
      _light ??= _loadLight().onError((Object e, StackTrace s) {
        _light = null;
        Error.throwWithStackTrace(e, s);
      });

  static Future<Style> dark() =>
      _dark ??= _loadDark().onError((Object e, StackTrace s) {
        _dark = null;
        Error.throwWithStackTrace(e, s);
      });

  /// Providers, sprites and prepared day JSON — fetched once, shared by both
  /// themes.
  static Future<_Base>? _base;

  static Future<_Base> _loadBase() => _base ??=
      () async {
        final json = await _fetchJson(styleUrl);
        final prepared = await compute(prepareStyleJson, json);
        final providers = await _readProviders(
          prepared['sources'] as Map<String, dynamic>? ?? const {},
        );
        final sprites = await _readSprites(prepared['sprite'] as String?);
        return _Base(prepared, providers, sprites);
      }().onError((Object e, StackTrace s) {
        _base = null;
        Error.throwWithStackTrace(e, s);
      });

  static Future<Style> _loadLight() async {
    final base = await _loadBase();
    return _split(base, base.json, 'liberty-day');
  }

  static Future<Style> _loadDark() async {
    final base = await _loadBase();
    final night = await compute(nightifyStyleJson, base.json);
    return _split(base, night, 'liberty-night');
  }

  static Future<Map<String, dynamic>> _fetchJson(String url) =>
      guarded('style $url', () async {
        final res = await _client.get(Uri.parse(url)).timeout(_fetchTimeout);
        if (res.statusCode != 200) throw ServerException(res.statusCode);
        final decoded = await compute(jsonDecode, res.body);
        if (decoded is! Map<String, dynamic>) {
          throw const BadResponseException(message: 'Style is not JSON');
        }
        return decoded;
      });

  static Map<String, String>? get _tileHeaders =>
      kIsWeb ? null : const {'User-Agent': kUserAgent};

  /// Mirrors vector_map_tiles' `StyleReader` without re-downloading the
  /// style: inline `tiles` sources are used directly, `url` (TileJSON)
  /// sources are resolved with one extra request.
  static Future<TileProviders> _readProviders(
    Map<String, dynamic> sources,
  ) async {
    final providers = <String, VectorTileProvider>{};
    for (final entry in sources.entries) {
      final source = entry.value;
      if (source is! Map) continue;
      final type = TileProviderType.values
          .where((e) => e.name.replaceAll('_', '-') == source['type'])
          .firstOrNull;
      if (type == null) continue;

      Map<dynamic, dynamic> resolved = source;
      final url = source['url'] as String?;
      if (url != null) resolved = await _fetchJson(url);

      final tiles = resolved['tiles'];
      if (tiles is! List || tiles.isEmpty) continue;
      providers[entry.key] = NetworkVectorTileProvider(
        type: type,
        urlTemplate: tiles.first as String,
        maximumZoom: (resolved['maxzoom'] as num?)?.toInt() ?? 14,
        minimumZoom: (resolved['minzoom'] as num?)?.toInt() ?? 1,
        // ignore: avoid_redundant_argument_values
        httpHeaders: _tileHeaders,
      );
    }
    if (providers.isEmpty) {
      throw const BadResponseException(message: 'Style has no tile sources');
    }
    return TileProviders(providers);
  }

  static Future<SpriteStyle?> _readSprites(String? spriteUri) async {
    if (spriteUri == null || spriteUri.trim().isEmpty) return null;
    for (final suffix in const ['@2x', '']) {
      try {
        final index = await _fetchJson('$spriteUri$suffix.json');
        final image = '$spriteUri$suffix.png';
        return SpriteStyle(
          atlasProvider: () async {
            final res = await _client
                .get(Uri.parse(image))
                .timeout(_fetchTimeout);
            if (res.statusCode != 200) throw ServerException(res.statusCode);
            return res.bodyBytes;
          },
          index: SpriteIndexReader().read(index),
        );
      } on Exception catch (e) {
        logError('sprite $spriteUri$suffix', e);
      }
    }
    return null; // Icons simply won't draw; labels and geometry still do.
  }

  /// Splits the style into the OSM basemap and an Overture overlay so the
  /// (much slower) Overture tiles never hold up roads and labels.
  static Style _split(_Base base, Map<String, dynamic> json, String name) {
    final layers = (json['layers'] as List).cast<Map<String, dynamic>>();
    bool isOverture(Map<String, dynamic> l) =>
        (l['source'] as String?)?.startsWith('overture_') ?? false;
    // Distinct ids matter: vector_map_tiles caches processed tiles by theme
    // id, so two layers sharing an id would corrupt each other's tiles.
    final baseJson = {
      ...json,
      'id': name,
      'layers': layers.where((l) => !isOverture(l)).toList(),
    };
    final overJson = {
      ...json,
      'id': '$name-overture',
      'layers': layers.where(isOverture).toList(),
    };
    _overlayByBase[name] = Style(
      name: '$name-overture',
      theme: ThemeReader().read(overJson),
      providers: TileProviders({
        'overture_places': PmTilesVectorTileProvider.forUri(
          Uri.parse('$_overtureBase/places.pmtiles'),
          minZoom: 14,
        ),
      }),
      sprites: base.sprites,
    );
    // Land/water/background only: painted from whatever coarser tile is
    // already cached (up to 4 zoom levels away) so zooming never shows a
    // blank page while the detailed tile is fetched and rendered.
    _backgroundByBase[name] = ThemeReader().readAsBackground(
      baseJson,
      layerPredicate: defaultBackgroundLayerPredicate,
    );
    // Geometry-only / labels-only variants for foveated rendering are
    // compiled lazily in [_part] — most devices never need them.
    _baseJsonByName[name] = baseJson;
    return Style(
      name: name,
      theme: ThemeReader().read(baseJson),
      providers: base.providers,
      sprites: base.sprites,
    );
  }

  /// Tile-decoding isolates. Pre-rendered mode used to run with half of
  /// them; the worker count only needs trimming on genuinely weak hardware.
  static int get _concurrency => RenderQualitySettings.isLowEndDevice ? 2 : 4;

  static final _overlayByBase = <String, Style>{};
  static final _backgroundByBase = <String, Theme>{};
  static final _baseJsonByName = <String, Map<String, dynamic>>{};
  static final _partByBase = <String, Theme>{};

  /// Background colour to paint behind tiles that haven't arrived yet.
  static Color backgroundColor({required bool dark}) =>
      dark ? const Color(0xFF141924) : const Color(0xFFF8F4F0);

  /// Overture overlay for a loaded basemap style, or null if unavailable.
  ///
  /// [lite] pre-renders it to bitmaps like the basemap geometry. The overlay
  /// is symbols only, and drawing it live would keep its labels upright and
  /// unstretched during zooms like the basemap's own labels — but a dense
  /// city has thousands of POI labels per screen at z15+, and with Impeller
  /// every live label is redrawn every frame: on a Snapdragon 695 the
  /// raster thread went from 3-5 ms to 100-340 ms per frame in navigation
  /// (see docs/map-rendering-performance.md §9).
  static Widget? overlayLayer(
    Style style, {
    bool lite = false,
    double rasterScale = 2.0,
    int rasterCacheBytes = VectorTileLayer.defaultRasterImageCacheMaxSize,
  }) {
    final overlay = _overlayByBase[style.name];
    if (overlay == null) return null;
    return VectorTileLayer(
      key: ValueKey('overture-${style.name}-$lite'),
      tileProviders: overlay.providers,
      theme: overlay.theme,
      sprites: overlay.sprites,
      layerMode: lite ? VectorTileLayerMode.raster : VectorTileLayerMode.vector,
      rasterScale: rasterScale,
      rasterImageCacheMaxSizeInBytes: rasterCacheBytes,
      maximumZoom: 20,
      // Places archive only has z14 tiles, so no zoom offset (the default).
      maximumTileSubstitutionDifference: 3,
      concurrency: _concurrency,
    );
  }

  /// Byte budget for a raster layer's bitmap cache: the tiles visible at
  /// two zoom levels. The level on screen shares its pixels with the map
  /// and costs nothing extra, so this really buys the level most recently
  /// left, which is what makes zooming out and back in (or in and back out)
  /// show the map immediately instead of the neighbouring level stretched
  /// while every tile renders again. Graphics memory is the constraint: a
  /// scripted 16-step zoom left the process at 365 MB of GL memory with no
  /// cache and 581 MB with a three-level (192 MB) one.
  ///
  /// A tile is 256 logical px, and at a fractional zoom just below a tile
  /// level it is drawn at ~0.71 of that, so a level is up to
  /// ceil(w / t + 1) * ceil(h / t + 1) tiles of (256 * dpr)^2 * 4 bytes.
  /// On a 1240x2772 @3x phone: 28 tiles of 2.4 MB per level, 132 MB for
  /// two, clamped to 128 MB.
  static int rasterCacheBytes(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final tilePx = 256 * dpr;
    final tileLogical = 256 * 0.71;
    final tilesPerLevel =
        (size.width / tileLogical + 1).ceil() *
        (size.height / tileLogical + 1).ceil();
    final bytesPerLevel = tilesPerLevel * tilePx * tilePx * 4;
    return (2 * bytesPerLevel).round().clamp(48 << 20, 128 << 20);
  }

  /// Which parts of the theme a layer draws. Part themes are read from the
  /// same JSON as the full theme (so they behave identically) on first use.
  static Theme _part(Style style, BasemapPart part) {
    if (part == BasemapPart.all) return style.theme;
    final name = style.name;
    final key = '$name/$part';
    final cached = _partByBase[key];
    if (cached != null) return cached;
    final baseJson = _baseJsonByName[name];
    if (baseJson == null) return style.theme;
    final baseLayers = (baseJson['layers'] as List)
        .cast<Map<String, dynamic>>();
    final wantSymbols = part == BasemapPart.symbols;
    return _partByBase[key] = ThemeReader().read({
      ...baseJson,
      'id': '$name-${part.name}',
      'layers': baseLayers
          .where((l) => (l['type'] == 'symbol') == wantSymbols)
          .toList(),
    });
  }

  static Widget layer(
    Style style, {
    bool lite = false,
    BasemapPart part = BasemapPart.all,
    bool foveated = false,
    double rasterScale = 2.0,
    int rasterCacheBytes = VectorTileLayer.defaultRasterImageCacheMaxSize,
  }) => VectorTileLayer(
    key: ValueKey('base-${style.name}-$lite-$part'),
    tileProviders: style.providers,
    theme: _part(style, part),
    sprites: style.sprites,
    // International boundaries as India depicts them; see boundary_policy.
    tileDataTransform: switch (kBoundaryWorldview) {
      BoundaryWorldview.india => indiaBoundaryPolicy,
    },
    // Raster mode paints each tile once to a bitmap in an isolate and
    // lets the GPU scale it; vector mode redraws at every fractional
    // zoom (crisper, but too much for weak CPUs).
    layerMode: lite ? VectorTileLayerMode.raster : VectorTileLayerMode.vector,
    // Bitmaps at the device's pixel ratio so text stays crisp.
    rasterScale: rasterScale,
    rasterImageCacheMaxSizeInBytes: rasterCacheBytes,
    maximumZoom: 20,
    // OpenMapTiles/liberty is authored for 512px tiles (MapLibre's
    // default). Loading one zoom level down renders 4x fewer tiles per
    // view and draws labels at their designed density.
    tileOffset: TileOffset.mapbox,
    // A symbols-only layer is transparent: no land/water under-paint.
    backgroundTheme: part == BasemapPart.symbols
        ? null
        : _backgroundByBase[style.name],
    maximumTileSubstitutionDifference: 3,
    concurrency: _concurrency,
    // Foveated mode stacks three layers over the same tiles; halve the
    // per-layer caches so the total stays where a single layer's was.
    memoryTileDataCacheMaxSize: foveated ? 8 : 20,
    memoryTileCacheMaxSize: foveated
        ? 3 * 1024 * 1024
        : (lite ? 4 * 1024 * 1024 : 10 * 1024 * 1024),
    textCacheMaxSize: foveated ? 40 : (lite ? 50 : 100),
  );
}

class _Base {
  final Map<String, dynamic> json;
  final TileProviders providers;
  final SpriteStyle? sprites;
  const _Base(this.json, this.providers, this.sprites);
}
