import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

/// WindowManagerWidget renders its FloatingWindow children in a Stack.
///
/// It acts as a pass-through container — each child FloatingWindow handles
/// its own positioning, dragging, resizing, and z-order. The manager just
/// fills the overlay area and provides the Stack.
///
/// SizedBox.expand ensures the Stack fills the available overlay area,
/// which gives FloatingWindowWidget's LayoutBuilder correct viewport bounds.
/// The Stack itself doesn't intercept pointer events — only the
/// FloatingWindow chrome areas do.
class WindowManagerWidget extends StatefulWidget {
  final Control control;

  const WindowManagerWidget({
    super.key,
    required this.control,
  });

  @override
  State<WindowManagerWidget> createState() => _WindowManagerWidgetState();
}

class _WindowManagerWidgetState extends State<WindowManagerWidget> {
  @override
  Widget build(BuildContext context) {
    final children = widget.control.buildWidgets("controls");

    return LayoutControl(
      control: widget.control,
      child: SizedBox.expand(
        child: Stack(
          clipBehavior: Clip.none,
          children: children,
        ),
      ),
    );
  }
}
