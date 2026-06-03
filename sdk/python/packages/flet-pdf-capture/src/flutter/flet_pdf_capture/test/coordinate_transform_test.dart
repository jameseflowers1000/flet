import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flet_pdf_capture/src/coordinate_transform.dart';

void main() {
  group('PdfPageTransform', () {
    // A 288x216pt page (the matplotlib test page) rendered at 2x.
    const t = PdfPageTransform(
      pageSizePts: Size(288, 216),
      pageSizePx: Size(576, 432),
    );

    test('scale is rendered/points on each axis', () {
      expect(t.scaleX, closeTo(2.0, 1e-9));
      expect(t.scaleY, closeTo(2.0, 1e-9));
    });

    test('point→local is a pure scale, no y-flip (top stays near top)', () {
      // A point near the page top must map near the canvas top.
      final near = t.pointToLocal(28.8, 16.2);
      expect(near.dx, closeTo(57.6, 1e-6));
      expect(near.dy, closeTo(32.4, 1e-6));
      // A point near the page bottom maps near the canvas bottom (y grows down).
      final far = t.pointToLocal(28.8, 184.7);
      expect(far.dy, greaterThan(near.dy));
      expect(far.dy, closeTo(369.4, 1e-6));
    });

    test('bbox→local rect preserves order and lands inside the page', () {
      final r = t.bboxToLocalRect(28.8, 16.2, 72.4, 26.2);
      expect(r.left, closeTo(57.6, 1e-6));
      expect(r.top, closeTo(32.4, 1e-6));
      expect(r.right, closeTo(144.8, 1e-6));
      expect(r.bottom, closeTo(52.4, 1e-6));
      expect(r.left, lessThan(r.right));
      expect(r.top, lessThan(r.bottom));
      expect(r.right, lessThanOrEqualTo(576));
      expect(r.bottom, lessThanOrEqualTo(432));
    });

    test('local↔point round-trips', () {
      const p = Offset(123.4, 67.8);
      final back = t.localToPoint(t.pointToLocal(p.dx, p.dy));
      expect(back.dx, closeTo(p.dx, 1e-6));
      expect(back.dy, closeTo(p.dy, 1e-6));
    });

    test('round-trips at a non-uniform / non-integer zoom', () {
      const t2 = PdfPageTransform(
        pageSizePts: Size(612, 792), // US Letter
        pageSizePx: Size(816.5, 1009.4),
      );
      const r = Rect.fromLTRB(72.1, 100.9, 540.3, 700.2);
      final back = t2.localRectToBbox(
        t2.bboxToLocalRect(r.left, r.top, r.right, r.bottom),
      );
      expect(back.left, closeTo(r.left, 1e-6));
      expect(back.top, closeTo(r.top, 1e-6));
      expect(back.right, closeTo(r.right, 1e-6));
      expect(back.bottom, closeTo(r.bottom, 1e-6));
    });
  });
}
