import 'dart:convert';
import 'dart:typed_data';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'gutter_painter.dart';

/// Per-row widget: gutter background + indicator + icon overlay + child.
///
/// Vertical mode (gutter on left):
///   Stack[
///     Padding(left: contentOffset)  → child widget
///     Positioned(left:0, w:gutterWidth) → gutter paint + icon
///   ]
///
/// Horizontal mode is handled by PaneWidget directly (gutter strip at bottom).
class GutterRow extends StatelessWidget {
  final Control control;
  final Animation<double> gutterWidth;
  final Animation<double> contentOffset;
  final Animation<double> iconOpacity;
  final Animation<Color?> gutterBgColor;
  final String? gutterIcon;       // base64 PNG data
  final Color? indicatorColor;    // gradient glow color
  final double hoverWidth;
  final bool isHorizontal;
  final VoidCallback onGutterTap;

  const GutterRow({
    super.key,
    required this.control,
    required this.gutterWidth,
    required this.contentOffset,
    required this.iconOpacity,
    required this.gutterBgColor,
    this.gutterIcon,
    this.indicatorColor,
    required this.hoverWidth,
    this.isHorizontal = false,
    required this.onGutterTap,
  });

  /// Build an icon widget from base64 PNG data. Used by both
  /// GutterRow (vertical) and PaneWidget (horizontal gutter strip).
  static Widget buildIconFromBase64(String base64Data, double size) {
    try {
      final bytes = base64Decode(base64Data);
      return Image.memory(
        Uint8List.fromList(bytes),
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final childWidget = ControlWidget(control: control);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // ── Child widget with animated left padding ──
        Padding(
          padding: EdgeInsets.only(
            left: contentOffset.value,
            top: 4,
            bottom: 4,
          ),
          child: childWidget,
        ),

        // ── Gutter background with indicator gradient ──
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: gutterWidth.value,
          child: GestureDetector(
            onTap: onGutterTap,
            child: CustomPaint(
              painter: GutterPainter(
                backgroundColor: gutterBgColor.value ?? Colors.transparent,
                indicatorColor: indicatorColor,
                indicatorOpacity: iconOpacity.value,
              ),
            ),
          ),
        ),

        // ── Icon overlay (TransparentPointer so scroll passes through) ──
        if (gutterIcon != null)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: gutterWidth.value,
            child: _TransparentPointer(
              child: Center(
                child: Opacity(
                  opacity: iconOpacity.value,
                  child: buildIconFromBase64(gutterIcon!, 28),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Lightweight TransparentPointer — reports "not hit" to parent so
/// scroll events pass through to the underlying ListView, while still
/// forwarding events to children (the icon image).
class _TransparentPointer extends SingleChildRenderObjectWidget {
  const _TransparentPointer({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderTransparentPointer();
  }
}

class _RenderTransparentPointer extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    super.hitTest(result, position: position);
    return false;
  }
}
