import 'dart:math' as math;
import 'dart:ui';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

/// Animated dashed border around an arbitrary child Control.
///
/// Mirrors the ETB-19 grid ants exactly: four dashed sides, all sliding
/// in the same direction, driven by a single AnimationController whose
/// .value is read at paint() time (capturing it at build time would
/// freeze the phase — same staleness bug we hit with the grid painter).
///
/// The controller is paused when `active=false` so an idle widget pays
/// no per-frame cost.
class MarchingAntsWidget extends StatefulWidget {
  final Control control;

  const MarchingAntsWidget({super.key, required this.control});

  @override
  State<MarchingAntsWidget> createState() => _MarchingAntsWidgetState();
}

class _MarchingAntsWidgetState extends State<MarchingAntsWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ants;

  @override
  void initState() {
    super.initState();
    _ants = AnimationController(
      vsync: this,
      duration: Duration(
          milliseconds: widget.control.getInt("period_ms", 900) ?? 900),
    );
    widget.control.addListener(_onControlChanged);
    _syncRunning();
  }

  @override
  void dispose() {
    widget.control.removeListener(_onControlChanged);
    _ants.dispose();
    super.dispose();
  }

  void _onControlChanged() {
    if (!mounted) return;
    // period_ms can change live; just reset duration and let the next
    // frame reflect it.
    final newPeriod = widget.control.getInt("period_ms", 900) ?? 900;
    if (newPeriod != _ants.duration?.inMilliseconds) {
      _ants.duration = Duration(milliseconds: newPeriod);
    }
    _syncRunning();
    setState(() {});
  }

  void _syncRunning() {
    final active = widget.control.getBool("active", true) ?? true;
    if (active) {
      if (!_ants.isAnimating) _ants.repeat();
    } else {
      if (_ants.isAnimating) _ants.stop();
      _ants.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.control.getBool("active", true) ?? true;
    final child = widget.control.buildWidget("content");
    final inset = widget.control.getDouble("border_inset", 2.0) ?? 2.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The child renders at natural size; the dashed border layer
        // matches the Stack's bounds via Positioned.fill — which the
        // Stack sizes from the child, so the border traces the child's
        // outline (plus border_inset padding).
        Padding(
          padding: EdgeInsets.all(inset),
          child: child ??
              const SizedBox.shrink(),
        ),
        if (active)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _AntsPainter(
                  animation: _ants,
                  color: _parseColor(
                      widget.control.getString("color", "#57C66B")!,
                      const Color(0xFF57C66B)),
                  dashLength:
                      widget.control.getDouble("dash_length", 6.0) ?? 6.0,
                  gapLength:
                      widget.control.getDouble("gap_length", 4.0) ?? 4.0,
                  stroke: widget.control.getDouble("stroke_width", 1.6) ?? 1.6,
                  radius: widget.control.getDouble("border_radius", 4.0) ?? 4.0,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // Tolerant of "#rrggbb" / "#aarrggbb" / named hexes already-prefixed.
  // Falls back to the supplied default on parse failure rather than
  // throwing, so a malformed color from Python doesn't blank the widget.
  static Color _parseColor(String s, Color fallback) {
    var t = s.trim();
    if (t.startsWith("#")) t = t.substring(1);
    if (t.length == 6) t = "FF$t";
    if (t.length != 8) return fallback;
    final v = int.tryParse(t, radix: 16);
    return v != null ? Color(v) : fallback;
  }
}

/// Same dashed-rect math as the grid `_MarchingAntsPainter` — four sides,
/// phase-shifted starts so all dashes slide in the same direction.
/// `animation.value` is read in paint() so the dashes actually march
/// (not frozen at build time).
class _AntsPainter extends CustomPainter {
  _AntsPainter({
    required this.animation,
    required this.color,
    required this.dashLength,
    required this.gapLength,
    required this.stroke,
    required this.radius,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final Color color;
  final double dashLength;
  final double gapLength;
  final double stroke;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final period = dashLength + gapLength;
    final phasePx = animation.value * period;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color;
    // Build the rounded-rect path; flatten to its four "sides" via
    // PathMetric.extractPath, which gives us dashed segments that
    // follow the corner curves naturally.
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      double t = -phasePx;
      while (t < metric.length) {
        final segStart = math.max(t, 0.0);
        final segEnd = math.min(t + dashLength, metric.length);
        if (segEnd > segStart) {
          canvas.drawPath(
              metric.extractPath(segStart, segEnd), paint);
        }
        t += period;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AntsPainter old) =>
      color != old.color ||
      dashLength != old.dashLength ||
      gapLength != old.gapLength ||
      stroke != old.stroke ||
      radius != old.radius;
}
