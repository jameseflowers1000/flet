import 'dart:math' as math;

import 'package:flutter/material.dart';

/// CustomPainter for gutter background + radial gradient indicator.
///
/// Draws:
/// 1. Solid background fill (animated from transparent → gutter color)
/// 2. Radial gradient "glow" centered vertically in the gutter
///    (indicator color → transparent, radius ~15% of gutter width)
class GutterPainter extends CustomPainter {
  final Color backgroundColor;
  final Color? indicatorColor;
  final double indicatorOpacity;

  GutterPainter({
    required this.backgroundColor,
    this.indicatorColor,
    required this.indicatorOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Background fill
    if (backgroundColor != Colors.transparent) {
      final bgPaint = Paint()..color = backgroundColor;
      canvas.drawRect(Offset.zero & size, bgPaint);
    }

    // Radial gradient indicator
    if (indicatorColor != null && indicatorOpacity > 0.01) {
      final center = Offset(size.width / 2, size.height / 2);
      final radius = math.min(size.width, size.height) * 0.4;

      final gradient = RadialGradient(
        center: Alignment.center,
        radius: 0.8,
        colors: [
          indicatorColor!.withValues(alpha: indicatorOpacity * 0.6),
          indicatorColor!.withValues(alpha: 0),
        ],
      );

      final paint = Paint()
        ..shader = gradient.createShader(
          Rect.fromCircle(center: center, radius: radius),
        );

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(GutterPainter oldDelegate) {
    return oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.indicatorColor != indicatorColor ||
        oldDelegate.indicatorOpacity != indicatorOpacity;
  }
}
