import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:executor_lib/executor_lib.dart';
import 'package:flutter/widgets.dart' hide Image;
import 'package:flutter_map/flutter_map.dart' hide TileProvider;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' hide TileLayer;

import '../../vector_map_tiles.dart';
import '../extensions.dart';
import '../grid/slippy_map_translator.dart';
import '../grid/tile_zoom.dart';
import '../rendering/tile_renderer.dart';
import '../stream/tile_supplier.dart';
import '../stream/tile_supplier_raster.dart';
import 'raster_image_cache.dart';
import 'storage_image_cache.dart';

class TileLoader {
  final Theme _theme;
  late final Set<String> _themeSources;
  late String _sourcesKey;
  final SpriteStyle? _sprites;
  final Future<Image> Function()? _spriteAtlas;
  final TileProvider _provider;
  final RasterTileProvider _rasterTileProvider;
  final TileOffset _tileOffset;
  final int _concurrency;
  final double _scale;
  final RasterImageCache? _imageCache;
  final MapCamera Function()? _camera;
  late final ConcurrencyExecutor _jobQueue;

  TileLoader(
      this._theme,
      this._sprites,
      this._spriteAtlas,
      this._provider,
      this._rasterTileProvider,
      this._tileOffset,
      this._concurrency,
      [this._scale = 2.0, this._imageCache, this._camera]) {
    _themeSources = _theme.tileSources;
    _sourcesKey = _theme.tileSources.toList().sorted().join(',');
    _jobQueue = ConcurrencyExecutor(
        delegate: ImmediateExecutor(),
        concurrencyLimit: _concurrency * 2,
        maxQueueSize: _maxOutstandingJobs);
  }

  Future<ImageInfo> loadTile(TileCoordinates coords, TileLayer options,
      bool Function() cancelled) async {
    final requestedTile =
        TileIdentity(coords.z.toInt(), coords.x.toInt(), coords.y.toInt());
    var requestZoom = requestedTile.z;
    if (_tileOffset.zoomOffset < 0) {
      requestZoom = max(
          1, min(requestZoom + _tileOffset.zoomOffset, _provider.maximumZoom));
    }
    // Patched (open_maps): rendered bitmaps are no longer cached on disk.
    // PNG-encoding a tile took ~350 ms (p90 545 ms) and the tile was held
    // back until the write finished, capping throughput at ~10 tiles/s;
    // re-rendering from the (disk-cached) vector data costs ~2 ms. They are
    // kept in memory instead, so a zoom level that was on screen a moment
    // ago comes back without a render (see RasterImageCache).
    final cached = _imageCache?.getTile(requestedTile);
    if (cached != null) {
      if (tileStats) {
        // ignore: avoid_print
        print('TILECACHE hit $requestedTile');
      }
      return ImageInfo(image: cached, scale: _scale);
    }
    final job = _TileJob(requestedTile, requestZoom,
        options.tileDimension.toDouble(), cancelled);
    // Patched (open_maps): a tile the map has moved away from waits here,
    // off the render queue, until it is wanted again or flutter_map cancels
    // it, instead of being rendered. flutter_map only prunes (and so only
    // cancels) tiles on camera events, so after a burst of zooming the queue
    // still held every tile of every level passed through; each one rendered
    // was a 2.4 MB texture that flutter_map then kept as an "ancestor". On
    // the test phone that ran graphics memory past 1 GB a minute after the
    // last gesture, until Vulkan reported a lost device. Waiting rather than
    // dropping matters because a tile flutter_map still holds is never
    // requested again: dropped, it would stay blank until pruned.
    while (true) {
      await _untilWanted(job);
      try {
        return await _jobQueue.submit(Job<_TileJob, ImageInfo>(
            'render $requestedTile', _renderJob, job,
            deduplicationKey:
                'render $requestedTile ${_theme.id}/$_sourcesKey'));
      } on _NotWantedException {
        continue;
      }
    }
  }

  Future<void> _untilWanted(_TileJob job) async {
    while (!_isWanted(job.requestedTile, job.tileSize)) {
      if (job.cancelled()) {
        throw CancellationException();
      }
      await Future.delayed(_wantedPollInterval);
    }
  }

  Future<ImageInfo> _renderJob(dynamic job) => _renderTile(
      job.requestedTile, job.requestZoom, job.tileSize, job.cancelled);

  Future<ImageInfo> _renderTile(TileIdentity requestedTile, int requestZoom,
      double tileSize, bool Function() cancelled) async {
    if (cancelled()) {
      throw CancellationException();
    }
    // The queue is LIFO and jobs can sit in it for seconds; see loadTile.
    if (!_isWanted(requestedTile, tileSize)) {
      throw _NotWantedException();
    }
    final sw = tileStats ? (Stopwatch()..start()) : null;
    final tileRequest = TileRequest(
        tileId: requestedTile,
        tileSources: _themeSources,
        zoom: requestedTile.z.toDouble(),
        zoomDetail: requestedTile.z.toDouble(),
        cancelled: cancelled);
    final spriteAtlas = await _spriteAtlas?.call();
    final tileResponseFuture = _provider.provide(tileRequest);
    // Patched (open_maps): see tile_model.dart — avoid an unhandled error if
    // the request is cancelled while the raster tiles are awaited.
    tileResponseFuture.ignore();
    final rasterTile = await _rasterTileProvider
        .retrieve(requestedTile.normalize(), skipMissing: true);
    try {
      final tileResponse = await tileResponseFuture;
      final tData = sw?.elapsedMilliseconds;
      final tileset = tileResponse.tileset;
      if (tileset == null) {
        throw 'No tile: $requestedTile';
      }
      final translator = SlippyMapTranslator(_provider.maximumZoom);
      final translation = translator.specificZoomTranslation(requestedTile,
          zoom: tileResponse.identity.z);

      final renderer = TileRenderer(
          theme: _theme,
          textPainterProvider: const DefaultTextPainterProvider(),
          tileState: TileState(
              zoom: requestedTile.z.toDouble(),
              zoomDetail: requestedTile.z.toDouble(),
              zoomScale: 0.0,
              rotation: 0.0),
          translation: translation,
          tileset: tileset,
          rasterTileset: rasterTile,
          spriteImage: spriteAtlas,
          sprites: _sprites);

      final size = Size.square(tileSize * _scale);
      final rect = Offset.zero & size;
      if (cancelled()) {
        throw CancellationException();
      }
      if (!_isWanted(requestedTile, tileSize)) {
        throw _NotWantedException();
      }
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder, rect);
      canvas.scale(_scale);
      renderer.render(canvas, size / _scale);

      final picture = recorder.endRecording();
      final tRenderStart = sw?.elapsedMilliseconds;
      final Image image;
      try {
        image = await picture.toImage(size.width.toInt(), size.height.toInt());
      } finally {
        // Patched (open_maps): a dense tile's display list is megabytes of
        // native memory that otherwise waits for a Dart GC to finalize it.
        picture.dispose();
      }
      if (sw != null) {
        // ignore: avoid_print
        print('TILESTATS $requestedTile data=${tData}ms '
            'render=${tRenderStart! - tData!}ms '
            'toImage=${sw.elapsedMilliseconds - tRenderStart}ms '
            'total=${sw.elapsedMilliseconds}ms');
      }
      // Only tiles that are on screen now are worth keeping: flutter_map
      // also renders a ring of off-screen tiles around the viewport, and a
      // return to this zoom level needs the visible ones immediately while
      // the ring can render behind them as before.
      if (_isVisibleNow(requestedTile, tileSize)) {
        _imageCache?.putTile(requestedTile, image);
      }
      return ImageInfo(image: image, scale: _scale);
    } finally {
      rasterTile.dispose();
    }
  }

}

extension on TileLoader {
  /// The tile's bounds in the camera's pixel space.
  Rect _tileRect(TileIdentity tile, double tileSize, MapCamera camera) {
    final size = tileSize * camera.getZoomScale(camera.zoom, tile.z.toDouble());
    return Rect.fromLTWH(tile.x * size, tile.y * size, size, size);
  }

  /// Whether the tile is on screen right now.
  bool _isVisibleNow(TileIdentity tile, double tileSize) {
    final camera = _camera?.call();
    return camera == null ||
        _tileRect(tile, tileSize, camera).overlaps(camera.pixelBounds);
  }

  /// Whether the tile is worth rendering now: at the zoom level the map is
  /// on or one away (which a zoom in progress is about to reach), and
  /// within a tile of the viewport, so a pan or a small zoom never waits.
  bool _isWanted(TileIdentity tile, double tileSize) {
    final camera = _camera?.call();
    if (camera == null) {
      return true;
    }
    if ((tile.z - camera.zoom.round()).abs() > 1) {
      return false;
    }
    final rect = _tileRect(tile, tileSize, camera);
    return rect.inflate(rect.width).overlaps(camera.pixelBounds);
  }
}

/// Thrown by a render job whose tile is not wanted at the moment; the
/// tile's loadTile call waits and resubmits.
class _NotWantedException implements Exception {}

const _wantedPollInterval = Duration(milliseconds: 250);

class _TileJob {
  final TileIdentity requestedTile;
  final int requestZoom;
  final double tileSize;
  final bool Function() cancelled;

  _TileJob(this.requestedTile, this.requestZoom, this.tileSize, this.cancelled);
}

int _maxOutstandingJobs = 100;

/// Dev-only per-tile timing (`--dart-define=OM_TILESTATS=true`).
const tileStats = bool.fromEnvironment('OM_TILESTATS');
