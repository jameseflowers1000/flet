// SpyTutorWidget — full-screen overlay widget for YAML-driven tutor lessons.
//
// Phase 2: Spy rendered as a placeholder snake emoji pane.
// Phase 3: Replace _buildSpyPane with RiveAnimation.asset('assets/spy.riv')
//          and wire state machine triggers to step character_animation field.

import 'dart:async';
import 'dart:convert';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:yaml/yaml.dart';

class SpyTutorWidget extends StatefulWidget {
  final Control control;

  const SpyTutorWidget({super.key, required this.control});

  @override
  State<SpyTutorWidget> createState() => _SpyTutorWidgetState();
}

class _SpyTutorWidgetState extends State<SpyTutorWidget> {
  List<Map<String, dynamic>> _steps = [];
  String _loadedYaml = "";
  int _currentStepIndex = -1;

  bool _spyVisible = true;
  bool _showHighlight = false;
  Rect? _highlightRect;

  // Python event tracking — last raw event JSON string (dedupe key)
  String _lastEvent = "";
  String? _waitingForEvent;
  String? _waitingForWidgetKey;
  String? _waitingForFilenameContains;

  Timer? _stepTimer;

  @override
  void initState() {
    super.initState();
    widget.control.addListener(_onControlChanged);
    _syncFromControl();
  }

  @override
  void dispose() {
    widget.control.removeListener(_onControlChanged);
    _stepTimer?.cancel();
    super.dispose();
  }

  void _onControlChanged() {
    _syncFromControl();
  }

  void _syncFromControl() {
    final active = widget.control.getBool("active", false) ?? false;
    if (!active) {
      if (_currentStepIndex != -1) {
        _stepTimer?.cancel();
        setState(() {
          _currentStepIndex = -1;
          _showHighlight = false;
        });
      }
      return;
    }

    // Load new lesson YAML when it changes
    final yaml = widget.control.getString("lesson_yaml", "") ?? "";
    if (yaml.isNotEmpty && yaml != _loadedYaml) {
      _loadedYaml = yaml;
      _loadLesson(yaml);
      return; // _loadLesson calls setState and _executeStep
    }

    // Detect Python event — a SINGLE JSON string property so type+data arrive
    // atomically (separate props raced: the int nonce was consumed before the
    // strings landed). Format: {"n": nonce, "type": str, "data": obj}
    final evt = widget.control.getString("event", "") ?? "";
    if (evt.isNotEmpty && evt != _lastEvent) {
      _lastEvent = evt;
      try {
        final m = jsonDecode(evt) as Map;
        final eventType = m["type"]?.toString() ?? "";
        final eventData = jsonEncode(m["data"] ?? <String, dynamic>{});
        if (eventType.isNotEmpty) {
          _handlePythonEvent(eventType, eventData);
        }
      } catch (e) {
        print('SpyTutor: event parse error: $e (raw=$evt)');
      }
    }

    // Sync spy_visible from Python (Python can also force-hide)
    final spyVis = widget.control.getBool("spy_visible", true) ?? true;
    if (spyVis != _spyVisible) {
      setState(() => _spyVisible = spyVis);
    }

    // Sync highlight position
    final hx = widget.control.getDouble("highlight_x", 0) ?? 0;
    final hy = widget.control.getDouble("highlight_y", 0) ?? 0;
    final hw = widget.control.getDouble("highlight_w", 0) ?? 0;
    final hh = widget.control.getDouble("highlight_h", 0) ?? 0;
    if (hw > 0 && hh > 0) {
      final rect = Rect.fromLTWH(hx, hy, hw, hh);
      if (rect != _highlightRect) {
        setState(() {
          _highlightRect = rect;
          _showHighlight = true;
        });
      }
    } else if (_showHighlight) {
      setState(() {
        _showHighlight = false;
        _highlightRect = null;
      });
    }
  }

  // ── Lesson loading ────────────────────────────────────────────────────

  void _loadLesson(String yamlString) {
    try {
      final doc = loadYaml(yamlString);
      if (doc is! YamlMap) return;
      final sequence = doc['sequence'];
      if (sequence is! YamlList) return;

      final steps = <Map<String, dynamic>>[];
      for (final s in sequence) {
        if (s is YamlMap) steps.add(_convertYamlMap(s));
      }

      _stepTimer?.cancel();
      setState(() {
        _steps = steps;
        _currentStepIndex = steps.isNotEmpty ? 0 : -1;
        _showHighlight = false;
        _highlightRect = null;
        _waitingForEvent = null;
      });

      if (_currentStepIndex >= 0) {
        _executeStep(_steps[_currentStepIndex]);
      }
    } catch (e) {
      debugPrint('SpyTutor: YAML parse error: $e');
    }
  }

  Map<String, dynamic> _convertYamlMap(YamlMap yaml) {
    final out = <String, dynamic>{};
    for (final entry in yaml.entries) {
      final k = entry.key.toString();
      final v = entry.value;
      if (v is YamlMap) {
        out[k] = _convertYamlMap(v);
      } else if (v is YamlList) {
        out[k] = v
            .map<dynamic>((e) => e is YamlMap ? _convertYamlMap(e) : e)
            .toList();
      } else {
        out[k] = v;
      }
    }
    return out;
  }

  // ── Step execution ────────────────────────────────────────────────────

  void _executeStep(Map<String, dynamic> step) {
    _stepTimer?.cancel();
    _waitingForEvent = null;
    _waitingForWidgetKey = null;
    _waitingForFilenameContains = null;

    final type = step['type'] as String? ?? 'narrative';

    switch (type) {
      case 'task':
        // Use `is Map` (not a typed cast) — YAML-derived nested maps are
        // Map<dynamic,dynamic>, so `as Map<String,dynamic>` would throw and
        // leave _waitingForEvent null (the task would never advance).
        final waitFor = step['wait_for'];
        if (waitFor is Map) {
          _waitingForEvent = waitFor['event']?.toString();
          _waitingForWidgetKey = waitFor['widget_key']?.toString();
          _waitingForFilenameContains =
              waitFor['filename_contains']?.toString();
          final t = waitFor['timeout'];
          final timeout = (t is num) ? t.toInt() : 30;
          _stepTimer = Timer(Duration(seconds: timeout), () {
            // Phase 3: trigger hint animation here
            debugPrint('SpyTutor: step ${step["id"]} timed out');
          });
        }

      case 'narrative':
      case 'explanation':
        final durRaw = step['duration'];
        if (durRaw != null) {
          final ms = ((durRaw as num).toDouble() * 1000).toInt();
          _stepTimer = Timer(Duration(milliseconds: ms), () {
            if (mounted) _advanceToNext(step);
          });
        }

      case 'splash':
      case 'endgame':
        // User interaction drives advancement — no auto-advance
        break;
    }
  }

  void _advanceToNext(Map<String, dynamic> fromStep) {
    final nextId = fromStep['next_step'] as String?;
    if (nextId == null) return;
    final idx = _steps.indexWhere((s) => s['id'] == nextId);
    if (idx == -1) return;

    setState(() {
      _currentStepIndex = idx;
      _showHighlight = false;
      _highlightRect = null;
    });
    _executeStep(_steps[idx]);
  }

  void _handleOptionTap(Map<String, dynamic> option) {
    final action = option['action'] as String? ?? '';
    switch (action) {
      case 'enable_spy':
        setState(() => _spyVisible = true);
      case 'disable_spy':
        setState(() => _spyVisible = false);
    }

    final nextId = option['next_step'] as String?;
    if (nextId != null) {
      final idx = _steps.indexWhere((s) => s['id'] == nextId);
      if (idx != -1) {
        setState(() {
          _currentStepIndex = idx;
          _showHighlight = false;
        });
        _executeStep(_steps[idx]);
      }
    }
  }

  void _handlePythonEvent(String eventType, String eventDataJson) {
    if (_waitingForEvent == null || _waitingForEvent != eventType) return;

    Map<String, dynamic> data = {};
    try {
      data = Map<String, dynamic>.from(jsonDecode(eventDataJson) as Map);
    } catch (_) {}

    if (eventType == 'widget_clicked' && _waitingForWidgetKey != null) {
      if (data['widget_key'] != _waitingForWidgetKey) return;
    }
    if (eventType == 'file_selected' && _waitingForFilenameContains != null) {
      final filename = data['filename'] as String? ?? '';
      if (!filename.contains(_waitingForFilenameContains!)) return;
    }

    if (_currentStepIndex >= 0 && _currentStepIndex < _steps.length) {
      _advanceToNext(_steps[_currentStepIndex]);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final active = widget.control.getBool("active", false) ?? false;
    if (!active || _currentStepIndex < 0 || _steps.isEmpty) {
      return const SizedBox.shrink();
    }

    final step = _steps[_currentStepIndex];
    final size = MediaQuery.of(context).size;

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          if (_showHighlight && _highlightRect != null) _buildHighlightOverlay(),
          if (_spyVisible) _buildSpyPane(),
          _buildPromptPanel(step),
        ],
      ),
    );
  }

  Widget _buildHighlightOverlay() {
    final rect = _highlightRect!.inflate(10);
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFFD700), width: 3),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFD700).withValues(alpha: 0.45),
                blurRadius: 18,
                spreadRadius: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSpyPane() {
    // Phase 2 placeholder — Phase 3 replaces with RiveAnimation.asset('assets/spy.riv')
    return Positioned(
      bottom: 20,
      left: 20,
      width: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              color: const Color(0xFF1A2E1A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2E7D32), width: 2),
            ),
            child: const Center(
              child: Text('🐍', style: TextStyle(fontSize: 60)),
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => setState(() => _spyVisible = false),
            child: const Text(
              'hide Spy',
              style: TextStyle(
                color: Color(0xFF888888),
                fontSize: 10,
                decoration: TextDecoration.underline,
                decorationColor: Color(0xFF888888),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptPanel(Map<String, dynamic> step) {
    final prompt = step['prompt'] as String? ?? '';
    final type = step['type'] as String? ?? 'narrative';
    final options = step['options'];
    final hasOptions = type == 'splash' && options is List && options.isNotEmpty;

    // Narrative/explanation with no duration AND a next_step gets a Next button
    final hasNextButton = (type == 'narrative' || type == 'explanation') &&
        step['next_step'] != null &&
        step['duration'] == null;

    return Positioned(
      top: 60,
      left: 16,
      right: 16,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF1E2227),
        child: Container(
          constraints: const BoxConstraints(maxHeight: 320),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header row
                const Row(
                  children: [
                    Text('🐍 ', style: TextStyle(fontSize: 14)),
                    Text(
                      'Spy',
                      style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // Prompt text
                Text(
                  prompt,
                  style: const TextStyle(
                    color: Color(0xFFDDDDDD),
                    fontSize: 13,
                    height: 1.55,
                  ),
                ),
                // Splash options
                if (hasOptions) ...[
                  const SizedBox(height: 14),
                  _buildOptionButtons(options),
                ],
                // Manual continue button
                if (hasNextButton) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      onPressed: () => _advanceToNext(step),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF37474F),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Next →',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptionButtons(List<dynamic> options) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final opt in options)
          if (opt is Map<String, dynamic>)
            ElevatedButton(
              onPressed: () => _handleOptionTap(opt),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                opt['text'] as String? ?? '',
                style: const TextStyle(fontSize: 12),
              ),
            ),
      ],
    );
  }
}
