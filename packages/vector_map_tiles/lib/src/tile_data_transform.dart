import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import 'tile_identity.dart';

/// Patched (open_maps): rewrites a decoded source tile before it is cached
/// and rendered — drop features, or change their properties.
///
/// Runs inside the decoding isolates, once per source tile, so it applies
/// to every render mode and costs nothing per frame. Because it is sent to
/// another isolate it must be a top-level or static function, not a closure.
/// [tile] is the source tile the data came from (its z/x/y and each layer's
/// `extent` place the tile-local geometry on the globe); [source] is the
/// tile source id (e.g. `openmaptiles`).
typedef TileDataTransform =
    TileData Function(TileIdentity tile, String source, TileData data);
