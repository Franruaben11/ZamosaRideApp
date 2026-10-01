# Local patches to vector_tile_renderer 6.1.0

1. `lib/src/themes/text_halo_factory.dart`: text halos are eight unblurred
   `Shadow`s around the text instead of four blurred ones (blur radius =
   halo width). Impeller has no raster cache, so live symbol layers draw
   every label every frame, and a blurred shadow costs a Gaussian blur pass
   with its own offscreen texture per shadow — per label, per frame. On a
   Snapdragon 695 that was 100-340 ms per raster frame and hundreds of MB
   of transient GPU memory per frame while navigating (process peak 3 GB,
   then `ErrorDeviceLost`). Unblurred shadows are plain glyph-atlas draws.

Also removed from this vendored copy (not patches): `example/`, `test/`,
`test_data/` and the README image.

2. `lib/vector_tile_renderer.dart`: export `src/model/geometry_model.dart`
   (`TileLine`, `TilePoint`) so a `TileDataTransform` (see
   `packages/vector_map_tiles/PATCHES.md` 11) can build line features from
   points instead of MVT command integers.
