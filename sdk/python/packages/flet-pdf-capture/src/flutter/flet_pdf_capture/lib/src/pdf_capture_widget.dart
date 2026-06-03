import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'coordinate_transform.dart';
import 'debug_overlay_painter.dart';
import 'pdf_fragment.dart';
import 'selection_painter.dart';

/// The PDF capture surface (Dart side). Milestone 2 scope: render the PDF
/// with pdfrx and draw the aligned fragment-bbox debug overlay. Geometric
/// selection + the dynamic button bar land in later milestones.
///
/// Document bytes and fragments arrive imperatively (msgpack — binary-safe,
/// no long-string-drop) via `addInvokeMethodListener`; nothing large rides
/// on control properties.
class PdfCaptureWidget extends StatefulWidget {
  final Control control;

  const PdfCaptureWidget({super.key, required this.control});

  @override
  State<PdfCaptureWidget> createState() => _PdfCaptureWidgetState();
}

class _PdfCaptureWidgetState extends State<PdfCaptureWidget> {
  Uint8List? _pdfBytes;
  int _docVersion = 0; // bumps per document → forces a fresh PdfViewer
  List<PdfFragment> _fragments = const [];
  bool _debugOverlay = false;

  // ── geometric selection (milestone 3) ─────────────────────────────
  /// Global indices into [_fragments] that are currently highlighted.
  final Set<int> _selected = {};
  // In-progress drag, page-local pixels, on page [_dragPage].
  Offset? _dragStart;
  Offset? _dragCurrent;
  int? _dragPage;
  // Status line (e.g. the reading-order text Python extracted).
  String? _status;

  String get _selectionMode =>
      widget.control.getString('selection_mode') ?? 'single';

  @override
  void initState() {
    super.initState();
    widget.control.addInvokeMethodListener(_invokeMethod);
    _debugOverlay = widget.control.getBool('debug_overlay', false) ?? false;
  }

  @override
  void didUpdateWidget(covariant PdfCaptureWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.control != widget.control) {
      oldWidget.control.removeInvokeMethodListener(_invokeMethod);
      widget.control.addInvokeMethodListener(_invokeMethod);
    }
    final dbg = widget.control.getBool('debug_overlay', false) ?? false;
    if (dbg != _debugOverlay) {
      setState(() => _debugOverlay = dbg);
    }
  }

  @override
  void dispose() {
    widget.control.removeInvokeMethodListener(_invokeMethod);
    super.dispose();
  }

  Future<dynamic> _invokeMethod(String name, dynamic args) async {
    switch (name) {
      case 'load_document':
        final raw = args['bytes'];
        Uint8List? bytes;
        if (raw is Uint8List) {
          bytes = raw;
        } else if (raw is List) {
          bytes = Uint8List.fromList(raw.cast<int>());
        }
        if (bytes != null) {
          setState(() {
            _pdfBytes = bytes;
            _docVersion++;
            _selected.clear();
            _status = null;
          });
        }
        return null;

      case 'set_fragments':
        final raw = args['fragments'];
        final frags = <PdfFragment>[];
        if (raw is List) {
          for (final m in raw) {
            if (m is Map) frags.add(PdfFragment.fromMap(m));
          }
        }
        setState(() => _fragments = frags);
        return null;

      case 'set_debug_overlay':
        setState(() => _debugOverlay = args['on'] == true);
        return null;

      case 'set_status':
        setState(() => _status = args['text'] as String?);
        return null;

      case 'get_document_bytes':
        return _pdfBytes;

      default:
        throw Exception('Unknown PdfCaptureWidget method: $name');
    }
  }

  /// Open a PDF from the local filesystem (front-end owns file access).
  /// Renders it immediately, then notifies Python via `on_document_changed`
  /// so it can pull the bytes (`get_document_bytes`), extract, and push
  /// fragments back. The surface itself stays domain-agnostic.
  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final bytes = picked.bytes;
    if (bytes == null) return;
    setState(() {
      _pdfBytes = bytes;
      _docVersion++;
      _fragments = const []; // cleared until Python re-extracts
      _selected.clear();
      _status = null;
    });
    widget.control.triggerEventWithoutSubscribers(
      'document_changed',
      jsonEncode({'name': picked.name}),
    );
  }

  // ── drag-rectangle selection ───────────────────────────────────────
  void _onPanStart(int pageIndex, Offset localPx) {
    setState(() {
      _dragPage = pageIndex;
      _dragStart = localPx;
      _dragCurrent = localPx;
    });
  }

  void _onPanUpdate(Offset localPx) {
    if (_dragStart == null) return;
    setState(() => _dragCurrent = localPx);
  }

  /// Commit the drag: convert the page-local pixel rect to PDF points, hit-test
  /// fragments for the live highlight (single mode replaces, multi accumulates),
  /// and fire `on_selection` so Python does the authoritative extraction.
  void _onPanEnd(int pageIndex, PdfPageTransform transform) {
    final start = _dragStart;
    final current = _dragCurrent;
    if (start == null || current == null) {
      _resetDrag();
      return;
    }
    final rectPx = Rect.fromPoints(start, current);
    if (rectPx.width < 2 && rectPx.height < 2) {
      _resetDrag(); // a tap, not a drag
      return;
    }
    final ptsRect = transform.localRectToBbox(rectPx);

    final caught = <int>{};
    for (var i = 0; i < _fragments.length; i++) {
      final f = _fragments[i];
      if (f.page != pageIndex) continue;
      final fr = Rect.fromLTRB(f.x0, f.top, f.x1, f.bottom);
      if (fr.overlaps(ptsRect)) caught.add(i);
    }

    setState(() {
      if (_selectionMode == 'multi') {
        _selected.addAll(caught);
      } else {
        _selected
          ..clear()
          ..addAll(caught);
      }
      _dragStart = null;
      _dragCurrent = null;
      _dragPage = null;
    });

    widget.control.triggerEventWithoutSubscribers(
      'selection',
      jsonEncode({
        'page': pageIndex,
        'rect_pts': [ptsRect.left, ptsRect.top, ptsRect.right, ptsRect.bottom],
      }),
    );
  }

  void _resetDrag() {
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _dragPage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: _buildViewer()),
        Positioned(
          top: 8,
          left: 8,
          child: SafeArea(
            child: ElevatedButton.icon(
              onPressed: _pickPdf,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open PDF'),
            ),
          ),
        ),
        if (_status != null && _status!.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: const Color(0xE6101418),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  _status!,
                  style: const TextStyle(
                      color: Color(0xFFB8E0FF), fontSize: 13, height: 1.3),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildViewer() {
    final bytes = _pdfBytes;
    if (bytes == null) {
      return const ColoredBox(
        color: Color(0xFF2A2A2A),
        child: Center(
          child: Text('No PDF loaded — press Open PDF',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
        ),
      );
    }

    final initialPage = (widget.control.getInt('initial_page', 0) ?? 0) + 1;

    return PdfViewer.data(
      bytes,
      key: ValueKey<int>(_docVersion),
      sourceName: 'capture_$_docVersion',
      initialPageNumber: initialPage,
      params: PdfViewerParams(
        pageOverlaysBuilder: (context, pageRect, page) {
          final pageIndex = page.pageNumber - 1;
          final transform = PdfPageTransform(
            pageSizePts: Size(page.width, page.height),
            pageSizePx: pageRect.size,
          );
          final pageFrags = _fragments
              .where((f) => f.page == pageIndex)
              .toList(growable: false);
          final selectedHere = <PdfFragment>[
            for (final i in _selected)
              if (_fragments[i].page == pageIndex) _fragments[i]
          ];
          final liveDrag = (_dragPage == pageIndex &&
                  _dragStart != null &&
                  _dragCurrent != null)
              ? Rect.fromPoints(_dragStart!, _dragCurrent!)
              : null;

          return [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _onPanStart(pageIndex, d.localPosition),
                onPanUpdate: (d) => _onPanUpdate(d.localPosition),
                onPanEnd: (_) => _onPanEnd(pageIndex, transform),
                child: CustomPaint(
                  // selection highlight + live drag rect
                  painter: SelectionPainter(
                    selected: selectedHere,
                    transform: transform,
                    liveDragPx: liveDrag,
                  ),
                  // optional alignment debug overlay, drawn on top
                  foregroundPainter: (_debugOverlay && pageFrags.isNotEmpty)
                      ? DebugOverlayPainter(
                          fragments: pageFrags, transform: transform)
                      : null,
                ),
              ),
            ),
          ];
        },
      ),
    );
  }
}
