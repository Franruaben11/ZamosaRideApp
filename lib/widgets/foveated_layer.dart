import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
// Not re-exported by flutter_map, but stable across 8.x.
// ignore: implementation_imports
import 'package:flutter_map/src/map/inherited_model.dart';

/// Foveated rendering for map layers: [periphery] is drawn over the whole
/// viewport (cheap — e.g. pre-rasterised tiles) while [fovea] is drawn only
/// inside a centred window covering [fraction] of each screen dimension
/// (expensive — e.g. live vector rendering).
///
/// The trick: tile layers work out which tiles to load from
/// `MapCamera.size`, centred on `camera.center`, and position tiles relative
/// to a pixel origin derived from that same size. Handing the fovea a camera
/// with a smaller `nonRotatedSize` inside a centred box of exactly that size
/// therefore loads only the central tiles and still lines up pixel-perfect
/// with the full-size layers beneath — at any zoom or rotation.
///
/// With `fraction = 0.6` the fovea processes ~36% of the tiles a full-screen
/// vector layer would, which is the difference between a dropped-frame
/// scroll and a smooth one on weak CPUs, while the part of the map you are
/// actually looking at stays crisp.
class FoveatedLayer extends StatelessWidget {
  final List<Widget> periphery;
  final List<Widget> fovea;
  final double fraction;

  /// Soft edge between sharp centre and periphery, in logical pixels.
  /// 0 (default) disables the blend. Beware: a blend draws the fovea's
  /// labels at partial alpha over the periphery's independently placed
  /// copies, which looks like ghosting/blur rather than a soft edge.
  final double feather;

  const FoveatedLayer({
    super.key,
    required this.periphery,
    required this.fovea,
    this.fraction = 0.6,
    this.feather = 0,
  }) : assert(fraction > 0 && fraction <= 1);

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final controller = MapController.of(context);
    final options = MapOptions.of(context);

    final full = camera.nonRotatedSize;
    final size = Size(full.width * fraction, full.height * fraction);
    final inner = MapInheritedModel(
      camera: camera.withNonRotatedSize(size),
      controller: controller,
      options: options,
      child: Stack(children: fovea),
    );

    Widget window = ClipRect(child: inner);
    if (feather > 0) {
      // Rectangular fade that follows the window's edges (a radial mask
      // would leave the corners of a tall window uncovered).
      Shader edge(Rect r, Alignment a, Alignment b, double len) =>
          LinearGradient(
            begin: a,
            end: b,
            colors: const [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0, feather / len, 1 - feather / len, 1],
          ).createShader(r);
      window = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) =>
            edge(r, Alignment.centerLeft, Alignment.centerRight, r.width),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) =>
              edge(r, Alignment.topCenter, Alignment.bottomCenter, r.height),
          child: window,
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ...periphery,
        // Hit-testing stays with FlutterMap's gesture layer; this is paint only.
        IgnorePointer(
          child: Center(
            child: SizedBox.fromSize(size: size, child: window),
          ),
        ),
      ],
    );
  }
}
