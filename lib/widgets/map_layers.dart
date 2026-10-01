import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// A selectable basemap style backed by a free/open tile server.
class MapLayerStyle {
  final String name;
  final IconData icon;
  final String urlTemplate;

  /// Purpose-designed dark tiles used in dark mode (much better than
  /// color-inverting light tiles).
  final String? darkUrlTemplate;
  final List<String> subdomains;
  final String attribution;
  final int maxNativeZoom;

  /// Whether the standard dark-mode color inversion looks right on this layer
  /// (only used when [darkUrlTemplate] is absent).
  final bool supportsDarkFilter;

  /// Render from vector tiles on device (crisp, full POI/label data).
  /// The raster [urlTemplate]s stay as the fallback while the style loads.
  final bool vector;

  const MapLayerStyle({
    required this.name,
    required this.icon,
    required this.urlTemplate,
    required this.attribution,
    this.darkUrlTemplate,
    this.subdomains = const [],
    this.maxNativeZoom = 19,
    this.supportsDarkFilter = true,
    this.vector = false,
  });

  static const all = <MapLayerStyle>[
    // CARTO basemaps: clean Google-like cartography, native dark style,
    // retina (@2x) label sharpness. Free with attribution.
    MapLayerStyle(
      name: 'Streets',
      icon: Icons.map,
      vector: true,
      urlTemplate:
          'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
      darkUrlTemplate:
          'https://{s}.basemaps.cartocdn.com/rastertiles/dark_all/{z}/{x}/{y}{r}.png',
      subdomains: ['a', 'b', 'c', 'd'],
      maxNativeZoom: 20,
      attribution: '© OpenMapTiles © OpenStreetMap contributors © CARTO',
    ),
    MapLayerStyle(
      name: 'OSM Classic',
      icon: Icons.public,
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors',
    ),
    MapLayerStyle(
      name: 'Satellite',
      icon: Icons.satellite_alt,
      urlTemplate:
          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      attribution: 'Imagery © Esri & contributors',
      supportsDarkFilter: false,
    ),
    MapLayerStyle(
      name: 'Terrain',
      icon: Icons.terrain,
      urlTemplate: 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
      attribution: '© OpenStreetMap contributors, SRTM | © OpenTopoMap',
      maxNativeZoom: 17,
    ),
    MapLayerStyle(
      name: 'Cycling',
      icon: Icons.directions_bike,
      urlTemplate:
          'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
      subdomains: ['a', 'b', 'c'],
      attribution: '© OpenStreetMap contributors | CyclOSM',
    ),
    MapLayerStyle(
      name: 'Humanitarian',
      icon: Icons.volunteer_activism,
      urlTemplate: 'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
      subdomains: ['a', 'b', 'c'],
      attribution: '© OpenStreetMap contributors | HOT OSM France',
    ),
  ];

  /// Style by [name], or the default when unknown.
  static MapLayerStyle byName(String? name) =>
      all.firstWhere((s) => s.name == name, orElse: () => all.first);

  TileLayer buildTileLayer({required bool darkMode, bool retina = false}) {
    final template = darkMode && darkUrlTemplate != null
        ? darkUrlTemplate!
        : urlTemplate;
    return TileLayer(
      urlTemplate: template,
      subdomains: subdomains,
      maxNativeZoom: maxNativeZoom,
      userAgentPackageName: 'dev.openmaps.open_maps',
      // flutter_map's default provider aborts obsolete requests itself.
      retinaMode: retina && template.contains('{r}'),
      tileBuilder: darkMode
          ? (darkUrlTemplate != null
                ? nightTintTileBuilder
                : (supportsDarkFilter ? darkModeTileBuilder : null))
          : null,
    );
  }
}

/// Re-grades CARTO's near-black `dark_all` tiles into a Google-Maps-like
/// night palette: land lifted to a deep navy, roads and labels pushed up in
/// contrast, water/buildings kept darker than the ground. A plain per-channel
/// gain + bias keeps the tile cartography intact while fixing its flatness.
Widget nightTintTileBuilder(
  BuildContext context,
  Widget tileWidget,
  TileImage tile,
) {
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix(<double>[
      1.45, 0, 0, 0, 4, // R
      0, 1.45, 0, 0, 12, // G
      0, 0, 1.60, 0, 36, // B
      0, 0, 0, 1, 0, // A
    ]),
    child: tileWidget,
  );
}

/// Bottom sheet for picking the basemap style.
Future<MapLayerStyle?> showLayerPicker(
  BuildContext context,
  MapLayerStyle current,
) {
  return showModalBottomSheet<MapLayerStyle>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Map type',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              children: [
                for (final style in MapLayerStyle.all)
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(context).pop(style),
                    child: Semantics(
                      button: true,
                      selected: style == current,
                      label: style.name,
                      child: Container(
                        width: 96,
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          children: [
                            CircleAvatar(
                              radius: 26,
                              backgroundColor: style == current
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                              child: Icon(
                                style.icon,
                                color: style == current
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.onPrimaryContainer
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              style.name,
                              style: Theme.of(context).textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}
