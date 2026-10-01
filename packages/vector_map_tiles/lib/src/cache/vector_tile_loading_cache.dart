import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:executor_lib/executor_lib.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../extensions.dart';
import '../grid/constants.dart';
import '../grid/slippy_map_translator.dart';
import '../provider_exception.dart';
import '../tile_data_transform.dart';
import '../tile_identity.dart';
import '../tile_providers.dart';
import '../vector_tile_provider.dart';
import 'memory_cache.dart';
import 'storage_cache.dart';

class VectorTileLoadingCache {
  final Theme _theme;
  late final String _sourcesKey;
  final MemoryTileDataCache _tileDataCache;
  final MemoryCache _memoryCache;
  final StorageCache _delegate;
  final TileProviders _providers;
  final Map<String, Future<Uint8List?>> _byteFuturesByKey = {};
  final Map<String, Future<Uint8List?>> _cacheByteFuturesByKey = {};
  final Executor _executor;
  bool _ready = false;
  final _readyCompleter = Completer<bool>();
  late final int maximumZoom;

  final TileDataTransform? _transform;

  VectorTileLoadingCache(this._delegate, this._memoryCache, this._tileDataCache,
      this._providers, this._executor, this._theme,
      {TileDataTransform? transform})
      : _transform = transform {
    maximumZoom = _providers.tileProviderBySource.values
        .map((e) => e.maximumZoom)
        .reduce(max);
    _sourcesKey = _theme.tileSources.toList().sorted().join(',');
    _initialize();
  }

  Future<TileData?> retrieve(String source, TileIdentity tile,
      {required CancellationCallback cancelled,
      required bool cachedOnly}) async {
    if (!_ready) {
      await _readyCompleter.future;
    }
    return await _loadTile(source, tile, cancelled, cachedOnly);
  }

  void _initialize() async {
    final futures = _executor.submitAll(
        Job('setup theme', _setupTheme, _theme, deduplicationKey: null));
    for (final future in futures) {
      await future;
    }
    _ready = true;
    _readyCompleter.complete(true);
  }

  String _toKey(String source, TileIdentity id) =>
      '${id.z}_${id.x}_${id.y}_$source.pbf';

  Future<TileData?> _loadTile(String source, TileIdentity tile,
      CancellationCallback cancelled, bool cachedOnly) async {
    final tileKey = _toKey(source, tile);
    final cached = _tileDataCache.get(tileKey);
    if (cached != null) {
      return cached;
    }
    var future = cachedOnly
        ? _cacheByteFuturesByKey[tileKey]
        : _byteFuturesByKey[tileKey];
    var loaded = false;
    TileTranslation? translation;
    var dataKey = tileKey;
    var dataTile = tile;
    if (future == null) {
      final provider = _providers.tileProviderBySource[source];
      if (provider == null || tile.z < provider.minimumZoom) {
        return _emptyTile();
      }
      final desiredZoom = min(
          max(tile.z + provider.tileOffset.zoomOffset, provider.minimumZoom),
          provider.maximumZoom);
      if (desiredZoom > tile.z) {
        return _emptyTile();
      }
      var tileToLoad = tile;
      if (tile.z != desiredZoom) {
        final translator = SlippyMapTranslator(desiredZoom);
        translation = translator.translate(tile);
        tileToLoad = translation.translated;
        dataKey = _toKey(source, tileToLoad);
      }
      dataTile = tileToLoad;
      loaded = true;
      future = _loadBytes(provider, dataKey, tileToLoad, cachedOnly);
      if (cachedOnly) {
        _cacheByteFuturesByKey[dataKey] = future;
      } else {
        _byteFuturesByKey[dataKey] = future;
      }
    }
    Uint8List? bytes;
    final sw = _tileStats ? (Stopwatch()..start()) : null;
    try {
      bytes = await future;
    } on ProviderException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 204) {
        return _emptyTile();
      }
      rethrow;
    } finally {
      if (loaded) {
        if (cachedOnly) {
          _cacheByteFuturesByKey.remove(dataKey);
        } else {
          _byteFuturesByKey.remove(dataKey);
        }
      }
    }
    if (bytes == null) {
      return null;
    }
    final tBytes = sw?.elapsedMilliseconds;
    final name = '$tileKey/${_theme.id}/$_sourcesKey';
    final tileData = await _executor.submit(Job(
        name,
        _createTile,
        _ThemeTile(
            source: source,
            themeId: _theme.id,
            dataKey: dataKey,
            tile: dataTile,
            bytes: bytes,
            translation: translation,
            transform: _transform),
        cancelled: cancelled,
        deduplicationKey: name));
    _tileDataCache.put(tileKey, tileData);
    if (sw != null) {
      // ignore: avoid_print
      print('TILEDATA $tileKey fetched=$loaded bytes=${bytes.length} '
          'wait=${tBytes}ms parse=${sw.elapsedMilliseconds - tBytes!}ms');
    }
    return tileData;
  }

  Future<Uint8List?> _loadBytes(VectorTileProvider provider, String key,
      TileIdentity tile, bool cachedOnly) async {
    var bytes = _memoryCache.get(key) ?? await _delegate.retrieve(key);
    if (bytes == null && !cachedOnly) {
      bytes = await provider.provide(tile);
      _memoryCache.put(key, bytes);
      await _delegate.put(key, bytes);
    }
    return bytes;
  }

  TileData _emptyTile() => TileFactory(_theme, const Logger.noop())
      .createTileData(VectorTile(layers: []));
}

class _ThemeTile {
  final String source;
  final String themeId;
  final String dataKey;
  final TileIdentity tile;
  final Uint8List bytes;
  final TileTranslation? translation;
  final TileDataTransform? transform;

  _ThemeTile(
      {required this.source,
      required this.themeId,
      required this.dataKey,
      required this.tile,
      required this.bytes,
      required this.translation,
      required this.transform});
}

/// Patched (open_maps): parsed source tiles, per isolate. Above the
/// provider's maximum zoom every requested tile is a clipped fragment of
/// the same source tile; parsing it once per fragment cost 150-500 ms each
/// on a mid-range phone and dominated tile latency. [TileClip] and
/// [TileTranslate] build new structures, so the cached data is never
/// mutated.
final _parsedBySourceKey = <String, TileData>{};
const _parsedCacheSize = 4;

TileData _parse(_ThemeTile themeTile) {
  final transform = themeTile.transform;
  final key =
      '${themeTile.dataKey}/${themeTile.themeId}/${transform == null ? 0 : 1}';
  var parsed = _parsedBySourceKey.remove(key);
  if (parsed == null) {
    parsed = TileFactory(_themeById[themeTile.themeId]!, const Logger.noop())
        .createTileData(VectorTileReader().read(themeTile.bytes));
    if (transform != null) {
      parsed = transform(themeTile.tile, themeTile.source, parsed);
    }
  }
  _parsedBySourceKey[key] = parsed;
  while (_parsedBySourceKey.length > _parsedCacheSize) {
    _parsedBySourceKey.remove(_parsedBySourceKey.keys.first);
  }
  return parsed;
}

const _tileStats = bool.fromEnvironment('OM_TILESTATS');

final _themeById = <String, Theme>{};

Future<void> _setupTheme(Theme theme) async {
  _themeById[theme.id] = theme;
}

TileData _createTile(_ThemeTile themeTile) {
  var tileData = _parse(themeTile);
  final translation = themeTile.translation;
  if (translation != null && tileData.layers.isNotEmpty) {
    final clipSize = tileSize.width / translation.fraction;
    final dx = (translation.xOffset * clipSize);
    final dy = (translation.yOffset * clipSize);
    final clip = Rectangle(dx, dy, clipSize, clipSize);
    var transformed = TileClip(bounds: clip).clip(tileData);
    if (clip.left > 0.0 || clip.top > 0.0 || translation.fraction != 1.0) {
      transformed = TileTranslate(clip.topLeft * -1,
              scale: translation.fraction.toDouble())
          .translate(transformed);
    }
    tileData = transformed;
  }
  return tileData;
}
