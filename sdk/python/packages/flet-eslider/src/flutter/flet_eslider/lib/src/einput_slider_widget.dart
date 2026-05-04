/// EInputSlider — slider with focus, keyboard step, type-to-replace, and
/// `def on_key(key, modifiers, value, ...)` render-plane projection eval.
///
/// Architectural twin of flet-einput's EInputTextWidget. Both widgets
/// implement the same on_key model: a baseline (arrow keys, Enter, Esc,
/// printable chars enter type-to-replace mode); on top of that, an α
/// `def on_key` snippet projected to the render plane runs first and
/// can intercept any key — its returned command list is dispatched via
/// the shared InputCommandExecutor (replace/insert/commit/cancel/...).
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
    _focusNode = FocusNode(
      debugLabel: 'eslider_${widget.control.id}',
      onKeyEvent: _onKeyEvent,
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
    widget.control.updateProperties(
      {'value': coerced},
      python: false,
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

    // First: try the on_key projection if any.
    if (_onKeyProjection != null && MicroPythonService.isReady) {
      final handled = _evalOnKey(event);
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
      if (_typing) _commitTypedBuffer(reason: "tab");
      shift ? _focusNode.previousFocus() : _focusNode.nextFocus();
      return KeyEventResult.handled;
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
    final proj = _onKeyProjection;
    if (proj == null) return false;
    final execBody = proj['exec'] as String? ?? '';
    final evalExpr = proj['eval'] as String?;
    if (evalExpr == null || evalExpr.isEmpty) return false;
    final keyName = _logicalKeyName(event);
    final mods = _buildModifiers();
    final ctx = <String, dynamic>{
      'key': keyName,
      'modifiers': mods,
      'value': _currentValue(),
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
      return InputCommandExecutor.execute(result, target);
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

    final slider = SliderTheme(
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
          // Drag updates — request focus so subsequent keys land here.
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
          _setValue(v, reason: "drag");
        },
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
        onSubmitted: (_) => _commitTypedBuffer(reason: "enter"),
        keyboardType: const TextInputType.numberWithOptions(
            signed: true, decimal: true),
      );
    } else {
      final shown = display.isNotEmpty ? display : _formatValue(value);
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

    return Focus(
      focusNode: _focusNode,
      child: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        behavior: HitTestBehavior.translucent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          padding: EdgeInsets.all(focusWidth),
          decoration: BoxDecoration(
            border: Border.all(
              color: _hasFocus ? focusColor : Colors.transparent,
              width: focusWidth,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: body,
        ),
      ),
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
