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

  TabEntry({
    required this.group,
    required this.order,
    required this.skip,
    required this.name,
    required this.node,
    required this.registrationSeq,
  });
}

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
  }

  void unregister(FocusNode node) {
    entries.removeWhere((e) => e.node == node);
  }

  /// Allocate a sequence number for a new entry. Caller passes this
  /// into the TabEntry constructor; it's the final tie-breaker after
  /// (order, name) for sort stability.
  int nextSeq() => ++_seq;

  /// Sorted, focusable entries for a group:
  ///   - excludes skip=true
  ///   - sort by (order ?? infinity, registrationSeq)
  List<TabEntry> entriesInGroup(int group) => _entriesInGroup(group);

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
}

// NOTE: there is intentionally NO custom FocusTraversalPolicy here.
// Group containment is achieved purely by EpyxFocusable gating
// `canRequestFocus` — only the active group's nodes are focusable, so
// native Flutter Tab can only ever cycle those. A policy that filters
// `sortDescendants` (returning a subset) violates the policy contract
// — Flutter's `next()` still knows the dropped nodes are focusable and
// lands focus on stray FocusScopeNodes. Don't reintroduce one.
