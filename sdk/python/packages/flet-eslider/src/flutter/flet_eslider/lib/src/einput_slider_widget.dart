/// EInputSlider — slider with focus, keyboard step, type-to-replace, and
/// α-snippet keystroke scripting.
///
/// Architectural twin of flet-einput's EInputTextWidget. Both widgets
/// implement the same model: a built-in baseline (arrow keys → step,
/// Enter/Esc, printable chars enter type-to-replace mode); on top of
/// that, the α `code` on the hosting EScalar can include
/// `if the.key == ...:` blocks. The static analyzer extracts those
/// blocks into a render-plane projection (registry key 'on_key' —
/// implementation detail; users write inline if-statements, not a
/// `def on_key(...)` function). On every keystroke we eval the
/// projection; if it returns a command list, the commands are
/// dispatched through the shared InputCommandExecutor
/// (replace/insert/commit/cancel/banner/beep/...).
import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flet_einput/flet_einput.dart'
    show InputCommandExecutor, InputCommandTarget;
import 'package:flet_micropython/flet_micropython.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class EInputSliderWidget extends StatefulWidget {
  final Control control;

  const EInputSliderWidget({super.key, required this.control});

  @override
  State<EInputSliderWidget> createState() => _EInputSliderWidgetState();
}

class _EInputSliderWidgetState extends State<EInputSliderWidget> {
  late final FocusNode _focusNode;
  late final TextEditingController _typingController;
  late final FocusNode _typingFocusNode;

  /// True while the user is actively typing a replacement value.
  /// During typing the slider's actual value is NOT mutated — only the
  /// transient text buffer is — so there's no "saved value to restore"
  /// on cancel; cancel simply clears the buffer.
  bool _typing = false;

  /// True when this slider is the focus target (drives the focus border).
  bool _hasFocus = false;

  /// Cached on_key projection from the render plane.
  Map<String, dynamic>? _onKeyProjection;
  VoidCallback? _renderPlaneUnsubscribe;
  String _lastHostId = '';

  @override
  void initState() {
    super.initState();
    // onKeyEvent is wired on the parent Focus widget below in build(),
    // not on the FocusNode itself, to avoid double-firing when the
    // node sits inside a Focus widget that also has an onKeyEvent.
    _focusNode = FocusNode(
      debugLabel: 'eslider_${widget.control.id}',
    );
    _focusNode.addListener(_onFocusChanged);
    _typingController = TextEditingController();
    _typingFocusNode = FocusNode(
      debugLabel: 'eslider_typing_${widget.control.id}',
    );
    _subscribeOnKey();
  }

  @override
  void didUpdateWidget(EInputSliderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hostId = widget.control.getString("host_control_id") ?? '';
    if (hostId != _lastHostId) {
      _subscribeOnKey();
    }
  }

  void _subscribeOnKey() {
    _renderPlaneUnsubscribe?.call();
    _renderPlaneUnsubscribe = null;
    final hostId = widget.control.getString("host_control_id") ?? '';
    _lastHostId = hostId;
    if (hostId.isEmpty) {
      _onKeyProjection = null;
      return;
    }
    // Pull current projection (static API; the registry is a class-level
    // singleton on RenderPlaneControl).
    _onKeyProjection = RenderPlaneControl.getProjection(hostId, 'on_key');
    // Subscribe for future updates — re-fetch when notified.
    _renderPlaneUnsubscribe =
        RenderPlaneControl.addListener(hostId, () {
      _onKeyProjection =
          RenderPlaneControl.getProjection(hostId, 'on_key');
    });
  }

  @override
  void dispose() {
    _renderPlaneUnsubscribe?.call();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _typingFocusNode.dispose();
    _typingController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (hasFocus == _hasFocus) return;
    setState(() {
      _hasFocus = hasFocus;
      if (!hasFocus && _typing) {
        // Lost focus — drop any in-flight type-to-replace.
        _typing = false;
        _typingController.clear();
      }
    });
    print('[eslider id=${widget.control.id}] focus=$hasFocus');
    widget.control.triggerEventWithoutSubscribers(
        'focus_change', jsonEncode({'focused': hasFocus}));
  }

  // ── Slider numeric helpers ──────────────────────────────────────────────

  double _minValue() => (widget.control.getDouble("min_value", 0.0) ?? 0.0).toDouble();
  double _maxValue() => (widget.control.getDouble("max_value", 100.0) ?? 100.0).toDouble();
  int? _divisions() {
    final n = widget.control.getInt("divisions");
    return (n != null && n > 0) ? n : null;
  }
  double _currentValue() => (widget.control.getDouble("value", 0.0) ?? 0.0).toDouble();
  String _ptype() => widget.control.getString("ptype") ?? "float";

  double _stepSize() {
    final divs = _divisions();
    final span = (_maxValue() - _minValue()).abs();
    if (divs != null && divs > 0) return span / divs;
    // No divisions → 1% of range, with floor of 1.0 for int sliders.
    final s = span * 0.01;
    return _ptype() == "int" ? (s < 1.0 ? 1.0 : s.roundToDouble()) : s;
  }

  double _coerce(double v) {
    final mn = _minValue();
    final mx = _maxValue();
    if (v < mn) v = mn;
    if (v > mx) v = mx;
    if (_ptype() == "int") v = v.roundToDouble();
    return v;
  }

  String _formatValue(double v) {
    if (_ptype() == "int") return v.toInt().toString();
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  // ── Slider mutations ────────────────────────────────────────────────────

  void _setValue(double v, {String reason = "command"}) {
    final coerced = _coerce(v);
    if ((coerced - _currentValue()).abs() < 1e-12) return;
    // python: true so the property tree on the Python side learns the
    // new value. Without this, escalar.on_slider_change reads
    // self.control.slider.value (= the Python-side EInputSlider.value)
    // and gets the OLD value, so o.amplitude.value never updates.
    widget.control.updateProperties(
      {'value': coerced},
      python: true,
      notify: true,
    );
    widget.control.triggerEventWithoutSubscribers(
        'value_change', jsonEncode({'value': coerced}));
    widget.control.triggerEventWithoutSubscribers(
        'submit', jsonEncode({'value': coerced, 'reason': reason}));
  }

  void _step(double delta) {
    _setValue(_currentValue() + delta, reason: "command");
  }

  // ── Type-to-replace ─────────────────────────────────────────────────────
  //
  // When the slider has focus and the user types a digit, sign, or dot,
  // we switch the value-display label into a TextField that captures
  // the typed buffer. Enter commits, Esc cancels and restores the
  // saved value.

  void _enterTypingMode(String initial) {
    if (_typing) return;
    setState(() {
      _typing = true;
      _typingController.text = initial;
      _typingController.selection = TextSelection.collapsed(
          offset: _typingController.text.length);
    });
    // Defer focus until after the TextField has built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _typingFocusNode.requestFocus();
    });
  }

  void _commitTypedBuffer({String reason = "enter"}) {
    if (!_typing) return;
    final text = _typingController.text.trim();
    setState(() {
      _typing = false;
      _typingController.clear();
    });
    if (text.isEmpty) return;
    final parsed = double.tryParse(text);
    if (parsed == null) return;
    _setValue(parsed, reason: reason);
    // Return focus to the slider so further arrow keys work.
    _focusNode.requestFocus();
  }

  void _cancelTypedBuffer() {
    if (!_typing) return;
    setState(() {
      _typing = false;
      _typingController.clear();
    });
    widget.control.triggerEventWithoutSubscribers('cancel', '{}');
    _focusNode.requestFocus();
  }

  // ── Key handling ────────────────────────────────────────────────────────

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    // First: try the α `if the.key == ...:` projection if any.
    final hostId = widget.control.getString("host_control_id") ?? '';
    print('[eslider id=${widget.control.id}] key=${key.debugName} '
        'hostId=$hostId proj=${_onKeyProjection != null} '
        'mpReady=${MicroPythonService.isReady}');
    // Late-bind the projection in case it got registered between
    // initState (when host_control_id might've been empty) and now.
    if (_onKeyProjection == null && hostId.isNotEmpty) {
      _onKeyProjection =
          RenderPlaneControl.getProjection(hostId, 'on_key');
    }
    if (_onKeyProjection != null && MicroPythonService.isReady) {
      final handled = _evalOnKey(event);
      print('[eslider id=${widget.control.id}] '
          'projection result handled=$handled');
      if (handled) return KeyEventResult.handled;
    }

    // Baseline behaviors below — used when the projection didn't handle
    // the key (or no projection is set).

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowDown) {
      _step(-_stepSize() * (shift ? 10 : 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowUp) {
      _step(_stepSize() * (shift ? 10 : 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _setValue(_minValue(), reason: "command");
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _setValue(_maxValue(), reason: "command");
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_typing) {
        _cancelTypedBuffer();
      } else {
        _focusNode.unfocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_typing) {
        _commitTypedBuffer(reason: "enter");
      } else {
        _focusNode.nextFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      // Commit any active type-to-replace buffer before the framework
      // traverses focus away. Then return ignored so Flutter's default
      // Tab handler walks the focus tree — calling _focusNode.nextFocus()
      // ourselves AND returning handled bypasses Flutter's traversal,
      // which left focus in an unset state when ExcludeFocus removed
      // Slider's internal node from the tree (only target was our outer
      // Focus, manual nextFocus didn't find a sibling cleanly).
      if (_typing) _commitTypedBuffer(reason: "tab");
      return KeyEventResult.ignored;
    }
    // Type-to-replace trigger: digit, '+', '-', '.'  (case sensitive,
    // no shifted variants).
    final ch = event.character;
    if (ch != null && ch.isNotEmpty) {
      final c = ch.codeUnitAt(0);
      final isDigit = (c >= 0x30 && c <= 0x39);
      final isSign = (ch == '+' || ch == '-');
      final isDot = (ch == '.');
      if (isDigit || isSign || isDot) {
        if (_typing) {
          // Append to existing buffer.
          _typingController.text += ch;
          _typingController.selection = TextSelection.collapsed(
              offset: _typingController.text.length);
        } else {
          _enterTypingMode(ch);
        }
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.backspace && _typing) {
      final t = _typingController.text;
      if (t.isNotEmpty) {
        _typingController.text = t.substring(0, t.length - 1);
        _typingController.selection = TextSelection.collapsed(
            offset: _typingController.text.length);
      } else {
        _cancelTypedBuffer();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _evalOnKey(KeyEvent event) {
    return _tryRunOnKeyProjection(_logicalKeyName(event));
  }

  /// Run the on_key projection for the given keyName.
  ///
  /// Shared between the slider's outer Focus.onKeyEvent (real KeyEvent
  /// path) and the inner type-to-replace TextField's onSubmitted (Enter
  /// inside an active typed buffer). Without this shared path, the
  /// TextField's onSubmitted would call `_commitTypedBuffer` directly,
  /// bypassing user `if the.key == the.keys.enter:` handlers on
  /// platforms where onSubmitted intercepts before the parent Focus
  /// sees the KeyEvent (notably macOS desktop). Same fix shape as
  /// epyx_grid's _tryRunOnKeyProjection.
  bool _tryRunOnKeyProjection(String keyName) {
    final proj = _onKeyProjection;
    if (proj == null) return false;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String?;
    if (evalExpr == null || evalExpr.isEmpty) return false;
    final mods = _buildModifiers();
    final ctx = <String, dynamic>{
      'key': keyName,
      'modifiers': mods,
      'value': _currentValue(),
      // Symmetry with EInputText: `buffer` is the live text buffer when
      // the slider is in type-to-replace mode, empty otherwise. Slider's
      // `value` is always already typed so callers usually only read
      // value, but buffer is here for snippets that want to inspect
      // mid-edit state during type-to-replace.
      'buffer': _typing ? _typingController.text : '',
      'cursor': 0,
      'selection': 'none',
      'selection_start': 0,
      'selection_end': 0,
    };
    try {
      final result = MicroPythonService.execEval(execBody, evalExpr, ctx);
      if (result == null) return false;
      if (result is! List) return false;
      if (result.isEmpty) return false;

      // Slider-targeted set_value commands are handled inline here —
      // the shared text-field executor doesn't know about slider state.
      // Any non-set_value commands fall through to InputCommandExecutor.
      final remaining = <dynamic>[];
      bool didSet = false;
      for (final cmd in result) {
        if (cmd is Map && cmd['cmd'] == 'set_value') {
          final raw = cmd['value'];
          double? v;
          if (raw is num) v = raw.toDouble();
          else if (raw is String) v = double.tryParse(raw);
          if (v != null) {
            _setValue(v, reason: "command");
            didSet = true;
          }
        } else {
          remaining.add(cmd);
        }
      }
      if (remaining.isEmpty) return didSet;
      final target = InputCommandTarget(
        controller: _typingController,
        focusNode: _focusNode,
        onCommit: (reason) {
          if (_typing) {
            _commitTypedBuffer(reason: reason);
          } else {
            // commit-without-typing: re-emit current value.
            final v = _currentValue();
            widget.control.triggerEventWithoutSubscribers(
                'submit', jsonEncode({'value': v, 'reason': reason}));
          }
        },
        onCancel: () {
          if (_typing) {
            _cancelTypedBuffer();
          }
        },
        onBanner: (msg, level) {
          widget.control.triggerEventWithoutSubscribers(
              'banner', jsonEncode({'message': msg, 'level': level}));
        },
        onBeep: () {
          // No DOM mirror needed here — the banner-side flet-einput JS
          // bridge already publishes beep counts. Sliders share that.
        },
      );
      final ranOthers = InputCommandExecutor.execute(remaining, target);
      return didSet || ranOthers;
    } catch (_) {
      return false;
    }
  }

  String _logicalKeyName(KeyEvent event) {
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp) return "Arrow_Up";
    if (k == LogicalKeyboardKey.arrowDown) return "Arrow_Down";
    if (k == LogicalKeyboardKey.arrowLeft) return "Arrow_Left";
    if (k == LogicalKeyboardKey.arrowRight) return "Arrow_Right";
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) return "Enter";
    if (k == LogicalKeyboardKey.escape) return "Escape";
    if (k == LogicalKeyboardKey.tab) return "Tab";
    if (k == LogicalKeyboardKey.backspace) return "Backspace";
    if (k == LogicalKeyboardKey.delete) return "Delete";
    if (k == LogicalKeyboardKey.home) return "Home";
    if (k == LogicalKeyboardKey.end) return "End";
    if (k == LogicalKeyboardKey.f1) return "F1";
    if (k == LogicalKeyboardKey.f2) return "F2";
    if (k == LogicalKeyboardKey.space) return "Space";
    final ch = event.character;
    if (ch != null && ch.isNotEmpty) {
      return ch.toLowerCase();
    }
    return k.debugName ?? '';
  }

  List<String> _buildModifiers() {
    final mods = <String>[];
    final hk = HardwareKeyboard.instance;
    if (hk.isShiftPressed) mods.add('shift');
    if (hk.isControlPressed) mods.add('ctrl');
    if (hk.isMetaPressed) mods.add('meta');
    if (hk.isAltPressed) mods.add('alt');
    final isMac = !kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS);
    if ((isMac && hk.isMetaPressed) || (!isMac && hk.isControlPressed)) {
      mods.add('cmd');
    }
    return mods;
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final value = _currentValue();
    final min = _minValue();
    final max = _maxValue();
    final divisions = _divisions();
    final activeColor = _parseColor(widget.control.getString("active_color"))
        ?? Theme.of(context).colorScheme.primary;
    final inactiveColor = _parseColor(widget.control.getString("inactive_color"))
        ?? Colors.white24;
    final textColor = _parseColor(widget.control.getString("text_color"))
        ?? Theme.of(context).textTheme.bodyMedium?.color;
    final fontSize = (widget.control.getDouble("font_size", 14.0) ?? 14.0).toDouble();
    final focusColor = _parseColor(widget.control.getString("focus_border_color"))
        ?? const Color(0xFF0066FF);
    final focusWidth = (widget.control.getDouble("focus_border_width", 2.0) ?? 2.0).toDouble();
    final display = widget.control.getString("display") ?? '';
    final label = widget.control.getString("label") ?? '';

    // We deliberately do NOT pass our FocusNode to Slider here.
    // When Slider has a focusNode, its internal Focus wrapper installs
    // its own onKeyEvent that fires BEFORE ours, intercepting digits
    // and other keys we want to handle. Slider also competes for focus
    // with the surrounding Focus widget, leading to flaky tap-to-focus
    // behavior (the amplitude/frequency divergence). With no focusNode
    // passed, Slider's keyboard step disables — but we re-implement it
    // ourselves in _onKeyEvent (and add Shift×10 + Home/End on top), so
    // the user-visible behavior is the same.
    //
    // ExcludeFocus around the Slider drops its internal default
    // FocusNode out of the focus traversal tree. Without this, Tab
    // requires TWO presses to advance off a slider: the first press
    // moves focus from Slider's internal node back to our outer Focus
    // (or wherever default traversal sends it), the second press
    // actually advances. With ExcludeFocus, Slider's internal node is
    // unreachable by Tab — only our outer Focus is in the traversal
    // tree per slider — so a single Tab advances cleanly.
    final slider = ExcludeFocus(
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: activeColor,
          inactiveTrackColor: inactiveColor,
          thumbColor: activeColor,
        ),
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: (v) {
            // Drag updates — make sure our FocusNode owns focus so
            // subsequent keys come to us, not to Slider's internal node.
            if (!_focusNode.hasFocus) _focusNode.requestFocus();
            _setValue(v, reason: "drag");
          },
        ),
      ),
    );

    Widget bottomLabel;
    if (_typing) {
      bottomLabel = TextField(
        controller: _typingController,
        focusNode: _typingFocusNode,
        autofocus: true,
        style: TextStyle(color: textColor, fontSize: fontSize),
        textAlign: TextAlign.center,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 2),
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) {
          // Try the on_key projection first so user
          // `if the.key == the.keys.enter:` handlers fire even when
          // Enter is pressed inside the type-to-replace TextField (the
          // TextField captures Enter via onSubmitted on platforms that
          // route through TextInputAction, bypassing the parent Focus's
          // onKeyEvent — notably macOS desktop). If the projection
          // didn't return commands, fall back to the baseline
          // commit-typed-buffer.
          if (_tryRunOnKeyProjection('Enter')) return;
          _commitTypedBuffer(reason: "enter");
        },
        keyboardType: const TextInputType.numberWithOptions(
            signed: true, decimal: true),
      );
    } else {
      final shown = display.isNotEmpty ? display : _formatValue(value);
      // Prefix a ▶ marker on the value label when this slider has focus
      // — duplicate signal in addition to the border + glow + bg tint.
      // Especially useful in the terminal/web stack where shadows can
      // be subtle. Marker color matches the focus border so it's
      // unmistakably an "I am focused" cue.
      bottomLabel = Text(
        shown,
        style: TextStyle(color: textColor, fontSize: fontSize),
        textAlign: TextAlign.center,
      );
    }

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              label,
              style: TextStyle(color: textColor, fontSize: fontSize - 2),
              textAlign: TextAlign.center,
            ),
          ),
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: bottomLabel,
        ),
        const Divider(thickness: 1, color: Colors.white24),
      ],
    );

    // Outer structure:
    //   Focus(focusNode, onKeyEvent)         ← owns keyboard input
    //     Listener(onPointerDown → focus)    ← any tap focuses us first
    //       AnimatedContainer(border/glow)   ← visible focus state
    //         Column(slider, label, …)
    //
    // The Listener sees pointer events without consuming them; Slider
    // also receives them and handles drag correctly. The Focus widget
    // installs onKeyEvent at our node, which fires BEFORE any Slider-
    // internal handler (no Slider focusNode → no internal handler).
    // Tab-nav participation — wrap the existing Focus(...) in
    // EpyxFocusable's proxy mode so the existing _focusNode stays the
    // real focus target and we just contribute registration with the
    // TabGroupController. The slider's own border-on-focus stays as
    // the visual feedback (drawFocusBorder=false).
    final tabGroup = widget.control.getInt("tab_group");
    final tabOrder = widget.control.getInt("tab_order");
    final tabSkip = widget.control.getBool("tab_skip", false) ?? false;
    final tabName = widget.control.getString("tab_name", "") ?? "";
    final inner = Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          padding: EdgeInsets.all(focusWidth),
          decoration: BoxDecoration(
            border: Border.all(
              color: _hasFocus ? focusColor : Colors.transparent,
              width: focusWidth,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: body,
        ),
      ),
    );
    return EpyxFocusable(
      name: tabName.isEmpty ? "eslider:${widget.control.id}" : tabName,
      group: tabGroup,
      order: tabOrder,
      skip: tabSkip,
      isProxy: true,
      proxyToFocusNode: _focusNode,
      drawFocusBorder: false,
      onFocusChange: (_) {},
      child: inner,
    );
  }
}

// Hex `#RRGGBB` / `#RRGGBBAA` / `#RGB` parser. Returns null on bad input.
Color? _parseColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var s = hex;
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 3) {
    s = s.split('').map((c) => '$c$c').join();
  }
  if (s.length == 6) s = 'FF$s';
  if (s.length == 8) {
    final v = int.tryParse(s, radix: 16);
    if (v == null) return null;
    return Color(v);
  }
  return null;
}
