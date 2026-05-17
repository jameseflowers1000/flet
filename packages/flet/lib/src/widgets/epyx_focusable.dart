// Single wrapper used by every Epyx focusable Dart widget (EMark,
// EPlot, EWeb, EImage, the EInput family).
//
//   EpyxFocusable(
//     name: 'rate',
//     group: 1,
//     order: 0,
//     skip: false,
//     onFocusChange: (focused) { /* report up to Python */ },
//     child: <whatever the control's normal Dart body is>,
//   )
//
// Behavior:
//   - Registers a FocusNode with TabGroupController on mount.
//   - Listens to controller.activeGroup; when our group != active,
//     canRequestFocus=false and skipTraversal=true so Tab never lands.
//   - On tap, activates our group (without requesting focus
//     elsewhere — Flutter's tap-to-focus on the inner widget handles
//     that) and requests focus on this node.
//   - Paints a 2px blue border when hasFocus.
library;

import 'package:flutter/material.dart';
import 'tab_group_controller.dart';

class EpyxFocusable extends StatefulWidget {
  final String name;
  final int? group;
  final int? order;
  final bool skip;
  final void Function(bool focused)? onFocusChange;
  final Widget child;

  /// When true, draws a 2px blue border around `child` while focused.
  /// Display-only widgets (EMark/EPlot/EWeb/EImage) want this. Input
  /// widgets that already have their own focus visual (EInputText's
  /// border color flip) set this false.
  final bool drawFocusBorder;

  /// When false (default), the wrapper itself owns the focus node and
  /// receives focus on Tab. Set true for input widgets that need their
  /// inner FocusNode (e.g., TextField) to be the real focus target —
  /// the wrapper then just contributes its registration to the
  /// controller and proxies focus state to the inner node via the
  /// `proxyToFocusNode` argument.
  final bool isProxy;
  final FocusNode? proxyToFocusNode;

  const EpyxFocusable({
    super.key,
    required this.name,
    required this.group,
    required this.order,
    required this.skip,
    required this.child,
    this.onFocusChange,
    this.drawFocusBorder = true,
    this.isProxy = false,
    this.proxyToFocusNode,
  });

  @override
  State<EpyxFocusable> createState() => _EpyxFocusableState();
}

class _EpyxFocusableState extends State<EpyxFocusable> {
  late FocusNode _ownNode;
  FocusNode get _activeNode =>
      (widget.isProxy && widget.proxyToFocusNode != null)
          ? widget.proxyToFocusNode!
          : _ownNode;
  TabEntry? _entry;

  @override
  void initState() {
    super.initState();
    _ownNode = FocusNode(debugLabel: 'EpyxFocus(${widget.name})');
    _activeNode.addListener(_onFocusChange);
    _registerIfEligible();
  }

  @override
  void didUpdateWidget(covariant EpyxFocusable old) {
    super.didUpdateWidget(old);
    // Group / order / skip can change at runtime when α code reassigns
    // the.tab.group on a recalc. Re-register with new metadata; the
    // FocusNode itself stays so a re-render doesn't lose focus.
    if (old.group != widget.group ||
        old.order != widget.order ||
        old.skip != widget.skip ||
        old.name != widget.name) {
      _unregister();
      _registerIfEligible();
    }
  }

  void _registerIfEligible() {
    final g = widget.group;
    if (g == null) return; // Excluded from nav (default — opt-in).
    final ctl = TabGroupController.instance;
    _entry = TabEntry(
      group: g,
      order: widget.order,
      skip: widget.skip,
      name: widget.name,
      node: _activeNode,
      registrationSeq: ctl.nextSeq(),
    );
    ctl.register(_entry!);
  }

  void _unregister() {
    if (_entry == null) return;
    TabGroupController.instance.unregister(_entry!.node);
    _entry = null;
  }

  @override
  void dispose() {
    _unregister();
    _activeNode.removeListener(_onFocusChange);
    _ownNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    final focused = _activeNode.hasFocus;
    widget.onFocusChange?.call(focused);
    // Repaint the border. setState is cheap — one wrapper.
    setState(() {});
  }

  void _onTap() {
    final g = widget.group;
    if (g == null) return;
    // Switch group if needed, but DON'T focusFirst — we want THIS
    // node to focus, not the group's first entry.
    TabGroupController.instance.activate(g, focusFirst: false);
    // Request focus synchronously (works when the group was already
    // active) AND post-frame: when the click switches the active
    // group, this node's `canRequestFocus` is still false until the
    // ValueListenableBuilder rebuilds next frame, so the synchronous
    // request is denied. The post-frame retry lands focus once the
    // rebuild has flipped `canRequestFocus` true — without it the
    // user had to click twice.
    _activeNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activeNode.requestFocus();
    });
  }

  /// Wrap `child` so neither it nor any descendant can take focus —
  /// `descendantsAreFocusable: false` blocks the whole subtree. Used
  /// for ungrouped controls while a group is active (the design says
  /// every node outside the active group is non-focusable).
  Widget _nonFocusable(Widget child) {
    if (widget.isProxy && widget.proxyToFocusNode?.hasFocus == true) {
      widget.proxyToFocusNode!.unfocus();
    }
    return Focus(
      focusNode: _ownNode,
      canRequestFocus: false,
      skipTraversal: true,
      descendantsAreFocusable: false,
      child: child,
    );
  }

  /// `the.tab.skip = True`: the control is NOT a Tab stop, but stays
  /// fully interactive — you can still click it and edit it (e.g. an
  /// ETab the user wants to override cells in without it being in the
  /// Tab order). So: `skipTraversal: true` only; `canRequestFocus` and
  /// descendant focusability stay ON.
  Widget _tabSkipped(Widget child) {
    if (widget.isProxy) {
      final node = widget.proxyToFocusNode;
      if (node != null) {
        node.skipTraversal = true;
        node.canRequestFocus = true;
      }
      return child;
    }
    return Focus(
      focusNode: _ownNode,
      canRequestFocus: true,
      skipTraversal: true,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    // SKIP (`the.tab.skip = True`): not a Tab stop, but still clickable
    // / editable. Checked before the no-group opt-out — skip-without-
    // group is legitimate (e.g. an ETab the user excludes from Tab but
    // still wants to click cells in and override them).
    if (widget.skip) {
      return _tabSkipped(widget.child);
    }
    // UNGROUPED control (`the.tab.group` never set):
    //   - No group active anywhere → fully transparent passthrough, so
    //     a doclet that doesn't use tab groups behaves natively.
    //   - A group IS active → this control is "outside the group", so
    //     per the design every node outside the active group is
    //     non-focusable. Gate it off.
    if (g == null) {
      return ValueListenableBuilder<int?>(
        valueListenable: TabGroupController.instance.activeGroup,
        builder: (context, active, _) {
          if (active == null) return widget.child;
          return _nonFocusable(widget.child);
        },
      );
    }
    return ValueListenableBuilder<int?>(
      valueListenable: TabGroupController.instance.activeGroup,
      builder: (context, active, _) {
        final isActive = active == g && !widget.skip;

        Widget body = widget.child;
        if (widget.drawFocusBorder && _activeNode.hasFocus) {
          // position: foreground — paint the border ON TOP of the
          // child. The default (background) paints it behind, where an
          // opaque child (EMark panel, EPlot canvas, ETab grid) fully
          // occludes it — that's why non-EScalar controls showed no
          // focus box. EScalar's box is the TextField's own decoration,
          // unaffected by this.
          body = DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF0066FF), width: 2),
            ),
            child: body,
          );
        }
        body = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            _onTap();
          },
          child: body,
        );

        if (widget.isProxy) {
          final node = widget.proxyToFocusNode;
          if (node != null) {
            node.canRequestFocus = isActive;
            node.skipTraversal = !isActive;
            if (!isActive && node.hasFocus) {
              node.unfocus();
            }
          }
          // Honor tab_order for proxied widgets too. The inner widget's
          // own FocusNode is a descendant of `body`, so a
          // FocusTraversalOrder ancestor here feeds the traversal policy
          // the right ordering — without this, sliders / text fields /
          // ETab (all proxy-mode) ignored `the.tab.order`.
          return FocusTraversalOrder(
            order: NumericFocusOrder((widget.order ?? 0).toDouble()),
            child: body,
          );
        }

        return Focus(
          focusNode: _ownNode,
          canRequestFocus: isActive,
          skipTraversal: !isActive,
          // descendantsAreFocusable: false ALWAYS — a non-proxy
          // EpyxFocusable wraps a display widget (EMark / EPlot / EWeb
          // / EImage). It must be a SINGLE tab stop (`_ownNode`); the
          // widget's internal content (markdown links, selectable
          // text, the inner SuperPlot) must never become separate tab
          // stops, or Tab leaks inside the panel instead of advancing
          // to the next group member.
          descendantsAreFocusable: false,
          child: FocusTraversalOrder(
            order: NumericFocusOrder((widget.order ?? 0).toDouble()),
            child: body,
          ),
        );
      },
    );
  }
}
