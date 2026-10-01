# Local patches to vector_map_tiles 9.0.0-beta.11

1. `lib/src/stream/tileset_executor_preprocessor.dart`: include `theme.id` in
   the preprocess job's `deduplicationKey`. The executor is shared across all
   `VectorTileLayer`s, so without it two layers with different themes over the
   same tile share one preprocessed result (symbols-only layers came out empty).

2. `lib/src/grid/tile_model.dart`: the tile request's `tileSources` is the
   union of the geometry theme's and the symbol theme's sources. Previously
   only the geometry theme was consulted, so a theme consisting solely of
   symbol layers loaded no tile data and rendered nothing in vector mode.

3. `lib/src/grid/tile_model.dart` and `lib/src/raster/tile_loader.dart`: call
   `.ignore()` on the vector tile future that is created before the raster
   tiles are awaited. When the request was cancelled during that gap (every
   zoom change does this) the `CancellationException` had no listener yet and
   surfaced as "Unhandled Exception: Cancelled". The same `.ignore()` is
   applied in `lib/src/stream/caches_tile_provider.dart`, where per-source
   futures are created up front and `testCancelled()` can throw before the
   loop reaches them.

Also removed from this vendored copy (not patches): the `gallery/` directory
and the two example PNGs — 7 MB of documentation images that have no effect
on the build.

4. `lib/src/vector_tile_layer.dart`, `options.dart`, `grid/grid_layer.dart`,
   `raster/*.dart`: a `rasterScale` option (default 2.0, the old constant)
   sets how many bitmap pixels are rendered per logical tile pixel in
   raster mode, so tiles can match the device pixel ratio; the scale is part
   of the on-disk image cache key. The raster `TileLayer` also cross-fades
   tiles over 220 ms instead of 100 ms.

5. `lib/src/raster/tile_loader.dart`: rendered bitmaps are no longer written
   to the disk cache. PNG-encoding a 3x tile took ~350 ms (p90 545 ms) on a
   Snapdragon 695 and the tile was withheld until the write completed,
   capping throughput at ~10 tiles/s (10-15 s to sharpen a screen); the
   vector data is cached on disk already and re-rendering costs ~2 ms.
   `lib/src/grid/grid_layer.dart`: raster mode paints the `backgroundTheme`
   (land/water from any cached coarser tile) under the `TileLayer`, as
   vector mode always did, so a zoom never shows a blank page.

6. `lib/src/cache/vector_tile_loading_cache.dart`: parsed source tiles are
   cached per isolate (4 entries). Above the provider's maximum zoom every
   requested tile is a clipped fragment of the same source tile and each
   was parsed again (150-500 ms per tile on a Snapdragon 695); median tile
   latency in raster mode dropped from 461 ms to 116 ms.

7. `lib/src/grid/tile/delay_painter.dart`, `symbols.dart`: labels stay
   visible while the map pans or rotates (the last painted pixels are
   reused; a re-layout is scheduled only when the tile's zoom scale
   changes) and are refreshed after at most 1.2 s of continuous movement
   instead of 10 s. Used by the app's Smooth mode, which draws geometry as
   pre-rendered bitmaps and labels live so they stay upright when the map
   rotates.

8. `lib/src/raster/raster_image_cache.dart` (new), `cache/caches.dart`,
   `raster/tile_loader.dart`, `vector_tile_layer.dart`, `options.dart`: a
   `rasterImageCacheMaxSizeInBytes` option and an in-memory LRU of rendered
   tile bitmaps. flutter_map disposes a tile's image the moment the tile
   leaves its keep range, which on a zoom is the whole level just left, so
   every crossing back re-parsed and re-painted that level on the UI isolate
   while the map showed the neighbouring level stretched. The cache stores a
   clone of each rendered `ui.Image` (pixels shared with the tile on screen,
   so the level in view costs nothing extra) and hands one back before a
   render job is queued. Only tiles that are on screen when they finish
   rendering are cached (the loader is given a `MapCamera` getter for
   this): flutter_map also renders a ring of off-screen tiles around the
   viewport, and on a 1240x2772 phone a level is ~35 tiles of which ~15-20
   are visible, so caching the ring halved the number of levels the budget
   could hold while a return to the level only needs the visible ones at
   once. `cache/cache.dart` now sizes an evicted value before disposing it,
   since a disposed `Image` has no dimensions.

9. `lib/src/raster/tile_loader.dart`: a tile that is not wanted right now —
   more than one zoom level from the map's, or more than a tile outside the
   viewport — waits off the render queue (polling every 250 ms) until it is
   wanted again or flutter_map cancels it, instead of being rendered; a job
   that finds its tile unwanted when it starts, or after the vector data
   arrives, goes back to waiting. flutter_map only prunes, and so only
   cancels, tiles on camera events, so after a burst of zooming the LIFO
   queue still held every tile of every level passed through; each one
   rendered was a 2.4 MB texture that flutter_map then retained as an
   "ancestor", and graphics memory on the test phone passed 1 GB until
   Vulkan reported a lost device, which surfaced as an ANR. Waiting rather
   than dropping matters because flutter_map never re-requests a tile it
   still holds: dropped, it would stay unrendered until pruned. Also
   `picture.dispose()` after
   `toImage` (a dense tile's display list is megabytes of native memory that
   otherwise waits for a Dart GC to finalize it; ~130 MB less native heap
   after a 16-step zoom), and `grid/grid_layer.dart` now registers its
   `WidgetsBindingObserver`, so `didHaveMemoryPressure` actually reaches the
   caches.

10. `lib/src/grid/tile/delay_painter.dart`: symbol tiles are shown and hidden
    with `Visibility` instead of a 500 ms `AnimatedOpacity`. Text cannot take
    group opacity directly, so every fading tile was a saveLayer (Impeller has
    no raster cache to absorb it); labels now pop in, as Organic Maps' do.

11. `lib/src/tile_data_transform.dart` (new), `vector_tile_layer.dart`,
    `options.dart`, `cache/caches.dart`, `cache/vector_tile_loading_cache.dart`,
    `grid/grid_layer.dart`: an optional `tileDataTransform` on
    `VectorTileLayer` — a top-level function applied to each decoded source
    tile inside the decoding isolates, before it enters the parsed-tile
    cache. It receives the source tile's `TileIdentity` so tile-local
    geometry can be placed on the globe. The app uses it to draw international
    boundaries according to a worldview (`lib/services/boundary_policy.dart`):
    it drops, cuts and re-tags features, adds line features built from
    lon/lat (`TileLine`, see the vector_tile_renderer patch 2), and adds a
    `boundary` layer to source tiles that have none. Changing the transform
    recreates the caches.

Dev-only timing prints: `--dart-define=OM_TILESTATS=true` logs per-tile
`TILEDATA` (fetch/parse), `TILESTATS` (render) and `TILECACHE` (bitmap
cache hit) lines.
