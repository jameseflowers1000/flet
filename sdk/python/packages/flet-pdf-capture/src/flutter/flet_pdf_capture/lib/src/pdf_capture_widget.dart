import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'coordinate_transform.dart';
import 'debug_overlay_painter.dart';
import 'pdf_fragment.dart';

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
    });
    widget.control.triggerEventWithoutSubscribers(
      'document_changed',
      jsonEncode({'name': picked.name}),
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
          if (!_debugOverlay || _fragments.isEmpty) return const <Widget>[];
          final pageFrags = _fragments
              .where((f) => f.page == page.pageNumber - 1)
              .toList(growable: false);
          if (pageFrags.isEmpty) return const <Widget>[];
          final transform = PdfPageTransform(
            pageSizePts: Size(page.width, page.height),
            pageSizePx: pageRect.size,
          );
          return [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: DebugOverlayPainter(
                    fragments: pageFrags,
                    transform: transform,
                  ),
                ),
              ),
            ),
          ];
        },
      ),
    );
  }
}
