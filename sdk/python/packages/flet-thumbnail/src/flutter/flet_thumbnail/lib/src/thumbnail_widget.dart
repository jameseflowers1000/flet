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

    // Remove keys for IDs no longer in the list
    for (final id in _registeredIds.difference(newIds)) {
      backend.captureKeys.remove(id);
    }

    // Add keys for new IDs
    for (final id in newIds.difference(_registeredIds)) {
      backend.captureKeys[id] = GlobalKey(debugLabel: "capture_$id");
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

    final currentContext = captureKey.currentContext;
    if (currentContext == null) {
      throw Exception("Control $controlId not mounted (no context). "
          "It may not be visible or attached to the widget tree.");
    }

    final renderObject = currentContext.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw Exception("Control $controlId render object is not a "
          "RenderRepaintBoundary (got ${renderObject.runtimeType}). "
          "This should not happen — file a bug.");
    }

    // Capture the image
    final ui.Image image = await renderObject.toImage(pixelRatio: pixelRatio);
    final ByteData? byteData =
        await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

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
