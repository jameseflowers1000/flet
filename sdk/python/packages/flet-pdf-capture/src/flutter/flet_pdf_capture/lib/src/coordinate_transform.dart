import 'dart:ui';

/// Maps the capture surface's canonical PDF-point coordinates
/// (origin top-left, y increasing downward, units = PDF points — the
/// convention fixed by the Python extractor in `epyx.pdf`) to/from pixels
/// **local to a single rendered page** (origin = that page's top-left, as
/// seen by a [CustomPainter] whose canvas fills the page rect).
///
/// Because the canonical convention already matches pdfium/pdfrx's render
/// orientation, this is a pure axis scale with **no y-flip** — which is
/// what eliminates the prototype's #1 coordinate-misalignment bug class
/// (handoff §5). Pure (`dart:ui` only) so it unit-tests headlessly.
class PdfPageTransform {
  /// Page size in PDF points (`PdfPage.width/height`, cross-checkable
  /// against the extractor's `page_sizes`).
  final Size pageSizePts;

  /// Rendered page size in pixels (`pageRectInViewer.size`).
  final Size pageSizePx;

  const PdfPageTransform({required this.pageSizePts, required this.pageSizePx});

  double get scaleX => pageSizePx.width / pageSizePts.width;
  double get scaleY => pageSizePx.height / pageSizePts.height;

  /// Point (pts) → page-local pixel offset.
  Offset pointToLocal(double xPt, double yPt) =>
      Offset(xPt * scaleX, yPt * scaleY);

  /// Canonical bbox (x0, top, x1, bottom, pts) → page-local pixel rect.
  Rect bboxToLocalRect(double x0, double top, double x1, double bottom) =>
      Rect.fromLTRB(x0 * scaleX, top * scaleY, x1 * scaleX, bottom * scaleY);

  /// Inverse: page-local pixel offset → point (pts). For selection (m3).
  Offset localToPoint(Offset local) =>
      Offset(local.dx / scaleX, local.dy / scaleY);

  /// Inverse: page-local pixel rect → canonical bbox (pts). For the
  /// drag-rectangle → region-rect conversion at commit (m3+).
  Rect localRectToBbox(Rect local) => Rect.fromLTRB(
        local.left / scaleX,
        local.top / scaleY,
        local.right / scaleX,
        local.bottom / scaleY,
      );
}
