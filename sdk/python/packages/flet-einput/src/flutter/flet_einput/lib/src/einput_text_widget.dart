import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dom_helpers_stub.dart'
    if (dart.library.js_interop) 'dom_helpers_web.dart' as dom;

import 'package:flet/flet.dart';
import 'package:flet_micropython/flet_micropython.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'input_command_executor.dart';

void _einputDiag(String msg) {
  if (kIsWeb) return;
  try {
    final stamp = DateTime.now().toIso8601String();
    File('/tmp/einput_keys.log').writeAsStringSync(
      '[$stamp] $msg\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

/// Custom Flet input widget — Flutter TextField with spreadsheet-grade
/// focus model and on_key_code scripting via the canonical render plane.
///
/// Baseline behavior (always active, even when no on_key projection exists):
/// - Focus → select-all on the controller (so type-to-replace works)
/// - Enter (single-line) → fire on_submit, blur
/// - Escape → restore pre-edit value, blur
/// - Tab → focusNode.nextFocus()
/// - Shift+Tab → focusNode.previousFocus()
/// - Any other key → fall through to the underlying TextField
///
/// Override behavior: when the host EScalar's spec_code defines
/// `def on_key(key, modifiers, value, cursor, selection)`, that function is
/// evaluated client-side via MicroPython on every key press BEFORE the
/// baseline runs. Returning a list of command dicts overrides the default;
/// returning None falls through to the baseline.
class EInputTextWidget extends StatefulWidget {
  final Control control;

  const EInputTextWidget({super.key, required this.control});

  @override
  State<EInputTextWidget> createState() => _EInputTextWidgetState();
}

bool _globalKeyListenerInstalled = false;

class _EInputTextWidgetState extends State<EInputTextWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  /// Snapshot of the value at focus time, used to restore on Escape.
  String _savedValueBeforeEdit = '';

  /// Most recent raw value pushed by Python (for dedup).
  String _lastPushedValue = '';

  /// Most recent formatted display pushed by Python (for dedup).
  String _lastPushedDisplay = '';

  /// Most recent host_control_id we subscribed to — so we can re-subscribe
  /// when Python pushes a different id (avoids needing a widget remount).
  String _lastHostId = '';

  /// True while the user is actively editing — suppresses Python value pushes
  /// from clobbering the in-flight text.
  bool _userIsEditing = false;

  /// True after the user has typed at least one character in the current
  /// edit session. Distinct from `_userIsEditing` (which goes true on
  /// any focus gain): we want α-computed display pushes to land *while
  /// focused but pristine* (so `if the.is_focused: the.display = ...`
  /// works), and only block them once the user starts typing (so the
  /// typed buffer isn't clobbered). Reset to false on focus change.
  bool _userHasTyped = false;

  /// Unregister callback for the render plane listener.
  VoidCallback? _renderPlaneUnsubscribe;

  /// Cached on_key projection — refreshed via the render plane listener.
  Map<String, dynamic>? _onKeyProjection;

  @override
  void initState() {
    super.initState();
    // Initial text: prefer the formatted display if Python has pushed one
    // (idle state), otherwise the raw value. This way the field renders
    // correctly on first mount even before any user interaction.
    final initialValue = widget.control.getString("value") ?? '';
    final initialDisplay = widget.control.getString("display") ?? '';
    final initialText = initialDisplay.isNotEmpty ? initialDisplay : initialValue;
    _controller = TextEditingController(text: initialText);
    _lastPushedValue = initialValue;
    _lastPushedDisplay = initialDisplay;
    // Set onKeyEvent on the FocusNode itself so we intercept keys BEFORE
    // EditableText processes them. A wrapping Focus widget only sees keys
    // AFTER the TextField has had a chance to consume them — single-line
    // TextField consumes Arrow_Up/Down (cursor to start/end), so on_key
    // could never override those if we waited for the bubble.
    _focusNode = FocusNode(
      debugLabel: 'EInputText',
      onKeyEvent: _onKeyEvent,
    );
    _focusNode.addListener(_onFocusChanged);
    widget.control.addListener(_onControlChanged);
    _refreshOnKeyProjection();
    _subscribeRenderPlane();
    _einputDiag('mount ctrl=${widget.control.id} hostId=${widget.control.getString("host_control_id") ?? ""}');
    // One-shot global keyboard listener (registered once for the whole app
    // — first widget to mount installs it). Logs every hardware key event
    // before any focus dispatch, so we can tell on desktop whether keys
    // reach Flutter at all even when the field is focused.
    if (!_globalKeyListenerInstalled) {
      _globalKeyListenerInstalled = true;
      HardwareKeyboard.instance.addHandler((KeyEvent event) {
        _einputDiag('HardwareKeyboard event=${event.runtimeType} '
            'key=${event.logicalKey.debugName} '
            'focusedNode=${FocusManager.instance.primaryFocus?.debugLabel ?? "<none>"}');
        return false;  // don't claim — let normal dispatch proceed
      });
    }
    print('[EInputText] mount id=${widget.control.id} text="${_controller.text}" hostId=${widget.control.getString("host_control_id") ?? ""}');
  }

  @override
  void dispose() {
    print('[EInputText] unmount id=${widget.control.id}');
    _renderPlaneUnsubscribe?.call();
    widget.control.removeListener(_onControlChanged);
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  // ─── Render plane integration ───────────────────────────────────────────

  void _subscribeRenderPlane() {
    final hostId = widget.control.getString("host_control_id") ?? '';
    _lastHostId = hostId;
    if (hostId.isEmpty) return;
    _renderPlaneUnsubscribe = RenderPlaneControl.addListener(hostId, _refreshOnKeyProjection);
  }

  void _resubscribeRenderPlaneIfHostChanged() {
    final hostId = widget.control.getString("host_control_id") ?? '';
    if (hostId == _lastHostId) return;
    print('[EInputText] hostId changed: "$_lastHostId" → "$hostId"');
    // Unsubscribe from the old host (if any), subscribe to the new one.
    _renderPlaneUnsubscribe?.call();
    _renderPlaneUnsubscribe = null;
    _lastHostId = hostId;
    if (hostId.isNotEmpty) {
      _renderPlaneUnsubscribe =
          RenderPlaneControl.addListener(hostId, _refreshOnKeyProjection);
    }
    _refreshOnKeyProjection();
  }

  void _refreshOnKeyProjection() {
    final hostId = widget.control.getString("host_control_id") ?? '';
    if (hostId.isEmpty) {
      _onKeyProjection = null;
      return;
    }
    _onKeyProjection = RenderPlaneControl.getProjection(hostId, 'on_key');
    print('[EInputText] on_key projection ${_onKeyProjection == null ? "CLEARED" : "LOADED"} for hostId=$hostId');
  }

  // ─── Python → Dart sync ─────────────────────────────────────────────────

  void _onControlChanged() {
    // host_control_id can change after the initial mount (Python pushes it
    // in the first recalc). React without needing a widget remount.
    _resubscribeRenderPlaneIfHostChanged();

    final newValue = widget.control.getString("value") ?? '';
    final newDisplay = widget.control.getString("display") ?? '';
    final valueChanged = newValue != _lastPushedValue;
    final displayChanged = newDisplay != _lastPushedDisplay;
    if (!valueChanged && !displayChanged) return;
    _lastPushedValue = newValue;
    _lastPushedDisplay = newDisplay;

    // Don't clobber the user's in-flight typing — but only once they've
    // actually started typing in this edit session. While focused but
    // pristine (just clicked, no keystroke yet), Python's focus-driven
    // recalc may push a new α-computed `display` (e.g. higher precision
    // because `the.is_focused` flipped True), and we want that to land.
    if (_userHasTyped) return;

    // When idle, prefer the formatted display; fall back to the raw value.
    final showText = newDisplay.isNotEmpty ? newDisplay : newValue;
    if (_controller.text == showText) return;
    print('[EInputText] Python pushed: value="$newValue" display="$newDisplay" → showing "$showText"');
    _controller.value = TextEditingValue(
      text: showText,
      selection: TextSelection.collapsed(offset: showText.length),
    );
  }

  // ─── Focus / commit / cancel ────────────────────────────────────────────

  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    _einputDiag('focus changed: ctrl=${widget.control.id} hasFocus=$hasFocus '
        'hostId=${widget.control.getString("host_control_id") ?? ""}');
    print('[EInputText] focus changed: hasFocus=$hasFocus text="${_controller.text}"');
    if (hasFocus) {
      _userIsEditing = true;
      _userHasTyped = false;
      // Snapshot the RAW pre-edit value (not the formatted display) so
      // the.cancel restores something the user can re-edit. Subsequent
      // command-list operations (replace/insert/...) mutate the
      // controller but never touch _savedValueBeforeEdit, so a chained
      // `the.replace('SCRATCH').cancel()` reverts to this snapshot.
      final rawValue = widget.control.getString("value") ?? '';
      _savedValueBeforeEdit =
          rawValue.isNotEmpty ? rawValue : _controller.text;
      // No automatic swap-to-raw-value-on-focus: α code may set a
      // distinct focused-mode display via `if the.is_focused: the.display
      // = ...`, and the focus-driven Python recalc will push it through
      // _onControlChanged (allowed because _userHasTyped is False).
      // Type-to-replace still works — the next printable key clears the
      // selection (set up by the postFrameCallback below) and starts the
      // typed buffer. Cancel still restores _savedValueBeforeEdit.
      // Spreadsheet feel: select all so the next printable char replaces.
      // Deferred to after the current frame because Flutter's TextField
      // tap handler sets the cursor to a collapsed position at the tap
      // offset AFTER the focus listener runs — setting selection here
      // directly gets overridden. postFrameCallback lands after the tap.
      final selectAll = widget.control.getBool("select_all_on_focus", true) ?? true;
      if (selectAll && _controller.text.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.hasFocus) return;
          _controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _controller.text.length,
          );
          print('[EInputText] selectAll applied, selection=${_controller.selection}');
        });
      }
      _fireFocusChange(true);
    } else {
      // Blur — commit any pending edit, then clear the editing flag so
      // _onControlChanged is allowed to update the controller from
      // Python pushes again.
      if (_userIsEditing) {
        _commit('blur');
      }
      _userIsEditing = false;
      _userHasTyped = false;
      if (_suppressDisplayRestoreOnNextBlur) {
        // Cancel just fired and put the saved raw value into the
        // controller. Don't clobber it with the formatted display.
        _suppressDisplayRestoreOnNextBlur = false;
      } else {
        // Restore the formatted display so the field shows the idle text
        // again until the next recalc pushes a fresh display.
        final display = widget.control.getString("display") ?? '';
        if (display.isNotEmpty && _controller.text != display) {
          _controller.value = TextEditingValue(
            text: display,
            selection: TextSelection.collapsed(offset: display.length),
          );
        }
      }
      _fireFocusChange(false);
    }
  }

  void _commit(String reason) {
    // IMPORTANT: do NOT set _userIsEditing = false here. The flag tracks
    // whether the field is ACTIVELY focused, not whether the value has
    // been committed. The user may commit (Enter) while keeping focus to
    // continue editing — clearing the flag would let _onControlChanged
    // clobber the controller with the formatted display on the next
    // recalc, replacing the user's typed value mid-edit. The flag is
    // cleared only on actual blur (handled in _onFocusChanged).
    final value = _controller.text;
    _lastPushedValue = value;
    // The value is passed in the event payload — the Python handler
    // (ETextField._handle_submit) extracts it from e.data. We deliberately
    // do NOT call updateProperties with python: true here because Flet's
    // updateControl ↔ controlEvent ordering isn't guaranteed for custom
    // controls, and a stale e.control.value in the handler bit us before.
    print('[EInputText] commit: reason=$reason value="$value"');
    widget.control.triggerEventWithoutSubscribers(
      'submit',
      jsonEncode({'value': value, 'reason': reason}),
    );
  }

  void _onChange(String value) {
    // First actual keystroke in this edit session: the user has taken
    // ownership of the controller. _onControlChanged now declines to
    // overwrite display until next focus change.
    _userHasTyped = true;
    // Stash locally so _onControlChanged doesn't fight us if Python re-pushes
    // the same string. The per-keystroke value_change event carries the
    // value in its payload — ETextField._handle_value_change reads it from
    // e.data and sets self.text_field.value accordingly.
    _lastPushedValue = value;
    widget.control.triggerEventWithoutSubscribers(
      'value_change',
      jsonEncode({'value': value}),
    );
  }

  void _cancel() {
    // Cancel restores the pre-edit text and unfocuses. We clear the
    // editing flag BEFORE unfocusing so the blur-side branch in
    // _onFocusChanged doesn't fire a phantom commit with the restored
    // value (cancel is the opposite of commit; the value should not
    // round-trip back to Python). Also: don't let the unfocus branch
    // overwrite the controller with the formatted display — keep the
    // raw saved value visible. We DO NOT call _commit here.
    _userIsEditing = false;
    _userHasTyped = false;
    _controller.value = TextEditingValue(
      text: _savedValueBeforeEdit,
      selection: TextSelection.collapsed(offset: _savedValueBeforeEdit.length),
    );
    // Stash a sentinel so _onFocusChanged knows we just cancelled and
    // should not overwrite controller text with the formatted display.
    _suppressDisplayRestoreOnNextBlur = true;
    // Fire cancel event so the Python side can re-run the α snippet
    // with `the.cancel == True` for branchy snippets like
    // `if the.cancel: the.field.color('#FF00FF')`.
    widget.control.triggerEventWithoutSubscribers('cancel', '{}');
    if (_focusNode.hasFocus) _focusNode.unfocus();
  }

  bool _suppressDisplayRestoreOnNextBlur = false;

  void _fireFocusChange(bool focused) {
    // E12: push state flags as Python props so the host EScalar's α
    // code can read `the.field.is_focused` / `the.field.is_editing`
    // and pivot display formatting on interaction state. Edit and
    // focus are coupled here (edit starts on focus, ends on blur)
    // — same lifecycle, two names for symmetry with ETab's per-cell
    // ctx where the distinction matters more.
    widget.control.updateProperties(
      {'is_focused': focused, 'is_editing': focused},
      python: true,
      notify: false,
    );
    widget.control.triggerEventWithoutSubscribers(
      'focus_change',
      jsonEncode({'focused': focused}),
    );
  }

  void _fireBanner(String message, String level) {
    widget.control.triggerEventWithoutSubscribers(
      'banner',
      jsonEncode({'message': message, 'level': level}),
    );
    // Surface the banner in the DOM so headless tests can read it via
    // innerText. Flutter web with canvaskit renders all text on canvas,
    // so a Text widget alone wouldn't be findable. We mirror the latest
    // banner into a hidden DOM div via dart:js_interop for test visibility.
    _publishLastBannerToDom(message, level);
  }

  void _publishLastBannerToDom(String message, String level) {
    dom.publishBanner(message, level);
  }

  void _publishBeepToDom() {
    dom.publishBeep();
  }

  // ─── Key handling ────────────────────────────────────────────────────────
  //
  // Enter is special — it travels through DIFFERENT paths on different
  // platforms. On web, FocusNode.onKeyEvent fires for Enter and our handler
  // runs synchronously. On desktop, Flutter routes Enter through the
  // platform input layer (TextInputClient.performAction → onEditingComplete
  // / onSubmitted on the TextField), bypassing FocusNode.onKeyEvent entirely.
  //
  // To make Enter work on every platform we wire BOTH paths to the same
  // handler `_handleEnter`. A per-frame de-dup flag (`_enterHandledThisFrame`)
  // prevents double-fire on the rare platform where both paths reach us.

  bool _enterHandledThisFrame = false;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    _einputDiag('FocusNode.onKeyEvent FIRED ctrl=${widget.control.id} '
        'evt=${event.runtimeType} key=${event.logicalKey.debugName} '
        'hasFocus=${node.hasFocus} hostId=${widget.control.getString("host_control_id") ?? ""}');
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shiftDown = HardwareKeyboard.instance.isShiftPressed;
    final isMultiline = widget.control.getBool("multiline", false) ?? false;

    // Enter goes through the unified handler so desktop (via onSubmitted)
    // and web (via this onKeyEvent) take the same path.
    if (key == LogicalKeyboardKey.enter && !isMultiline) {
      final handled = _handleEnter(shiftDown: shiftDown);
      return handled ? KeyEventResult.handled : KeyEventResult.ignored;
    }

    // For non-Enter keys, fire on_key projection first, then fall through
    // to baseline.
    if (_onKeyProjection != null && MicroPythonService.isReady) {
      final handled = _evalOnKey(event);
      if (handled) return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      print('[EInputText] baseline: Escape → cancel');
      _cancel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !shiftDown) {
      print('[EInputText] baseline: Tab → nextFocus');
      _commit('tab');
      _focusNode.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && shiftDown) {
      print('[EInputText] baseline: Shift+Tab → previousFocus');
      _commit('tab');
      _focusNode.previousFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Single source of truth for Enter handling. Called by both
  /// `FocusNode.onKeyEvent` (web path) and the TextField's
  /// `onEditingComplete` callback (desktop path).
  ///
  /// Returns true if the user's on_key projection handled it OR the
  /// baseline ran successfully.
  bool _handleEnter({bool shiftDown = false}) {
    if (_enterHandledThisFrame) {
      return true;
    }
    _enterHandledThisFrame = true;
    // Reset the flag after the current frame so the next Enter press is
    // processed normally.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterHandledThisFrame = false;
    });

    // 1. Try the user's on_key projection first. We synthesize a key
    //    event-like context with key="Enter" and run on_key.
    if (_onKeyProjection != null && MicroPythonService.isReady) {
      final handled = _evalOnKeyForName('Enter', shiftDown: shiftDown);
      if (handled) return true;
    }

    // 2. Baseline: commit + move to next focusable. Shift+Enter → previous.
    _commit('enter');
    if (shiftDown) {
      _focusNode.previousFocus();
    } else {
      _focusNode.nextFocus();
    }
    return true;
  }

  /// Canonicalize a `set_value` command's payload to its shortest
  /// round-trip decimal string.
  ///
  /// Why: MicroPython's float-to-string emits fixed precision (e.g.
  /// `"6.0000000000000000"` for an exact 6.0), so values that are
  /// IEEE-clean show up in the buffer as noisy strings. Round-tripping
  /// through `double.parse` + `toString()` re-canonicalizes via Dart's
  /// shortest round-trip algorithm: lossless (every distinguishable
  /// double survives, including high-precision scientific values like
  /// `1.0000000000000125`) but strips the spurious extra digits MP
  /// added.
  ///
  /// Genuinely noisy doubles (e.g. `0.1 + 0.2`) stay noisy by design —
  /// that's the actual stored value; the way to hide it is per-control
  /// `display_code` formatting, not lossy rounding here.
  String _canonicalizeForBuffer(dynamic raw) {
    if (raw == null) return '';
    if (raw is num) return raw.toString();
    final s = raw.toString();
    final v = double.tryParse(s);
    if (v == null) return s;
    return v.toString();
  }

  /// Read the host EScalar's *committed* value, parsed per ptype.
  ///
  /// `the.field.value` in α on_key blocks should always be the typed,
  /// committed scalar value — never the half-typed buffer. This helper
  /// looks up the `host_value` + `ptype` properties pushed down by the
  /// host EScalar and coerces. On parse failure (rare; the server sends
  /// a stringified typed value) it falls back to the raw string so user
  /// code at least sees something rather than crashing.
  dynamic _typedHostValue() {
    final raw = widget.control.getString('host_value') ?? '';
    final pt = widget.control.getString('ptype') ?? 'str';
    if (pt == 'int') {
      final v = int.tryParse(raw);
      if (v != null) return v;
      // Try float-then-truncate: server might have sent "5.0" for int.
      final f = double.tryParse(raw);
      if (f != null) return f.toInt();
      return raw;
    }
    if (pt == 'float') {
      final v = double.tryParse(raw);
      if (v != null) return v;
      return raw;
    }
    return raw;
  }

  /// Like `_evalOnKey(event)` but takes the key name directly. Used by
  /// `_handleEnter` since the desktop path doesn't have a real KeyEvent.
  bool _evalOnKeyForName(String keyName, {bool shiftDown = false}) {
    final proj = _onKeyProjection;
    if (proj == null) return false;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String?;
    if (evalExpr == null || evalExpr.isEmpty) return false;

    final mods = _buildModifiers();
    final selection = _controller.selection;
    final selectionState = !selection.isValid
        ? 'none'
        : selection.isCollapsed
            ? 'none'
            : (selection.start == 0 && selection.end == _controller.text.length)
                ? 'all'
                : 'partial';
    final ctx = <String, dynamic>{
      'key': keyName,
      'modifiers': mods,
      'value': _typedHostValue(),
      'buffer': _controller.text,
      'cursor': selection.isValid ? selection.baseOffset : 0,
      'selection': selectionState,
      'selection_start': selection.isValid ? selection.start : 0,
      'selection_end': selection.isValid ? selection.end : 0,
    };
    try {
      final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
      if (result == null) return false;
      if (result is! List) return false;
      if (result.isEmpty) return false;

      // Same set_value sugar as _evalOnKey (KeyEvent path). Keeps the
      // synthetic-Enter path in lockstep with real key events.
      final remaining = <dynamic>[];
      bool didSet = false;
      for (final cmd in result) {
        if (cmd is Map && cmd['cmd'] == 'set_value') {
          final text = _canonicalizeForBuffer(cmd['value']);
          _controller.text = text;
          _controller.selection = TextSelection.collapsed(offset: text.length);
          _commit('command');
          didSet = true;
        } else {
          remaining.add(cmd);
        }
      }
      if (remaining.isEmpty) return didSet;

      final target = InputCommandTarget(
        controller: _controller,
        focusNode: _focusNode,
        onCommit: (reason) {
          _commit(reason);
        },
        onCancel: _cancel,
        onBanner: _fireBanner,
        onBeep: _publishBeepToDom,
      );
      return didSet || InputCommandExecutor.execute(remaining, target);
    } catch (e) {
      print('[EInputText] on_key eval error (name path): $e');
      return false;
    }
  }

  bool _evalOnKey(KeyEvent event) {
    final proj = _onKeyProjection;
    if (proj == null) {
      _einputDiag('_evalOnKey: proj=null, returning false');
      return false;
    }
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String?;
    if (evalExpr == null || evalExpr.isEmpty) {
      _einputDiag('_evalOnKey: evalExpr empty, returning false');
      return false;
    }

    final keyName = _logicalKeyName(event);
    final mods = _buildModifiers();
    _einputDiag('_evalOnKey: keyName="$keyName" mods=$mods '
        'mpReady=${MicroPythonService.isReady} '
        'execBody.len=${execBody.length} evalExpr.len=${evalExpr.length}');

    final selection = _controller.selection;
    final selectionState = !selection.isValid
        ? 'none'
        : selection.isCollapsed
            ? 'none'
            : (selection.start == 0 && selection.end == _controller.text.length)
                ? 'all'
                : 'partial';

    final ctx = <String, dynamic>{
      'key': keyName,
      'modifiers': mods,
      'value': _typedHostValue(),
      'buffer': _controller.text,
      'cursor': selection.isValid ? selection.baseOffset : 0,
      'selection': selectionState,
      'selection_start': selection.isValid ? selection.start : 0,
      'selection_end': selection.isValid ? selection.end : 0,
    };

    try {
      final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
      _einputDiag('_evalOnKey result type=${result.runtimeType} '
          'value=${result.toString().substring(0, result.toString().length.clamp(0, 200))}');
      if (result == null) return false;
      if (result is! List) return false;
      if (result.isEmpty) return false;

      // `the.field.set(value)` lowers to a `set_value` command. For text
      // fields, this is sugar for replace+commit: stuff the controller
      // with str(value), fire submit. Strip handled set_value cmds and
      // pass remaining commands through to the shared executor.
      final remaining = <dynamic>[];
      bool didSet = false;
      for (final cmd in result) {
        if (cmd is Map && cmd['cmd'] == 'set_value') {
          final text = _canonicalizeForBuffer(cmd['value']);
          _controller.text = text;
          _controller.selection = TextSelection.collapsed(offset: text.length);
          _commit('command');
          didSet = true;
        } else {
          remaining.add(cmd);
        }
      }
      if (remaining.isEmpty) return didSet;

      final target = InputCommandTarget(
        controller: _controller,
        focusNode: _focusNode,
        onCommit: (reason) {
          // The `commit` command fires submit and STAYS focused. If a user
          // wants to leave the field after commit, they chain it with
          // `move_to_next` / `move_to_prev`. Unfocusing here would break
          // chains like [commit, select_all] (the select_all would silently
          // do nothing on an unfocused field).
          _commit(reason);
        },
        onCancel: _cancel,
        onBanner: _fireBanner,
        onBeep: _publishBeepToDom,
      );
      final executed = didSet || InputCommandExecutor.execute(remaining, target);
      _einputDiag('_evalOnKey: InputCommandExecutor.execute returned $executed');
      return executed;
    } catch (e, st) {
      _einputDiag('_evalOnKey EXCEPTION: $e\n$st');
      print('[EInputText] on_key eval error: $e');
      return false;
    }
  }

  /// Build the modifiers list passed to user `on_key` code.
  ///
  /// Reports four literal modifiers (`ctrl`, `meta`, `shift`, `alt`) plus a
  /// single derived alias (`cmd`) that resolves to the platform-conventional
  /// shortcut modifier: `meta` on macOS, `ctrl` everywhere else. User code
  /// should reach for `"cmd" in modifiers` for cross-platform shortcuts;
  /// the literal modifiers are available for platform-specific cases.
  static List<String> _buildModifiers() {
    final mods = <String>[];
    final hasCtrl = HardwareKeyboard.instance.isControlPressed;
    final hasMeta = HardwareKeyboard.instance.isMetaPressed;
    if (hasCtrl) mods.add('ctrl');
    if (hasMeta) mods.add('meta');
    if (HardwareKeyboard.instance.isShiftPressed) mods.add('shift');
    if (HardwareKeyboard.instance.isAltPressed) mods.add('alt');
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    if ((isMac && hasMeta) || (!isMac && hasCtrl)) mods.add('cmd');
    return mods;
  }

  /// Map a logical key event to a name compatible with the ETab convention.
  ///
  /// Convention: structural keys get a stable PascalCase / Snake_Case name
  /// (Enter, Tab, Arrow_Up, ...). Letter keys get the lowercase form
  /// regardless of Shift / Cmd state — modifiers are reported separately
  /// in the `modifiers` list. Otherwise on macOS Cmd+K would arrive with
  /// `event.character == null` and we'd fall back to the uppercase
  /// `keyLabel == "K"`, breaking user code that checks `key == "k"`.
  String _logicalKeyName(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.escape) return 'Escape';
    if (key == LogicalKeyboardKey.f2) return 'F2';
    if (key == LogicalKeyboardKey.delete) return 'Delete';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.arrowUp) return 'Arrow_Up';
    if (key == LogicalKeyboardKey.arrowDown) return 'Arrow_Down';
    if (key == LogicalKeyboardKey.arrowLeft) return 'Arrow_Left';
    if (key == LogicalKeyboardKey.arrowRight) return 'Arrow_Right';
    if (key == LogicalKeyboardKey.home) return 'Home';
    if (key == LogicalKeyboardKey.end) return 'End';
    if (key == LogicalKeyboardKey.pageUp) return 'Page_Up';
    if (key == LogicalKeyboardKey.pageDown) return 'Page_Down';
    // Letter keys: always lowercase. keyLabel is "A".."Z" for letters.
    final label = key.keyLabel;
    if (label.length == 1 && label.codeUnitAt(0) >= 0x41 && label.codeUnitAt(0) <= 0x5A) {
      return label.toLowerCase();
    }
    // Printable chars (digits, punctuation) — use the event character if present.
    final char = event.character;
    if (char != null && char.isNotEmpty) return char;
    return label;
  }

  // ─── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final label = widget.control.getString("label");
    final hint = widget.control.getString("hint_text");
    final readOnly = widget.control.getBool("read_only", false) ?? false;
    final multiline = widget.control.getBool("multiline", false) ?? false;
    final minLines = widget.control.getInt("min_lines", 1) ?? 1;
    final maxLines = widget.control.getInt("max_lines", 1) ?? 1;

    final textColor = _parseColor(widget.control.getString("text_color"));
    final bgColor = _parseColor(widget.control.getString("bg_color"));
    final borderColor = _parseColor(widget.control.getString("border_color"));
    final focusedBorderColor = _parseColor(widget.control.getString("focused_border_color"));
    final borderWidth = widget.control.getDouble("border_width", 2.0) ?? 2.0;
    final fontSize = widget.control.getDouble("font_size", 14.0) ?? 14.0;
    final fontFamily = widget.control.getString("font_family");
    final fontWeightStr = widget.control.getString("font_weight");
    final italic = widget.control.getBool("italic", false) ?? false;
    final underline = widget.control.getBool("underline", false) ?? false;

    final textStyle = TextStyle(
      color: textColor,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontWeight: _parseFontWeight(fontWeightStr),
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
    );

    // Key interception:
    //   - Arrow / letter / Tab / Escape go through _focusNode.onKeyEvent
    //     (set in initState). The FocusNode runs FIRST in Flutter's key
    //     dispatch, before EditableText consumes Arrow keys.
    //   - Enter is special: it's routed via the platform input layer on
    //     desktop (TextInputClient.performAction → onEditingComplete) but
    //     via the focus chain on web. We wire `onEditingComplete` to call
    //     the same `_handleEnter` method that the focus path calls; a
    //     per-frame guard prevents double-fire.
    //   - We provide `onEditingComplete` (overriding Flutter's default
    //     unfocus on done) so Enter doesn't blow our focus away on desktop.
    //   - `onSubmitted` is also set, but only as a redundant safety net.
    // Tab-nav metadata mirrored from host EScalar Property. Wrap the
    // TextField in EpyxFocusable in proxy mode so the existing
    // _focusNode is the actual focus target; the wrapper contributes
    // only registration with TabGroupController. The TextField's own
    // focused border (focusedBorderColor on the InputDecoration)
    // doubles as visual feedback — drawFocusBorder=false here.
    final tabGroup = widget.control.getInt("tab_group");
    final tabOrder = widget.control.getInt("tab_order");
    final tabSkip = widget.control.getBool("tab_skip", false) ?? false;
    final tabName = widget.control.getString("tab_name", "") ?? "";
    final textField = TextField(
        controller: _controller,
        focusNode: _focusNode,
        readOnly: readOnly,
        style: textStyle,
        minLines: multiline ? minLines : 1,
        maxLines: multiline ? maxLines : 1,
        onEditingComplete: () {
          // Desktop path: Enter on the platform input layer fires this.
          // The default behavior (had we not provided this) would be to
          // unfocus. We override with our own handler.
          final shiftDown = HardwareKeyboard.instance.isShiftPressed;
          _handleEnter(shiftDown: shiftDown);
        },
        onSubmitted: (_) {
          // Redundant safety net; in practice onEditingComplete fires first.
          final shiftDown = HardwareKeyboard.instance.isShiftPressed;
          _handleEnter(shiftDown: shiftDown);
        },
        onChanged: _onChange,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: bgColor != null,
          fillColor: bgColor,
          border: OutlineInputBorder(
            borderSide: BorderSide(
              color: borderColor ?? Colors.white,
              width: borderWidth,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: borderColor ?? Colors.white,
              width: borderWidth,
            ),
          ),
          // Focus is now shown by EpyxFocusable's blue glow — keep the
          // focused border identical to the resting border so there's
          // no competing 2px line on focus.
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(
              color: borderColor ?? Colors.white,
              width: borderWidth,
            ),
          ),
        ),
      );
    return EpyxFocusable(
      name: tabName.isEmpty ? "einput:${widget.control.id}" : tabName,
      group: tabGroup,
      order: tabOrder,
      skip: tabSkip,
      isProxy: true,
      proxyToFocusNode: _focusNode,
      drawFocusBorder: true,
      onFocusChange: (focused) {
        // Already wired via _focusNode.addListener(_onFocusChanged) →
        // existing focus_change event; EpyxFocusable's callback is a
        // duplicate here, but harmless (Python receives two events on
        // focus change). Keep for symmetry with display-only widgets.
      },
      child: textField,
    );
  }

  static Color? _parseColor(String? value) {
    if (value == null || value.isEmpty) return null;
    var v = value.trim();
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 6) v = 'FF$v';
    if (v.length != 8) return null;
    final n = int.tryParse(v, radix: 16);
    if (n == null) return null;
    return Color(n);
  }

  static FontWeight? _parseFontWeight(String? name) {
    if (name == null || name.isEmpty) return null;
    switch (name.toLowerCase()) {
      case 'thin':
      case 'w100':
        return FontWeight.w100;
      case 'extralight':
      case 'w200':
        return FontWeight.w200;
      case 'light':
      case 'w300':
        return FontWeight.w300;
      case 'regular':
      case 'normal':
      case 'w400':
        return FontWeight.w400;
      case 'medium':
      case 'w500':
        return FontWeight.w500;
      case 'semibold':
      case 'w600':
        return FontWeight.w600;
      case 'bold':
      case 'w700':
        return FontWeight.w700;
      case 'extrabold':
      case 'w800':
        return FontWeight.w800;
      case 'black':
      case 'w900':
        return FontWeight.w900;
      default:
        return null;
    }
  }
}
