// Epyx tab-group focus controller.
//
// Single source of truth for "which group of controls is currently
// tabbable." Only the active group's FocusNodes are reachable by
// keyboard traversal; everything else is excluded via canRequestFocus
// false + skipTraversal true. This eliminates the marker-vs-real-focus
// race: there's no marker, only Flutter focus, and Flutter can only
// land focus on the active group's nodes.
//
// Used by:
//   - EpyxFocusable wrapper around each focusable Flet control widget
//   - Page.dart Cmd-; handler (calls cycle()) and Cmd-Shift-;/Cmd-Backspace
//   - Each control's tap/focus handler (calls activate())
//   - Python side observes focus changes via the existing focus_change
//     events emitted by each widget's wrapper
//
// Group / order metadata is mirrored from each Property's tab_group /
// tab_order / tab_skip into Flet control properties, then read here.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class TabEntry {
  /// 1-based group label (matches the.tab.group = N).
  final int group;

  /// Within-group order; null = property-tree order, ties broken by
  /// registration order.
  final int? order;

  /// `the.tab.skip = True` — never receives focus even when in the
  /// active group (e.g., display-only field inside an input group).
  final bool skip;

  /// Property name (logical). Used for diagnostics and to report focus
  /// changes back to Python.
  final String name;

  final FocusNode node;

  /// Monotonically increasing registration counter — final tie-breaker
  /// when (order, name) match.
  final int registrationSeq;

  /// True when this entry is in the IMPLICIT group — i.e. the control
  /// has no `the.tab.group` of its own and the doclet defines no
  /// explicit groups at all, so every control falls into one implicit
  /// group. Implicit entries don't count toward `hasExplicitGroups`.
  final bool isImplicit;

  TabEntry({
    required this.group,
    required this.order,
    required this.skip,
    required this.name,
    required this.node,
    required this.registrationSeq,
    this.isImplicit = false,
  });
}

/// The group id used for the implicit group (see TabEntry.isImplicit).
const int kImplicitGroup = 0;

/// Process-singleton. Imported by Page.dart and every extension that
/// wraps a focusable widget. Lives in flet core so all extensions can
/// import from the same dart library path.
class TabGroupController {
  TabGroupController._();
  static final TabGroupController instance = TabGroupController._();

  /// Active group — null until the first control registers. Listened
  /// to by every EpyxFocusable so the active group's wrappers rebuild
  /// with canRequestFocus=true and the rest with false.
  final ValueNotifier<int?> activeGroup = ValueNotifier<int?>(null);

  /// True iff some control declares an explicit `the.tab.group`. When
  /// false, the whole doclet has no groups, so every control joins one
  /// implicit group (everything focusable, Tab cycles all). When it
  /// flips true, the implicit group dissolves — ungrouped controls
  /// listen to this and re-register / rebuild accordingly.
  final ValueNotifier<bool> hasExplicitGroups = ValueNotifier<bool>(false);

  /// All registered focusable entries. Mutated under no lock — Dart
  /// is single-threaded, and registration only happens on
  /// State.initState / dispose which the framework serializes.
  final List<TabEntry> entries = [];

  int _seq = 0;

  /// True between activate(N) and first focus settle — suppresses any
  /// auto-activate calls from focus_change callbacks that fire while
  /// Flutter is still moving keyboard focus to our requested node.
  /// Without this, the chain "we requestFocus(X) → X's onFocusChange
  /// fires → onFocusChange calls activate(X.group)" could re-trigger
  /// requestFocus mid-flight.
  bool _activating = false;

  void register(TabEntry e) {
    entries.add(e);
    if (activeGroup.value == null) {
      activeGroup.value = e.group;
    }
    _refreshHasExplicit();
  }

  void unregister(FocusNode node) {
    entries.removeWhere((e) => e.node == node);
    _refreshHasExplicit();
  }

  /// Recompute `hasExplicitGroups` from the registry. When it flips
  /// false→true the implicit group has just dissolved: if the active
  /// group is no longer a real (explicit) group, jump to the first
  /// explicit one so focus isn't stranded on the dead implicit group.
  void _refreshHasExplicit() {
    final has = entries.any((e) => !e.isImplicit);
    if (hasExplicitGroups.value == has) return;
    hasExplicitGroups.value = has;
    if (has) {
      final explicit = entries
          .where((e) => !e.isImplicit)
          .map((e) => e.group)
          .toSet()
          .toList()
        ..sort();
      if (explicit.isNotEmpty && !explicit.contains(activeGroup.value)) {
        activeGroup.value = explicit.first;
      }
    }
  }

  /// Allocate a sequence number for a new entry. Caller passes this
  /// into the TabEntry constructor; it's the final tie-breaker after
  /// (order, name) for sort stability.
  int nextSeq() => ++_seq;

  /// Sorted, focusable entries for a group:
  ///   - excludes skip=true
  ///   - sort by (order ?? infinity, registrationSeq)
  List<TabEntry> entriesInGroup(int group) => _entriesInGroup(group);

  /// Sorted distinct group ids that have at least one non-skip entry.
  List<int> allGroups() => _allGroups();

  /// "2/3"-style label — group `g`'s 1-based position out of the total
  /// group count. Empty when there are fewer than 2 groups (nothing to
  /// switch to, so the on-screen hint pill stays hidden).
  String groupPositionLabel(int g) {
    final groups = _allGroups();
    if (groups.length < 2) return '';
    final idx = groups.indexOf(g);
    if (idx < 0) return '';
    return '${idx + 1}/${groups.length}';
  }

  List<TabEntry> _entriesInGroup(int group) {
    final inGroup = entries.where((e) => e.group == group && !e.skip).toList();
    inGroup.sort((a, b) {
      final ao = a.order ?? 1 << 30;
      final bo = b.order ?? 1 << 30;
      if (ao != bo) return ao.compareTo(bo);
      return a.registrationSeq.compareTo(b.registrationSeq);
    });
    return inGroup;
  }

  /// Sorted unique group IDs that have at least one non-skip entry.
  /// Cycling source for Cmd-;.
  List<int> _allGroups() {
    final s = <int>{};
    for (final e in entries) {
      if (!e.skip) s.add(e.group);
    }
    final out = s.toList()..sort();
    return out;
  }

  /// Clear the active group — "free" mode: no doclet tab group is
  /// active, so grouped controls are non-focusable and ungrouped
  /// controls / chrome (e.g. the AgentView) behave natively. Called
  /// when the user clicks into chrome that has no group, so they can
  /// use it without a doclet group trapping focus. Cmd-; re-enters
  /// group navigation.
  void clearActiveGroup() {
    if (activeGroup.value != null) {
      activeGroup.value = null;
    }
  }

  /// Activate group `g`. If `focusFirst` is true, calls
  /// requestFocus on the first entry of that group. Click-from-
  /// elsewhere passes focusFirst=false because the click target itself
  /// will request focus.
  void activate(int g, {bool focusFirst = true}) {
    if (activeGroup.value == g && !focusFirst) return;
    _activating = true;
    activeGroup.value = g;
    if (focusFirst) {
      final inGroup = _entriesInGroup(g);
      if (inGroup.isNotEmpty) {
        // Schedule on next frame so the activeGroup listeners have
        // first chance to rebuild Focus widgets with canRequestFocus
        // newly = true. Without this, requestFocus runs against a
        // FocusNode whose canRequestFocus is still false from the
        // prior frame, and Flutter silently drops the request.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final node = inGroup.first.node;
          node.requestFocus();
          // The target may be scrolled out of view (a pane's ListView
          // parked elsewhere). Native Tab auto-scrolls via the
          // traversal policy, but our explicit requestFocus does not —
          // so scroll the focused control to the centre of whatever
          // scrollables enclose it. Without this, Cmd-; can move focus
          // to a control the user can't see.
          final ctx = node.context;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0.5,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
            );
          }
          _activating = false;
        });
      } else {
        _activating = false;
      }
    } else {
      _activating = false;
    }
  }

  // NOTE: within-group Tab movement is intentionally NOT handled here.
  // Flutter's own FocusTraversalPolicy cycles Tab through the focusable
  // nodes, and EpyxFocusable makes only the active group's nodes
  // focusable — so native Tab already does the right thing. A manual
  // tab() that called requestFocus ran a parallel traversal that
  // fought Flutter's and broke within-group Tab; it was removed.

  /// Cmd-; (direction=+1) / Cmd-Shift-; (-1) / Cmd-Backspace (-1).
  /// Wraps at ends. If no group is currently active, lands on the
  /// first/last group depending on direction.
  void cycle(int direction) {
    final groups = _allGroups();
    if (groups.isEmpty) return;
    final cur = activeGroup.value;
    int idx;
    if (cur == null || !groups.contains(cur)) {
      idx = direction > 0 ? 0 : groups.length - 1;
    } else {
      final cIdx = groups.indexOf(cur);
      idx = (cIdx + direction) % groups.length;
      if (idx < 0) idx += groups.length;
    }
    activate(groups[idx], focusFirst: true);
  }

  bool get isActivating => _activating;

  /// Debug dump used by /debug-focus on the Python side via JS interop
  /// (later) — for now, callers can print this from a Dart breakpoint.
  Map<String, Object?> diagnostics() {
    return {
      'activeGroup': activeGroup.value,
      'allGroups': _allGroups(),
      'entries': entries
          .map((e) => {
                'name': e.name,
                'group': e.group,
                'order': e.order,
                'skip': e.skip,
                'hasFocus': e.node.hasFocus,
                'canRequestFocus': e.node.canRequestFocus,
              })
          .toList(),
    };
  }

  /// Handle a raw Tab / Shift-Tab key event for group-constrained
  /// traversal. Returns true when focus was moved inside the active
  /// group — the caller then marks the event handled so Flutter's own
  /// traversal never runs. Returns false to let native traversal
  /// proceed (focus in the editor, free mode, or no active group).
  ///
  /// WHY intercept the key rather than install a FocusTraversalPolicy:
  /// `canRequestFocus` gating only covers EpyxFocusable controls — the
  /// vim editor and orchestrator chrome carry ungated focusable widgets,
  /// so once either is on screen native Tab escapes the group ("the
  /// focus abyss"). A custom FocusTraversalPolicy is unreliable here
  /// (WidgetsApp installs its own FocusTraversalGroup; ours was never
  /// resolved as the nearest one). Intercepting the key in an ancestor
  /// `Focus.onKeyEvent` — which runs before the `Shortcuts` widget that
  /// fires `NextFocusIntent` — both moves focus AND stops the native
  /// traversal, so there is no parallel-traversal fight.
  bool handleTabKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.tab) return false;
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return false;
    final dir = HardwareKeyboard.instance.isShiftPressed ? -1 : 1;
    return _moveFocusInGroup(node, dir);
  }

  /// Move keyboard focus by [dir] (+1 next / -1 previous), constrained
  /// to the active doclet group. Falls back to native traversal when
  /// [current] is not in the active group (editor / free mode).
  ///
  /// Proxy widgets (EInputText, ESlider) that run their own key
  /// handling MUST call this instead of a bare `FocusNode.nextFocus()`
  /// — a bare call uses Flutter's default policy and escapes the group
  /// into the editor / orchestrator chrome ("the focus abyss").
  void moveFocus(FocusNode current, int dir) {
    if (_moveFocusInGroup(current, dir)) return;
    if (dir > 0) {
      current.nextFocus();
    } else {
      current.previousFocus();
    }
  }

  /// Move focus by [dir] within the active group when [current] is one
  /// of its registered nodes. Returns true once handled (focus moved,
  /// or a single-control group consumed the key to stay put); false
  /// when focus is not in the active group so the caller defers.
  bool _moveFocusInGroup(FocusNode current, int dir) {
    final active = activeGroup.value;
    if (active == null) return false;
    final inGroup = _entriesInGroup(active);
    final idx = inGroup.indexWhere((e) => e.node == current);
    if (idx < 0) return false;
    if (inGroup.length == 1) return true;
    var ni = (idx + dir) % inGroup.length;
    if (ni < 0) ni += inGroup.length;
    final target = inGroup[ni].node;
    target.requestFocus();
    final ctx = target.context;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
    return true;
  }
}
