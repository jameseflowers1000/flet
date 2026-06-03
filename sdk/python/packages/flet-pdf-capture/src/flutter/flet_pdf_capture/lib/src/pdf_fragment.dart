/// One selectable text run pushed from the Python extractor, in canonical
/// page coordinates (x0, top, x1, bottom — top-left origin, y-down, pts).
///
/// On the Dart side fragments are used only for display: the milestone-2
/// debug overlay and the milestone-3 live selection highlight. They are NOT
/// the source of truth for extraction — Python re-hit-tests the committed
/// region rect against its own cached fragments (Python-authoritative).
class PdfFragment {
  final int page; // 0-based page index
  final String text;
  final double x0;
  final double top;
  final double x1;
  final double bottom;
  final String source; // "embedded" | "ocr"

  const PdfFragment({
    required this.page,
    required this.text,
    required this.x0,
    required this.top,
    required this.x1,
    required this.bottom,
    this.source = 'embedded',
  });

  /// Build from the msgpack map sent by `PdfCaptureSurface.set_fragments`.
  factory PdfFragment.fromMap(Map<dynamic, dynamic> m) => PdfFragment(
        page: (m['page'] as num).toInt(),
        text: (m['text'] ?? '').toString(),
        x0: (m['x0'] as num).toDouble(),
        top: (m['top'] as num).toDouble(),
        x1: (m['x1'] as num).toDouble(),
        bottom: (m['bottom'] as num).toDouble(),
        source: (m['source'] ?? 'embedded').toString(),
      );
}
