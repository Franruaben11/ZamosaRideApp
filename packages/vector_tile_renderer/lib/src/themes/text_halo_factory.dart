import 'dart:math';
import 'dart:ui';

import 'expression/caching_expression.dart';
import 'expression/expression.dart';

class TextHaloFactory {
  static Expression<List<Shadow>>? toHaloFunction(
    Expression<Color> colorExpression,
    Expression<double>? haloWidth,
  ) {
    return cache(TextHaloExpression(colorExpression, haloWidth));
  }
}

class TextHaloExpression extends Expression<List<Shadow>> {
  final Expression<Color> colorExpression;
  final Expression<double>? haloWidth;

  TextHaloExpression(this.colorExpression, this.haloWidth)
    : super('textHalo(${colorExpression.cacheKey},${haloWidth?.cacheKey})', {
        ...colorExpression.properties(),
        ...(haloWidth?.properties() ?? {}),
        'zoom',
      });

  @override
  List<Shadow>? evaluate(EvaluationContext context) {
    final color = colorExpression.evaluate(context);
    if (color == null) {
      return null;
    }
    final width = haloWidth?.evaluate(context);
    if (width == null) {
      return null;
    }
    double factor = max(1.0, context.zoomScaleFactor);
    double offset = width / factor;
    // Patched (open_maps): the halo is eight unblurred copies of the text
    // around it instead of four blurred ones. A blurred shadow makes
    // Impeller run a Gaussian blur pass with its own offscreen texture per
    // shadow, per label, per frame; with every label on screen drawn live
    // that allocated hundreds of MB of transient GPU memory per frame on a
    // Snapdragon 695 (raster thread 100-340 ms/frame, process peak 3 GB,
    // Vulkan device lost). Unblurred shadows are plain glyph-atlas draws.
    final diagonal = offset / sqrt2;
    return [
      Shadow(offset: Offset(-offset, 0), color: color),
      Shadow(offset: Offset(offset, 0), color: color),
      Shadow(offset: Offset(0, -offset), color: color),
      Shadow(offset: Offset(0, offset), color: color),
      Shadow(offset: Offset(-diagonal, -diagonal), color: color),
      Shadow(offset: Offset(diagonal, diagonal), color: color),
      Shadow(offset: Offset(diagonal, -diagonal), color: color),
      Shadow(offset: Offset(-diagonal, diagonal), color: color),
    ];
  }

  @override
  bool get isConstant => false;
}
