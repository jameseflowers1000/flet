import 'dart:convert';
import 'dart:typed_data';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'gutter_painter.dart';

/// Per-row widget: gutter background + indicator + icon overlay + child.
///
/// Layout (Stack):
///   ├── Padding(left: contentLeft)    ← child widget from Python
///   ├── Positioned(left:0, w:gutterWidth)
///   │   └── CustomPaint              ← gutter background + gradient indicator
///   └── TransparentPointer           ← icon overlay (passes scroll through)
///       └── Positioned(centered)
///           └── Opacity(iconOpacity)
///               └── icon image
class GutterRow extends StatelessWidget {
  final Control control;
  final Animation<double> gutterWidth;
  final Animation<double> contentLeft;
  final Animation<double> iconOpacity;
  final Animation<Color?> gutterBgColor;
  final String? gutterIcon;       // base64 PNG data
  final Color? indicatorColor;    // gradient glow color
  final double hoverWidth;
  final VoidCallback onGutterTap;

  const GutterRow({
    super.key,
    required this.control,
    required this.gutterWidth,
    required this.contentLeft,
    required this.iconOpacity,
    required this.gutterBgColor,
    this.gutterIcon,
    this.indicatorColor,
    required this.hoverWidth,
    required this.onGutterTap,
  });

  @override
  Widget build(BuildContext context) {
    // Build the child widget from this control
    final childWidget = ControlWidget(control: control);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // ── Child widget with animated left padding ──
        Padding(
          padding: EdgeInsets.only(
            left: contentLeft.value,
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
                  child: _buildIcon(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildIcon() {
    if (gutterIcon == null) return const SizedBox.shrink();

    try {
      final bytes = base64Decode(gutterIcon!);
      return Image.memory(
        Uint8List.fromList(bytes),
        width: 28,
        height: 28,
        fit: BoxFit.contain,
        gaplessPlayback: true, // prevent flash on rebuild
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
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
    // Forward hits to children but report "not hit" to parent
    super.hitTest(result, position: position);
    return false;
  }
}
