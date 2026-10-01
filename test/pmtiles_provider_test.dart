import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/pmtiles_provider.dart';

void main() {
  test('hilbert tile ids match the reference implementation', () {
    expect(PmTilesVectorTileProvider.zxyToTileId(0, 0, 0), 0);
    expect(PmTilesVectorTileProvider.zxyToTileId(1, 1, 1), 3);
    expect(PmTilesVectorTileProvider.zxyToTileId(3, 5, 2), 76);
    expect(PmTilesVectorTileProvider.zxyToTileId(14, 11763, 7384), 308347428);
  });
}
