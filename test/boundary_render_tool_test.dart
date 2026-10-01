// Visual check of the boundary policy against real tiles. Not a regression
// test: it only runs when pointed at a directory of `z_x_y.pbf` tiles and
// writes a before/after mosaic per zoom level plus a feature listing.
//
//   OM_RENDER_TILES=/dir/of/tiles OM_RENDER_OUT=/dir/out \
//     flutter test test/boundary_render_tool_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_maps/services/basemap_style.dart';
import 'package:open_maps/services/boundary_policy.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

const _scale = 3.0;
const tileSize = 256;

Map<String, dynamic> _styleJson() => prepareStyleJson(
  jsonDecode(File('test/fixtures/liberty.json').readAsStringSync())
      as Map<String, dynamic>,
);

Theme _geometryTheme(Map<String, dynamic> style) {
  final json = Map<String, dynamic>.of(style);
  json['layers'] = (style['layers'] as List)
      .where((l) => (l as Map)['type'] != 'symbol')
      .toList();
  return ThemeReader().read(json);
}

TileData _decode(Theme theme, Uint8List bytes) => TileFactory(
  theme,
  const Logger.noop(),
).createTileData(VectorTileReader().read(bytes));

(double, double) _lonLat(TileIdentity t, int extent, double x, double y) {
  final n = math.pow(2, t.z).toDouble();
  final lon = (t.x + x / extent) / n * 360 - 180;
  final s = math.pi * (1 - 2 * (t.y + y / extent) / n);
  final lat = math.atan((math.exp(s) - math.exp(-s)) / 2) * 180 / math.pi;
  return (lon, lat);
}

String _describe(TileIdentity t, TileDataLayer layer, TileDataFeature f) {
  final p = f.properties;
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  var n = 0;
  if (f.hasLines) {
    for (final line in f.lines) {
      for (final pt in line.points) {
        n++;
        minX = math.min(minX, pt.x);
        maxX = math.max(maxX, pt.x);
        minY = math.min(minY, pt.y);
        maxY = math.max(maxY, pt.y);
      }
    }
  } else if (f.hasPoints) {
    for (final pt in f.points) {
      n++;
      minX = math.min(minX, pt.x);
      maxX = math.max(maxX, pt.x);
      minY = math.min(minY, pt.y);
      maxY = math.max(maxY, pt.y);
    }
  }
  String bbox = '';
  if (n > 0) {
    final (w, nn) = _lonLat(t, layer.extent, minX, minY);
    final (e, ss) = _lonLat(t, layer.extent, maxX, maxY);
    bbox =
        ' bbox=[${w.toStringAsFixed(2)},${ss.toStringAsFixed(2)}]-'
        '[${e.toStringAsFixed(2)},${nn.toStringAsFixed(2)}] pts=$n';
  }
  final keys = [
    'admin_level',
    'disputed',
    'claimed_by',
    'maritime',
    'adm0_l',
    'adm0_r',
    'disputed_name',
    'name',
    'name:en',
    'class',
    'rank',
  ];
  final props = [
    for (final k in keys)
      if (p.containsKey(k)) '$k=${p[k]}',
  ].join(' ');
  var lines = '';
  if (f.hasLines && p['disputed'] == 1 && f.lines.length > 1) {
    for (final line in f.lines) {
      final xs = line.points.map((q) => q.x), ys = line.points.map((q) => q.y);
      final (w, nn) = _lonLat(
        t,
        layer.extent,
        xs.reduce(math.min),
        ys.reduce(math.min),
      );
      final (e, ss) = _lonLat(
        t,
        layer.extent,
        xs.reduce(math.max),
        ys.reduce(math.max),
      );
      lines +=
          '\n      line [${w.toStringAsFixed(2)},${ss.toStringAsFixed(2)}]-'
          '[${e.toStringAsFixed(2)},${nn.toStringAsFixed(2)}] pts=${line.points.length}';
    }
  }
  return '  $props$bbox$lines';
}

void main() {
  final tilesDir = Platform.environment['OM_RENDER_TILES'];
  final outDir = Platform.environment['OM_RENDER_OUT'];

  testWidgets('render boundary policy before/after', (tester) async {
    await tester.runAsync(() async {
      final style = _styleJson();
      final fullTheme = ThemeReader().read(style);
      final geomTheme = _geometryTheme(style);
      final renderer = Renderer(theme: geomTheme);
      final files = Directory(tilesDir!)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.pbf'))
          .toList();
      final byZoom = <int, List<(TileIdentity, Uint8List)>>{};
      for (final f in files) {
        final parts = f.uri.pathSegments.last
            .replaceAll('.pbf', '')
            .split('_')
            .map(int.parse)
            .toList();
        final t = TileIdentity(parts[0], parts[1], parts[2]);
        byZoom.putIfAbsent(t.z, () => []).add((t, f.readAsBytesSync()));
      }
      Directory(outDir!).createSync(recursive: true);
      final report = StringBuffer();

      for (final z in byZoom.keys.toList()..sort()) {
        final tiles = byZoom[z]!;
        final minX = tiles.map((t) => t.$1.x).reduce(math.min);
        final maxX = tiles.map((t) => t.$1.x).reduce(math.max);
        final minY = tiles.map((t) => t.$1.y).reduce(math.min);
        final maxY = tiles.map((t) => t.$1.y).reduce(math.max);
        final cols = maxX - minX + 1, rows = maxY - minY + 1;
        final w = (cols * tileSize * _scale).round();
        final h = (rows * tileSize * _scale).round();

        for (final pass in ['before', 'after']) {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          canvas.drawRect(
            ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            ui.Paint()..color = const ui.Color(0xFFFFFFFF),
          );
          for (final (t, bytes) in tiles) {
            var data = _decode(fullTheme, bytes);
            var elapsed = '';
            if (pass == 'after') {
              final sw = Stopwatch()..start();
              data = indiaBoundaryPolicy(t, 'openmaptiles', data);
              elapsed = ' (${sw.elapsedMilliseconds} ms)';
            }
            report.writeln('== z${t.z}/${t.x}/${t.y} $pass$elapsed');
            for (final layer in data.layers) {
              if (layer.name == 'boundary') {
                for (final f in layer.features) {
                  report.writeln(_describe(t, layer, f));
                }
              }
              if (layer.name == 'place' && pass == 'before') {
                for (final f in layer.features) {
                  final c = f.properties['class'];
                  if (c == 'country' || c == 'state' || c == 'province') {
                    report.writeln('  [place] ${_describe(t, layer, f)}');
                  }
                }
              }
            }
            canvas.save();
            canvas.translate(
              (t.x - minX) * tileSize * _scale,
              (t.y - minY) * tileSize * _scale,
            );
            canvas.scale(_scale);
            renderer.render(
              canvas,
              TileSource(tileset: Tileset({'openmaptiles': data.toTile()})),
              zoomScaleFactor: 1.0,
              zoom: z.toDouble(),
              rotation: 0,
            );
            canvas.restore();
          }
          // Tile grid for orientation.
          final grid = ui.Paint()
            ..color = const ui.Color(0x40FF0000)
            ..style = ui.PaintingStyle.stroke;
          for (var c = 0; c <= cols; c++) {
            final x = c * tileSize * _scale;
            canvas.drawLine(ui.Offset(x, 0), ui.Offset(x, h.toDouble()), grid);
          }
          for (var r = 0; r <= rows; r++) {
            final y = r * tileSize * _scale;
            canvas.drawLine(ui.Offset(0, y), ui.Offset(w.toDouble(), y), grid);
          }
          final image = await recorder.endRecording().toImage(w, h);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '$outDir/z${z}_$pass.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        }
      }
      File('$outDir/features.txt').writeAsStringSync(report.toString());
    });
  }, skip: tilesDir == null || outDir == null);
}
