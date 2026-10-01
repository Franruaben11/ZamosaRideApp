import 'dart:math' as math;

import 'package:flutter/material.dart';

const _gmBlue = Color(0xFF1A73E8);
const _gmBlueDark = Color(0xFF0B57D0);

/// Google-Maps-style navigation chevron: gradient blue arrow with a white
/// outline and soft shadow. Point it with an outer Transform.rotate.
class NavigationArrow extends StatelessWidget {
  final double size;

  const NavigationArrow({super.key, this.size = 54});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _NavigationArrowPainter());
}

class _NavigationArrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, h * 0.06) // tip
      ..lineTo(w * 0.88, h * 0.82) // right wing
      ..lineTo(w * 0.5, h * 0.64) // tail notch
      ..lineTo(w * 0.12, h * 0.82) // left wing
      ..close();

    canvas.drawShadow(path, Colors.black54, 5, true);

    final fill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_gmBlue, _gmBlueDark],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(path, fill);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.055
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white;
    canvas.drawPath(path, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Browse-mode location marker: blue dot with white ring plus a rotating
/// translucent view cone showing which way the phone is facing.
class LocationBeamDot extends StatelessWidget {
  final double size;

  const LocationBeamDot({super.key, this.size = 60});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LocationBeamPainter());
}

class _LocationBeamPainter extends CustomPainter {
  static const _beamHalfAngle = 28 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final beamRadius = size.width * 0.5;

    // View cone pointing up from the dot.
    final beam = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(
        Rect.fromCircle(center: center, radius: beamRadius),
        -math.pi / 2 - _beamHalfAngle,
        _beamHalfAngle * 2,
        false,
      )
      ..close();
    final beamPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          _gmBlue.withValues(alpha: 0.45),
          _gmBlue.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: beamRadius));
    canvas.drawPath(beam, beamPaint);

    // White ring + blue dot.
    final dotRadius = size.width * 0.16;
    canvas.drawCircle(
      center,
      dotRadius + size.width * 0.05,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(center, dotRadius, Paint()..color = _gmBlue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
