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

import 'dart:async';

import 'package:flutter/material.dart';
import '../utils/diag_log.dart';
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

  // Ephemeral group-position pips: shown for a moment right after the
  // ACTIVE GROUP changes (Ctrl-J/K, Cmd-;, click into another group),
  // then faded out. Never shown for plain within-group Tab.
  bool _showGroupHint = false;
  Timer? _hintTimer;
  static const Duration _hintLinger = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _ownNode = FocusNode(debugLabel: 'EpyxFocus(${widget.name})');
    _activeNode.addListener(_onFocusChange);
    TabGroupController.instance.hasExplicitGroups
        .addListener(_onHasExplicitChanged);
    TabGroupController.instance.activeGroup
        .addListener(_onActiveGroupChanged);
    _registerIfEligible();
  }

  /// The active group changed — flash the position pips, then fade.
  void _onActiveGroupChanged() {
    if (!mounted) return;
    _hintTimer?.cancel();
    _hintTimer = Timer(_hintLinger, () {
      if (mounted) setState(() => _showGroupHint = false);
    });
    setState(() => _showGroupHint = true);
  }

  /// The implicit group appeared or dissolved — only an ungrouped
  /// control's effective group changes. Re-register it. Deferred to
  /// post-frame: this fires synchronously inside register()'s notify,
  /// where mutating the registry mid-iteration is unsafe. The build
  /// itself reacts via its ValueListenableBuilder, so no setState here.
  void _onHasExplicitChanged() {
    if (!mounted || widget.group != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.group != null) return;
      _unregister();
      _registerIfEligible();
    });
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

  /// Effective group: the explicit `the.tab.group`, or — when the
  /// doclet declares NO explicit groups anywhere — the implicit group
  /// so every control is navigable. Null only for an ungrouped control
  /// in a doclet that DOES have explicit groups elsewhere.
  int? _effectiveGroup() {
    if (widget.group != null) return widget.group;
    return TabGroupController.instance.hasExplicitGroups.value
        ? null
        : kImplicitGroup;
  }

  void _registerIfEligible() {
    final g = _effectiveGroup();
    if (g == null) return;
    final ctl = TabGroupController.instance;
    _entry = TabEntry(
      group: g,
      order: widget.order,
      skip: widget.skip,
      name: widget.name,
      node: _activeNode,
      registrationSeq: ctl.nextSeq(),
      isImplicit: widget.group == null,
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
    _hintTimer?.cancel();
    TabGroupController.instance.hasExplicitGroups
        .removeListener(_onHasExplicitChanged);
    TabGroupController.instance.activeGroup
        .removeListener(_onActiveGroupChanged);
    _unregister();
    _activeNode.removeListener(_onFocusChange);
    _ownNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    final focused = _activeNode.hasFocus;
    // [focus.diag] log every EpyxFocusable focus-state transition.
    // Bug 1: blue outline disappears on click + Cmd-E on the markdown.
    // Python's mark_ui_focus chain stays pinned to the clicked control,
    // but the Dart blue border is driven by `_activeNode.hasFocus`.
    // Something is stealing the FocusNode's focus on Cmd-E — this log
    // shows which control transitions to hasFocus=false and when, so
    // we can correlate with what mounted in the editor.
    diagLog('[focus.diag] EpyxFocusable(${widget.name}) '
        'hasFocus=$focused isProxy=${widget.isProxy} '
        't=${DateTime.now().millisecondsSinceEpoch}');
    widget.onFocusChange?.call(focused);
    // Repaint the border. setState is cheap — one wrapper.
    setState(() {});
  }

  void _onTap(int g) {
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
    // SKIP (`the.tab.skip = True`): not a Tab stop, but still clickable
    // / editable (e.g. an ETab excluded from Tab but whose cells the
    // user still overrides).
    if (widget.skip) {
      return _tabSkipped(widget.child);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: TabGroupController.instance.hasExplicitGroups,
      builder: (context, hasExplicit, _) {
        // Effective group: explicit `the.tab.group`, or the implicit
        // group when the doclet declares none. Null only when this
        // control is ungrouped AND explicit groups exist elsewhere.
        final g = widget.group ?? (hasExplicit ? null : kImplicitGroup);
        if (g == null) {
          // ETB-14: an ungrouped control in a doclet that DOES declare
          // groups elsewhere is kept OUT of the Tab / group cycle
          // (skipTraversal) but stays CLICK-FOCUSABLE — clicking in
          // still gives it keyboard / arrow-key input. Previously it
          // was fully non-focusable (descendantsAreFocusable: false),
          // which silently made a table keyboard-dead whenever its
          // `the.tab.group` was simply omitted (e.g. data.specs while
          // data.numbers was grouped). Same flags as `the.tab.skip`.
          return _tabSkipped(widget.child);
        }
        return _buildGrouped(g);
      },
    );
  }

  Widget _buildGrouped(int g) {
    return ValueListenableBuilder<int?>(
      valueListenable: TabGroupController.instance.activeGroup,
      builder: (context, active, _) {
        final isActive = active == g;

        Widget body = widget.child;
        if (widget.drawFocusBorder) {
          // Modern focus GLOW — a soft blue halo just outside the
          // control's edge, replacing the old 2px line.
          //  - BlurStyle.outer: the blur is painted ENTIRELY outside
          //    the box, so it never spills inward over the content.
          //  - boxShadow is paint-only: the control's size and its
          //    siblings never shift — no resizing.
          //  - The DecoratedBox stays in the tree always; only the
          //    shadow list toggles, so the child's State isn't
          //    recreated on focus change (the grey-grid bug).
          // Two layers: a tight bright ring + a wider soft halo.
          body = DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: _activeNode.hasFocus
                  ? const [
                      BoxShadow(
                        color: Color(0x880066FF),
                        blurRadius: 10,
                        spreadRadius: 1,
                        blurStyle: BlurStyle.outer,
                      ),
                      BoxShadow(
                        color: Color(0x3D0066FF),
                        blurRadius: 28,
                        spreadRadius: 3,
                        blurStyle: BlurStyle.outer,
                      ),
                    ]
                  : const [],
            ),
            child: body,
          );
        }
        // Group-position pips — top-right of the focus box. One dot per
        // group, the active one filled. Shown EPHEMERALLY: only just
        // after the active group changes (_showGroupHint, set by
        // _onActiveGroupChanged and cleared by a 1.5s timer), and only
        // on the focused control of a multi-group doclet. Not shown for
        // within-group Tab. Always in the tree (opacity-toggled) so the
        // child's State isn't recreated when the pips appear/disappear.
        final groups = TabGroupController.instance.allGroups();
        final activeIdx = groups.indexOf(g);
        final showHint = _showGroupHint &&
            _activeNode.hasFocus &&
            groups.length >= 2 &&
            activeIdx >= 0;
        body = Stack(
          clipBehavior: Clip.none,
          children: [
            body,
            Positioned(
              top: 2,
              right: 2,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: showHint ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: _GroupHint(
                    count: groups.length,
                    activeIndex: activeIdx,
                  ),
                ),
              ),
            ),
          ],
        );

        body = Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            _onTap(g);
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

/// Ephemeral group-change hint: the Ctrl-K / Ctrl-J switch keys
/// flanking a row of position pips (one dot per group, active one
/// filled). `⌃K` on the left = previous group, `⌃J` on the right =
/// next — so the layout itself shows which key goes which way. Shown
/// briefly when the active group changes, then faded.
class _GroupHint extends StatelessWidget {
  final int count;
  final int activeIndex;
  const _GroupHint({required this.count, required this.activeIndex});

  static const _keyStyle = TextStyle(
    color: Color(0xFF9DC3FF),
    fontSize: 9,
    fontWeight: FontWeight.w600,
    height: 1.0,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xCC0A2540),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⌃K', style: _keyStyle),
          const SizedBox(width: 6),
          ...List.generate(count, (i) {
            final active = i == activeIndex;
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? const Color(0xFF4C9DFF)
                      : const Color(0x55FFFFFF),
                ),
              ),
            );
          }),
          const SizedBox(width: 6),
          const Text('⌃J', style: _keyStyle),
        ],
      ),
    );
  }
}
