import 'package:flutter/rendering.dart';

import 'coordinate_transform.dart';
import 'pdf_fragment.dart';

/// Paints the geometric selection on a page: a translucent highlight over each
/// caught fragment, plus the live drag rectangle while a drag is in progress.
/// Canvas origin is the page's top-left (the painter fills the page rect).
class SelectionPainter extends CustomPainter {
  /// Currently-selected fragments on THIS page.
  final List<PdfFragment> selected;
  final PdfPageTransform transform;

  /// Committed region rectangles on THIS page, in canonical PDF points —
  /// drawn as outlines so multiple accumulated selections are distinct.
  final List<Rect> regionsPts;

  /// In-progress drag rect in page-local pixels (null when not dragging
  /// this page).
  final Rect? liveDragPx;

  SelectionPainter({
    required this.selected,
    required this.transform,
    this.regionsPts = const [],
    this.liveDragPx,
  });

  static const _blue = Color(0xFF3399FF);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x553399FF);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = _blue;
    for (final f in selected) {
      final r = transform.bboxToLocalRect(f.x0, f.top, f.x1, f.bottom);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }

    // Committed region boundaries (so accumulated regions read as discrete).
    final regionStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0xCC1166CC);
    for (final pts in regionsPts) {
      canvas.drawRect(
          transform.bboxToLocalRect(pts.left, pts.top, pts.right, pts.bottom),
          regionStroke);
    }

    final drag = liveDragPx;
    if (drag != null) {
      canvas.drawRect(
          drag,
          Paint()
            ..style = PaintingStyle.fill
            ..color = const Color(0x223399FF));
      canvas.drawRect(
          drag,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = _blue);
    }
  }

  @override
  bool shouldRepaint(covariant SelectionPainter old) =>
      old.liveDragPx != liveDragPx ||
      !identical(old.selected, selected) ||
      old.regionsPts.length != regionsPts.length ||
      old.transform.pageSizePx != transform.pageSizePx;
}
