import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Invisible service widget that captures thumbnails of registered controls.
///
/// Parses `control_ids` (JSON array of ints) from the Python control and
/// registers GlobalKeys in [FletBackend.captureKeys]. On `capture` method
/// invocation, looks up the RepaintBoundary via the GlobalKey and calls
/// `toImage()` to produce a PNG.
class ThumbnailWidget extends StatefulWidget {
  final Control control;

  const ThumbnailWidget({super.key, required this.control});

  @override
  State<ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<ThumbnailWidget> {
  // LRU cache: controlId → PNG bytes
  final Map<int, Uint8List> _cache = {};
  static const int _maxCacheSize = 50;

  // Track which IDs we've registered so we can clean up
  final Set<int> _registeredIds = {};

  @override
  void initState() {
    super.initState();
    widget.control.addInvokeMethodListener(_invokeMethod);
    // _syncRegistrations() deferred to didChangeDependencies (Provider access)
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRegistrations();
  }

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.control != widget.control) {
      oldWidget.control.removeInvokeMethodListener(_invokeMethod);
      widget.control.addInvokeMethodListener(_invokeMethod);
    }
    _syncRegistrations();
  }

  /// Parse control_ids JSON and register/unregister GlobalKeys in FletBackend.captureKeys.
  void _syncRegistrations() {
    final backend = FletBackend.of(context);
    final idsJson = widget.control.getString("control_ids");

    final Set<int> newIds = {};
    if (idsJson != null && idsJson.isNotEmpty) {
      try {
        final List<dynamic> parsed = jsonDecode(idsJson);
        for (final id in parsed) {
          if (id is int) {
            newIds.add(id);
          }
        }
      } catch (e) {
        debugPrint("ThumbnailWidget: failed to parse control_ids: $e");
      }
    }

    // Remove keys for IDs no longer in the list and rebuild to unwrap
    for (final id in _registeredIds.difference(newIds)) {
      backend.captureKeys.remove(id);
      final targetControl = backend.controlsIndex.get(id);
      if (targetControl != null) {
        targetControl.notify();
      }
    }

    // Add keys for new IDs and force target controls to rebuild
    // so ControlWidget wraps them in RepaintBoundary
    for (final id in newIds.difference(_registeredIds)) {
      backend.captureKeys[id] = GlobalKey(debugLabel: "capture_$id");
      final targetControl = backend.controlsIndex.get(id);
      if (targetControl != null) {
        targetControl.notify();
      }
    }

    _registeredIds
      ..clear()
      ..addAll(newIds);
  }

  Future<dynamic> _invokeMethod(String name, dynamic args) async {
    debugPrint("ThumbnailWidget.$name($args)");
    switch (name) {
      case "capture":
        return await _capture(args);
      case "invalidate":
        final controlId = args["control_id"];
        if (controlId is int) {
          _cache.remove(controlId);
        }
        return null;
      case "clear_cache":
        _cache.clear();
        return null;
      default:
        throw Exception("Unknown ThumbnailWidget method: $name");
    }
  }

  Future<Uint8List?> _capture(dynamic args) async {
    final controlId = args["control_id"] as int;
    final double pixelRatio = (args["pixel_ratio"] as num?)?.toDouble() ?? 0.5;

    // Check cache first
    if (_cache.containsKey(controlId)) {
      return _cache[controlId];
    }

    final backend = FletBackend.of(context);
    final captureKey = backend.captureKeys[controlId];
    if (captureKey == null) {
      throw Exception("Control $controlId not registered for capture. "
          "Call register_controls() first.");
    }

    // Wait up to 3 frames for RepaintBoundary to mount after notify()
    BuildContext? currentContext;
    for (int attempt = 0; attempt < 3; attempt++) {
      currentContext = captureKey.currentContext;
      if (currentContext != null) break;
      // Schedule a frame and wait for it to complete
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        completer.complete();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
      await completer.future;
    }
    if (currentContext == null) {
      throw Exception("Control $controlId not mounted (no context). "
          "It may not be visible or attached to the widget tree.");
    }

    final renderObject = currentContext.findRenderObject();
    if (renderObject == null) {
      throw Exception("Control $controlId has no render object.");
    }
    if (renderObject is RenderBox && !renderObject.hasSize) {
      throw Exception("Control $controlId has no size.");
    }

    // Find the nearest ancestor RenderRepaintBoundary that can be captured.
    // Walk up from the target control, trying toImage() on each boundary.
    // Note: debugLayer is always null in release builds (wrapped in assert),
    // so we must try toImage() to detect if the boundary is painted.
    final boundaries = <RenderRepaintBoundary>[];
    if (renderObject is RenderRepaintBoundary) {
      boundaries.add(renderObject);
    }
    RenderObject? walker = renderObject.parent;
    while (walker != null) {
      if (walker is RenderRepaintBoundary) {
        boundaries.add(walker);
      }
      walker = walker.parent;
    }

    if (boundaries.isEmpty) {
      throw Exception("No RepaintBoundary in ancestor chain for control $controlId.");
    }

    // Try each boundary from closest to farthest
    ui.Image? fullImage;
    RenderRepaintBoundary? boundary;
    for (final b in boundaries) {
      try {
        fullImage = await b.toImage(pixelRatio: pixelRatio);
        boundary = b;
        break;
      } catch (_) {
        continue; // This boundary has no layer yet, try parent
      }
    }

    if (fullImage == null || boundary == null) {
      throw Exception("No painted RepaintBoundary ancestor for control $controlId.");
    }

    // If we captured the target control directly, use the image as-is
    if (boundary == renderObject) {
      final ByteData? byteData =
          await fullImage.toByteData(format: ui.ImageByteFormat.png);
      fullImage.dispose();
      if (byteData == null) {
        throw Exception("Failed to encode control $controlId to PNG.");
      }
      final pngBytes = byteData.buffer.asUint8List();
      if (_cache.length >= _maxCacheSize) _cache.remove(_cache.keys.first);
      _cache[controlId] = pngBytes;
      return pngBytes;
    }

    // Crop the ancestor image to the target control's region
    final targetSize = renderObject.paintBounds.size;
    final transform = renderObject.getTransformTo(boundary);
    final targetOffset = MatrixUtils.transformPoint(transform, Offset.zero);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final srcRect = Rect.fromLTWH(
      targetOffset.dx * pixelRatio,
      targetOffset.dy * pixelRatio,
      targetSize.width * pixelRatio,
      targetSize.height * pixelRatio,
    );
    final dstRect = Rect.fromLTWH(
      0, 0,
      targetSize.width * pixelRatio,
      targetSize.height * pixelRatio,
    );
    canvas.drawImageRect(fullImage, srcRect, dstRect, Paint());
    final picture = recorder.endRecording();
    final croppedImage = await picture.toImage(
      (targetSize.width * pixelRatio).ceil(),
      (targetSize.height * pixelRatio).ceil(),
    );
    fullImage.dispose();
    picture.dispose();

    final ByteData? byteData =
        await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    croppedImage.dispose();

    if (byteData == null) {
      throw Exception("Failed to encode control $controlId to PNG.");
    }

    final Uint8List pngBytes = byteData.buffer.asUint8List();

    // Cache with LRU eviction
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
    _cache[controlId] = pngBytes;

    return pngBytes;
  }

  @override
  void dispose() {
    widget.control.removeInvokeMethodListener(_invokeMethod);

    // Clean up registered captureKeys
    try {
      final backend = FletBackend.of(context);
      for (final id in _registeredIds) {
        backend.captureKeys.remove(id);
      }
    } catch (_) {
      // Context may not be valid during dispose
    }
    _registeredIds.clear();
    _cache.clear();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("ThumbnailWidget build: ${widget.control.id}");
    // Re-sync registrations on every build (properties may have changed)
    _syncRegistrations();
    // Invisible — this is a service widget
    return const SizedBox.shrink();
  }
}
