import 'package:flutter/rendering.dart';

import 'coordinate_transform.dart';
import 'pdf_fragment.dart';

/// Draws every fragment bbox over a rendered page to verify coordinate
/// alignment — the prototype's "single fastest bug-finder" (handoff §13),
/// replicated in Flutter at milestone 2 *before* selection is trusted.
///
/// The painter's canvas origin is the page's top-left (it fills the page
/// rect via `Positioned.fill`), so the transform maps points → page-local
/// pixels with no viewer offset.
class DebugOverlayPainter extends CustomPainter {
  /// Fragments already filtered to this page.
  final List<PdfFragment> fragments;
  final PdfPageTransform transform;

  DebugOverlayPainter({required this.fragments, required this.transform});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = const Color(0xCCFF0066); // magenta — high contrast on text
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x22FF0066);
    for (final f in fragments) {
      final r = transform.bboxToLocalRect(f.x0, f.top, f.x1, f.bottom);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant DebugOverlayPainter old) =>
      !identical(old.fragments, fragments) ||
      old.transform.pageSizePx != transform.pageSizePx ||
      old.transform.pageSizePts != transform.pageSizePts;
}
