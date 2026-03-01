import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

/// Client-side resizable panel widget.
///
/// Handles drag entirely in Dart at 60fps via setState().
/// Sends final flex values to Python only on drag_end.
class ResizablePanelControl extends StatefulWidget {
  final Control control;

  const ResizablePanelControl({
    super.key,
    required this.control,
  });

  @override
  State<ResizablePanelControl> createState() => _ResizablePanelControlState();
}

class _ResizablePanelControlState extends State<ResizablePanelControl>
    with SingleTickerProviderStateMixin {
  List<double> _flexValues = [];
  int? _draggingIndex;
  int? _hoveredIndex;
  String? _lastInitialSizes;

  late final AnimationController _animController;
  List<double>? _animStartFlex;
  List<double>? _animTargetFlex;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addListener(_onAnimationTick);
    _parseInitialSizes();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ResizablePanelControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _parseInitialSizes();
  }

  void _parseInitialSizes() {
    final sizesJson = widget.control.getString("initial_sizes");
    // Only re-parse if initial_sizes changed (don't override user drag results)
    if (sizesJson != _lastInitialSizes) {
      _lastInitialSizes = sizesJson;
      // Stop any running animation when sizes are set externally
      if (_animController.isAnimating) {
        _animController.stop();
        _animStartFlex = null;
        _animTargetFlex = null;
      }
      if (sizesJson != null && sizesJson.isNotEmpty) {
        try {
          final List<dynamic> sizes = jsonDecode(sizesJson);
          _flexValues = sizes.map((e) => (e as num).toDouble()).toList();
        } catch (e) {
          debugPrint('[ResizablePanel] ERROR parsing initial_sizes: $e');
        }
      }
      // Invalidate stale drag/hover indices after flex values change
      _sanitizeIndices();
    }
  }

  /// Clear drag/hover indices that are no longer valid for current flex count.
  void _sanitizeIndices() {
    final maxDivider = _flexValues.length - 2; // divider i sits between i and i+1
    if (_draggingIndex != null && _draggingIndex! > maxDivider) {
      _draggingIndex = null;
    }
    if (_hoveredIndex != null && _hoveredIndex! > maxDivider) {
      _hoveredIndex = null;
    }
  }

  Color _parseColor(String? hex, Color defaultColor) {
    if (hex == null || hex.isEmpty) return defaultColor;
    try {
      var h = hex.replaceFirst('#', '');
      if (h.length == 6) h = 'FF$h';
      return Color(int.parse(h, radix: 16));
    } catch (e) {
      return defaultColor;
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      return _buildInner(context);
    } catch (e, st) {
      // Surface error visually instead of red crash screen
      final errorLine = _extractLine(st);
      debugPrint('[ResizablePanel] build error at $errorLine: $e\n$st');
      return LayoutControl(
        control: widget.control,
        child: Container(
          color: const Color(0xFF1A1A2E),
          padding: const EdgeInsets.all(12),
          child: Text(
            'ResizablePanel error at $errorLine:\n$e',
            style: const TextStyle(
              color: Color(0xFFFF6B6B),
              fontSize: 12,
              fontFamily: 'monospace',
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    }
  }

  /// Extract "file:line" from the first frame of a StackTrace.
  String _extractLine(StackTrace st) {
    final firstLine = st.toString().split('\n').firstWhere(
          (l) => l.contains('resizable_panel_control'),
          orElse: () => st.toString().split('\n').first,
        );
    // Dart web traces: "at Object.xxx (file:line:col)"
    // Dart VM traces:  "#0  Class.method (file:line:col)"
    final match = RegExp(r'[( ]([^( ]+:\d+)[:\)]').firstMatch(firstLine);
    return match?.group(1) ?? firstLine.trim();
  }

  Widget _buildInner(BuildContext context) {
    final isHorizontal =
        (widget.control.getString("orientation") ?? "horizontal") ==
            "horizontal";
    final children = widget.control.buildWidgets("controls");
    final dividerWidth =
        widget.control.getDouble("divider_width", 8.0)!;
    final dividerColor = _parseColor(
        widget.control.getString("divider_color"), Colors.black);
    final indicatorColor = _parseColor(
        widget.control.getString("indicator_color"), const Color(0xFF42A5F5));

    // Ensure flex values match children count
    while (_flexValues.length < children.length) {
      _flexValues.add(1.0);
    }
    if (_flexValues.length > children.length) {
      _flexValues = _flexValues.sublist(0, children.length);
    }
    _sanitizeIndices();

    if (children.isEmpty) {
      return LayoutControl(
        control: widget.control,
        child: const SizedBox.shrink(),
      );
    }

    final isDragging = _draggingIndex != null;
    final totalFlex = _flexValues.reduce((a, b) => a + b);

    // Build interleaved children + dividers
    final List<Widget> widgets = [];
    for (int i = 0; i < children.length; i++) {
      final flexInt = (_flexValues[i] * 1000).round().clamp(1, 999999);

      // Always use Stack wrapper — toggling between Stack/no-Stack
      // changes the widget tree structure, which destroys platform view
      // iframes (WebView/EMark). Overlays use Opacity to show/hide.
      final child = Stack(
        fit: StackFit.expand,
        children: [
          children[i],
          // Dim overlay
          IgnorePointer(
            child: Opacity(
              opacity: isDragging ? 1.0 : 0.0,
              child: const ColoredBox(color: Color(0x66000000)),
            ),
          ),
          // Size badge — adapts to available space via FittedBox
          IgnorePointer(
            child: Opacity(
              opacity: isDragging ? 1.0 : 0.0,
              child: _buildSizeBadge(i, isHorizontal, totalFlex),
            ),
          ),
        ],
      );

      widgets.add(
        Expanded(
          flex: flexInt,
          child: child,
        ),
      );

      if (i < children.length - 1) {
        widgets.add(_buildDivider(
            i, isHorizontal, dividerWidth, dividerColor, indicatorColor));
      }
    }

    return LayoutControl(
      control: widget.control,
      child: isHorizontal
          ? Row(children: widgets)
          : Column(children: widgets),
    );
  }

  Widget _buildSizeBadge(int index, bool isHorizontal, double totalFlex) {
    if (index >= _flexValues.length) return const SizedBox.shrink();

    final percentage = totalFlex > 0
        ? (_flexValues[index] / totalFlex * 100).round()
        : 0;

    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Get pixel size from layout constraints
          final pixelSize = isHorizontal
              ? constraints.maxWidth
              : constraints.maxHeight;
          final sizeText = pixelSize.isFinite
              ? '${pixelSize.round()}px  $percentage%'
              : '$percentage%';

          final badge = Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xDD1A1A2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0x44FFFFFF),
                width: 1,
              ),
            ),
            child: Text(
              sizeText,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.none,
              ),
            ),
          );

          // FittedBox with scaleDown renders at 30px but shrinks to fit
          // when the panel is too narrow. Margin keeps it off the edges.
          return Padding(
            padding: const EdgeInsets.all(8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: badge,
            ),
          );
        },
      ),
    );
  }

  Widget _buildDivider(int index, bool isHorizontal, double dividerWidth,
      Color dividerColor, Color indicatorColor) {
    // Three-state color: idle → hovered → dragging
    final Color color;
    if (_draggingIndex == index) {
      color = indicatorColor;
    } else if (_hoveredIndex == index) {
      color = Color.lerp(dividerColor, indicatorColor, 0.5)!;
    } else {
      color = dividerColor;
    }

    // Expand divider width on hover/drag for easier grabbing
    final isActive = _draggingIndex == index || _hoveredIndex == index;
    final effectiveWidth = isActive ? dividerWidth + 2 : dividerWidth;

    final dividerWidget = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: isHorizontal ? effectiveWidth : null,
      height: isHorizontal ? null : effectiveWidth,
      color: color,
    );

    // Use directional drag recognizers to prevent gesture competition
    // between nested horizontal and vertical splitters.
    Widget gestureWidget;
    if (isHorizontal) {
      gestureWidget = GestureDetector(
        onHorizontalDragStart: (_) => _onDragStart(index),
        onHorizontalDragUpdate: (details) =>
            _onDragUpdate(index, details, isHorizontal),
        onHorizontalDragEnd: (_) => _onDragEnd(),
        onDoubleTap: _onDoubleTapEqualize,
        child: dividerWidget,
      );
    } else {
      gestureWidget = GestureDetector(
        onVerticalDragStart: (_) => _onDragStart(index),
        onVerticalDragUpdate: (details) =>
            _onDragUpdate(index, details, isHorizontal),
        onVerticalDragEnd: (_) => _onDragEnd(),
        onDoubleTap: _onDoubleTapEqualize,
        child: dividerWidget,
      );
    }

    return MouseRegion(
      cursor: isHorizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) => setState(() => _hoveredIndex = null),
      child: gestureWidget,
    );
  }

  void _onDoubleTapEqualize() {
    if (_flexValues.isEmpty) return;

    _animStartFlex = List<double>.from(_flexValues);
    _animTargetFlex = List<double>.filled(_flexValues.length, 1.0);

    _animController.forward(from: 0.0);
  }

  void _onAnimationTick() {
    final start = _animStartFlex;
    final target = _animTargetFlex;
    if (start == null || target == null) return;

    final t = Curves.easeOutCubic.transform(_animController.value);

    setState(() {
      for (int i = 0; i < _flexValues.length && i < start.length && i < target.length; i++) {
        _flexValues[i] = start[i] + (target[i] - start[i]) * t;
      }
    });

    // Send final values when animation completes
    if (_animController.isCompleted) {
      _animStartFlex = null;
      _animTargetFlex = null;
      FletBackend.of(context).updateControl(
        widget.control.id,
        {'panel_sizes': jsonEncode(_flexValues)},
      );
    }
  }

  void _onDragStart(int index) {
    // Cancel any running animation
    if (_animController.isAnimating) {
      _animController.stop();
      _animStartFlex = null;
      _animTargetFlex = null;
    }

    setState(() {
      _draggingIndex = index;
    });
  }

  void _onDragUpdate(
      int index, DragUpdateDetails details, bool isHorizontal) {
    // Bounds guard — flex values may have been truncated by didUpdateWidget
    if (index < 0 || index + 1 >= _flexValues.length) {
      debugPrint('[ResizablePanel] _onDragUpdate: index $index out of range '
          '(flexValues.length=${_flexValues.length}), cancelling drag');
      setState(() => _draggingIndex = null);
      return;
    }

    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final totalSize = isHorizontal ? box.size.width : box.size.height;
    final delta = isHorizontal ? details.delta.dx : details.delta.dy;

    // Subtract divider space from total
    final dividerWidth =
        widget.control.getDouble("divider_width", 8.0)!;
    final numDividers = _flexValues.length - 1;
    final availableSize = totalSize - (numDividers * dividerWidth);

    if (availableSize <= 0) return;

    final totalFlex = _flexValues.reduce((a, b) => a + b);
    final flexPerPixel = totalFlex / availableSize;
    final flexDelta = delta * flexPerPixel;

    final minPanelSize =
        widget.control.getDouble("min_panel_size", 50.0)!;
    final minFlex = minPanelSize * flexPerPixel;

    setState(() {
      double newLeft = _flexValues[index] + flexDelta;
      double newRight = _flexValues[index + 1] - flexDelta;

      // Enforce minimum sizes
      if (newLeft < minFlex) {
        newRight -= (minFlex - newLeft);
        newLeft = minFlex;
      }
      if (newRight < minFlex) {
        newLeft -= (minFlex - newRight);
        newRight = minFlex;
      }

      if (newLeft >= minFlex && newRight >= minFlex) {
        _flexValues[index] = newLeft;
        _flexValues[index + 1] = newRight;
      }
    });
  }

  void _onDragEnd() {
    setState(() {
      _draggingIndex = null;
    });

    // Send final flex values to Python
    FletBackend.of(context).updateControl(
      widget.control.id,
      {'panel_sizes': jsonEncode(_flexValues)},
    );
  }
}
