import 'dart:ui';

import '../cache/cache.dart';
import '../tile_identity.dart';

/// Patched (open_maps): rendered tile bitmaps kept in memory under a byte
/// budget, so a zoom level that was recently on screen comes back without
/// being rendered again.
///
/// flutter_map disposes a tile's image as soon as the tile leaves its keep
/// range, which on a zoom is every tile of the level just left. Without this
/// cache each crossing back re-parsed and re-painted that level on the UI
/// isolate while the map showed the neighbouring level stretched.
///
/// Values are [Image] handles: a clone is stored and a clone is returned, so
/// the pixels stay alive while either the cache or a tile on screen holds
/// them, and cost nothing extra while both do. Sized in bytes of RGBA
/// pixels; see `VectorTileLayer.rasterImageCacheMaxSizeInBytes`.
class RasterImageCache extends Cache<String, Image> {
  RasterImageCache({required int maxSizeBytes})
      : super(maxSize: maxSizeBytes, sizer: _Sizer(), copier: _Copier());

  /// A clone of the cached bitmap for [tile], which the caller owns, or null.
  Image? getTile(TileIdentity tile) => get(_key(tile));

  /// Caches a clone of [image]; the caller keeps ownership of [image].
  void putTile(TileIdentity tile, Image image) => put(_key(tile), image);

  static String _key(TileIdentity tile) => '${tile.z}/${tile.x}/${tile.y}';
}

class _Sizer extends Sizer<Image> {
  @override
  int size(Image value) => value.width * value.height * 4;
}

class _Copier extends Copier<Image> {
  @override
  Image? copy(Image? value) => value?.clone();

  @override
  void dispose(Image? value) => value?.dispose();
}
