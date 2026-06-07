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

  // ── geometric selection (milestone 3+) ────────────────────────────
  /// Committed region rectangles (canonical PDF points), in selection order.
  /// Single mode holds at most one; multi accumulates. This is what a commit
  /// returns to the agent; [_selected] is the derived highlight set.
  final List<({int page, Rect pts})> _regions = [];

  /// Global indices into [_fragments] highlighted by the current regions.
  final Set<int> _selected = {};
  // In-progress drag, page-local pixels, on page [_dragPage].
  Offset? _dragStart;
  Offset? _dragCurrent;
  int? _dragPage;
  // Status line (e.g. the reading-order text Python extracted).
  String? _status;
  // Surfaced error from the Open-PDF picker (else it fails silently).
  String? _pickError;

  // Request config pushed via the invoke channel (Python→Dart PROPERTY sync
  // does not deliver for this control; invoke methods do). These override the
  // same-named control properties when present.
  String? _buttonsJson;
  String? _instructionsText;
  String? _selectionModeOverride;

  String get _selectionMode =>
      _selectionModeOverride ??
      widget.control.getString('selection_mode') ??
      'single';

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
            _regions.clear();
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

      case 'set_buttons':
        setState(() => _buttonsJson = args['buttons'] as String?);
        return null;

      case 'set_instructions':
        setState(() => _instructionsText = args['text'] as String?);
        return null;

      case 'set_selection_mode':
        setState(() => _selectionModeOverride = args['mode'] as String?);
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
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return; // user cancelled
      final picked = result.files.first;
      // On desktop, file_picker often returns a path with bytes == null even
      // when withData is requested — read the file ourselves in that case.
      Uint8List? bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
      if (bytes == null) {
        setState(() => _pickError = 'Open PDF: no bytes and no path for '
            '"${picked.name}"');
        return;
      }
      setState(() {
        _pickError = null;
        _pdfBytes = bytes;
        _docVersion++;
        _fragments = const []; // cleared until Python re-extracts
        _regions.clear();
        _selected.clear();
        _status = null;
      });
      widget.control.triggerEventWithoutSubscribers(
        'document_changed',
        jsonEncode({'name': picked.name}),
      );
    } catch (e) {
      setState(() => _pickError = 'Open PDF failed: $e');
    }
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

    setState(() {
      if (_selectionMode == 'multi') {
        _regions.add((page: pageIndex, pts: ptsRect));
      } else {
        _regions
          ..clear()
          ..add((page: pageIndex, pts: ptsRect));
      }
      _recomputeHighlight();
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

  /// Remove one accumulated region (multi mode per-region affordance).
  void _removeRegion(int index) {
    if (index < 0 || index >= _regions.length) return;
    setState(() {
      _regions.removeAt(index);
      _recomputeHighlight();
    });
  }

  /// Rebuild the highlighted-fragment set from the current regions.
  void _recomputeHighlight() {
    _selected.clear();
    for (final region in _regions) {
      for (var i = 0; i < _fragments.length; i++) {
        final f = _fragments[i];
        if (f.page != region.page) continue;
        if (Rect.fromLTRB(f.x0, f.top, f.x1, f.bottom).overlaps(region.pts)) {
          _selected.add(i);
        }
      }
    }
  }

  // ── dynamic button bar / commit (milestone 4) ──────────────────────
  String _instructions() =>
      _instructionsText ?? widget.control.getString('instructions') ?? '';

  List<Map<String, dynamic>> _buttons() {
    final raw = _buttonsJson ?? widget.control.getString('buttons');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return [for (final b in list) if (b is Map) b.cast<String, dynamic>()];
      }
    } catch (_) {}
    return const [];
  }

  /// Press an agent-authored button: emit a CaptureResult (geometry only —
  /// Python extracts). A `cancel`-role button returns no selections.
  void _onButton(Map<String, dynamic> button) {
    final cancelled = button['role'] == 'cancel';
    widget.control.triggerEventWithoutSubscribers(
      'result',
      jsonEncode({
        'buttonId': button['id'],
        'cancelled': cancelled,
        'selections': cancelled
            ? const []
            : [
                for (final r in _regions)
                  {
                    'page': r.page,
                    'rect_pts': [
                      r.pts.left,
                      r.pts.top,
                      r.pts.right,
                      r.pts.bottom
                    ],
                  }
              ],
      }),
    );
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
        if (_pickError != null)
          Positioned(
            top: 52,
            left: 8,
            right: 8,
            child: SafeArea(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                color: const Color(0xEEAA0033),
                child: SelectableText(_pickError!,
                    style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          ),
        // Agent-authored instruction banner (top, clearing the Open PDF button).
        if (_instructions().isNotEmpty)
          Positioned(
            top: 8,
            left: 120,
            right: 8,
            child: SafeArea(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xCC101418),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  _instructions(),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        // Extracted-text status + dynamic, agent-authored button bar (bottom).
        Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomPanel()),
      ],
    );
  }

  Widget _buildBottomPanel() {
    final buttons = _buttons();
    final hasStatus = _status != null && _status!.isNotEmpty;
    if (!hasStatus && buttons.isEmpty) return const SizedBox.shrink();
    return Container(
      color: const Color(0xF0101418),
      padding: const EdgeInsets.all(8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasStatus)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _status!,
                    style: const TextStyle(
                        color: Color(0xFFB8E0FF), fontSize: 13, height: 1.3),
                  ),
                ),
              ),
            if (buttons.isNotEmpty) ...[
              if (hasStatus) const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  for (final b in buttons)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ElevatedButton(
                        onPressed: () => _onButton(b),
                        style: b['role'] == 'cancel'
                            ? ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF444A52),
                                foregroundColor: Colors.white)
                            : null,
                        child: Text('${b['label'] ?? b['id'] ?? 'OK'}'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Small red ✕ at a region's top-right corner to remove that region.
  Widget _regionRemoveButton(int index, Rect localRect) {
    return Positioned(
      left: localRect.right - 11,
      top: localRect.top - 11,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _removeRegion(index),
        child: Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: Color(0xFFD33A3A),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: Color(0x66000000), blurRadius: 2),
            ],
          ),
          child: const Icon(Icons.close, size: 15, color: Colors.white),
        ),
      ),
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
          // Committed regions on this page, with their global index (for remove).
          final regionsHere = <({int index, Rect pts})>[
            for (var i = 0; i < _regions.length; i++)
              if (_regions[i].page == pageIndex)
                (index: i, pts: _regions[i].pts)
          ];
          final liveDrag = (_dragPage == pageIndex &&
                  _dragStart != null &&
                  _dragCurrent != null)
              ? Rect.fromPoints(_dragStart!, _dragCurrent!)
              : null;
          final multi = _selectionMode == 'multi';

          return [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => _onPanStart(pageIndex, d.localPosition),
                onPanUpdate: (d) => _onPanUpdate(d.localPosition),
                onPanEnd: (_) => _onPanEnd(pageIndex, transform),
                child: CustomPaint(
                  // selection highlight + region outlines + live drag rect
                  painter: SelectionPainter(
                    selected: selectedHere,
                    transform: transform,
                    regionsPts: [for (final r in regionsHere) r.pts],
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
            // Per-region remove buttons (multi mode), at each region's
            // top-right corner. On top of the gesture layer so taps land here.
            if (multi)
              for (final r in regionsHere)
                _regionRemoveButton(r.index,
                    transform.bboxToLocalRect(
                        r.pts.left, r.pts.top, r.pts.right, r.pts.bottom)),
          ];
        },
      ),
    );
  }
}
