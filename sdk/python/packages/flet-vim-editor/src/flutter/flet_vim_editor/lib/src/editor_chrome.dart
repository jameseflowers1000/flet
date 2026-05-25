// Chrome that wraps the editor body — top toolbar with action buttons
// + mode switch + label, plus a thin hint/status bar at the bottom.
//
// Modeled on the Epyx orchestrator's nvim toolbar
// (`orchestrator.py:_build_nvim_toolbar` / lines 427-532). The
// orchestrator surface is:
//   • Save / Close / divider / Undo / Redo / divider / Defaults
//   • A muted edit-target label that fills the row
//   • A "Neo" branding cluster on the right
//   • Hint bar below with copy/paste / shortcut docs
//
// Adapted for the lab's two-editor design:
//   • Save / Close / Undo / Redo on the left (icon buttons,
//     Material icons standing in for the orch's SVG assets).
//   • EZ↔Vim toggle near the right.
//   • Edit-target label between the action group and the toggle.
//   • Status bar at the bottom: cursor position, LSP/nvim health,
//     keyboard hints (Cmd-K hover, Cmd-S save).
//
// Palette comes from `orchestrator.py:108-113` so editor surfaces
// feel like part of the same product.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'edit_session.dart';

/// Asset path prefix for the curated toolbar SVGs bundled with this
/// extension (`packages/flet-vim-editor/.../assets/icons/`). Mirrors
/// the original orchestrator's `_build_nvim_toolbar` which loaded
/// `save.svg`, `dismiss-neo.svg`, `defaults-neo.svg`, `neo.svg` via
/// `get_cached_image_resource` from the Python `epyx/assets/` dir.
/// Shipping the same artwork inside the extension keeps the look-
/// and-feel identical to what the tmux+ttyd path used to render.
const String _kIconPkg = 'packages/flet_vim_editor/assets/icons';

const Color _kBg = Color(0xFF1A191F);
const Color _kBgPanel = Color(0xFF1E1E2E); // BAR_BG in orch
const Color _kBgHint = Color(0xFF16161E); // hint-bar bg in orch
const Color _kFg = Color(0xFFCCCCCC); // MUTED in orch
const Color _kFgDim = Color(0xFFAAAAAA); // muted label
const Color _kFgFaint = Color(0xFF666666); // INACTIVE / hint text
const Color _kActive = Color(0xFF97C977); // ACTIVE (sage green)
const Color _kAccent2 = Color(0xFF5EA702); // yank/paste hint accent
const Color _kBorder = Color(0xFF2E2D34);
const Color _kDivider = Color(0xFF444444);
const Color _kDirty = Color(0xFFFFAA33);

enum EditorMode { native, nvim }

/// A small action invoked by a toolbar button. The chrome surfaces
/// these as icon buttons; the parent (UnifiedEditor) decides whether
/// each is enabled and what it does.
class EditorActions {
  final VoidCallback? save; // null disables the button
  final VoidCallback? cancel;
  final VoidCallback? undo;
  final VoidCallback? redo;
  final VoidCallback? hover; // Cmd-K → show hover docs
  const EditorActions({
    this.save,
    this.cancel,
    this.undo,
    this.redo,
    this.hover,
  });
}

/// Status data shown in the bottom bar — cursor position, system
/// health badges, current-line diagnostic. The chrome rebuilds
/// whenever any of these change.
class EditorStatus {
  final int cursorLine; // 0-based
  final int cursorCol;
  final bool lspConnected;
  final bool nvimConnected;
  /// Last error reported by the LSP transport — surfaced as a tooltip
  /// AND a banner when `lspConnected` is false. Empty/null = no error
  /// to surface (either healthy, or never connected to begin with).
  final String? lspError;
  final String? nvimError;
  final String? mode; // "INSERT" / "NORMAL" / etc. for vim; null otherwise
  /// First diagnostic that overlaps the cursor's current line — its
  /// message is rendered inline so the user can see why a wavy
  /// underline / sign is there without leaving the editor.
  final String? diagnosticMessage;
  /// 1=Error, 2=Warning, 3=Info, 4=Hint — drives the indicator color.
  final int? diagnosticSeverity;
  const EditorStatus({
    this.cursorLine = 0,
    this.cursorCol = 0,
    this.lspConnected = false,
    this.nvimConnected = false,
    this.lspError,
    this.nvimError,
    this.mode,
    this.diagnosticMessage,
    this.diagnosticSeverity,
  });

  bool get hasHealthIssue => !lspConnected || !nvimConnected;
}

class EditorChrome extends StatelessWidget {
  final EditSession session;
  final EditorMode mode;
  final ValueChanged<EditorMode> onModeChange;
  final EditorActions actions;
  final EditorStatus status;
  final Widget body;

  const EditorChrome({
    super.key,
    required this.session,
    required this.mode,
    required this.onModeChange,
    required this.actions,
    required this.status,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        return Container(
          color: _kBg,
          child: Column(
            children: [
              _Toolbar(
                session: session,
                mode: mode,
                onModeChange: onModeChange,
                actions: actions,
              ),
              // Always mounted so it can debounce internally — the brief
              // connecting window on editor open must NOT flash "LSP DOWN".
              _HealthBanner(status: status),
              Expanded(
                child: Container(
                  color: const Color(0xFF111111),
                  child: body,
                ),
              ),
              _StatusBar(status: status, mode: mode),
            ],
          ),
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  final EditSession session;
  final EditorMode mode;
  final ValueChanged<EditorMode> onModeChange;
  final EditorActions actions;

  const _Toolbar({
    required this.session,
    required this.mode,
    required this.onModeChange,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _kBgPanel,
        border: Border(bottom: BorderSide(color: _kBorder, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      height: 36,
      child: Row(
        children: [
          // Left action cluster: Save / Close / divider / Undo / Redo /
          // divider / Help. Save and Close use the curated SVG assets
          // bundled with this extension (artwork ported from the
          // original orchestrator's `_build_nvim_toolbar` so the new
          // editor feels like the same product). Undo/Redo/Help stay
          // on Material icons — those were Material in the orch too.
          _SvgBtn(
            assetName: 'save.svg',
            tooltip: 'Save  •  ⌘S',
            onTap: actions.save,
          ),
          _SvgBtn(
            assetName: 'dismiss-neo.svg',
            tooltip: 'Close  •  Esc',
            onTap: actions.cancel,
          ),
          const _VBar(),
          _IconBtn(
            icon: Icons.undo,
            tooltip: 'Undo  •  ⌘Z',
            onTap: actions.undo,
          ),
          _IconBtn(
            icon: Icons.redo,
            tooltip: 'Redo  •  ⇧⌘Z',
            onTap: actions.redo,
          ),
          const _VBar(),
          _IconBtn(
            icon: Icons.help_outline,
            tooltip: 'Show docs for symbol  •  ⌘K',
            onTap: actions.hover,
          ),
          const SizedBox(width: 12),
          // Edit-target label fills the middle. Truncates with ellipsis;
          // dirty state surfaced with a leading dot, same affordance as
          // the orchestrator's edit label.
          Expanded(
            child: Row(
              children: [
                if (session.dirty) ...[
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Text('●',
                        style: TextStyle(color: _kDirty, fontSize: 12)),
                  ),
                ] else
                  const SizedBox(width: 14),
                Flexible(
                  child: Text(
                    session.label.isEmpty ? '(unnamed)' : session.label,
                    style: const TextStyle(
                      color: _kFg,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
          // Neo brand mark (matches the orch's right-side cluster).
          const _BrandSvg(assetName: 'neo.svg', size: 22),
          const SizedBox(width: 8),
          // Mode toggle on the right.
          _ModeSwitch(mode: mode, onChange: onModeChange),
        ],
      ),
    );
  }
}

class _StatusBar extends StatefulWidget {
  final EditorStatus status;
  final EditorMode mode;
  const _StatusBar({required this.status, required this.mode});

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  Timer? _clockTick;
  // Re-render once a minute so the displayed clock advances. We pin
  // the rebuild rate to "next-minute" rather than every-second since
  // we only show HH:MM AM/PM.
  void _scheduleClockTick() {
    _clockTick?.cancel();
    final now = DateTime.now();
    final msToNextMinute =
        Duration(minutes: 1).inMilliseconds - (now.second * 1000 + now.millisecond);
    _clockTick = Timer(Duration(milliseconds: msToNextMinute), () {
      if (mounted) setState(() {});
      _scheduleClockTick();
    });
  }

  @override
  void initState() {
    super.initState();
    _scheduleClockTick();
  }

  @override
  void dispose() {
    _clockTick?.cancel();
    super.dispose();
  }

  String _formattedTime() {
    final n = DateTime.now();
    final h12 = ((n.hour + 11) % 12) + 1; // 0→12, 13→1, …
    final mm = n.minute.toString().padLeft(2, '0');
    final ampm = n.hour < 12 ? 'AM' : 'PM';
    return '${h12.toString().padLeft(2, '0')}:$mm $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    // Cursor position: numbers boldfaced, two spaces between Ln…Col,
    // no comma. Time follows after another two-space gap, also bold.
    final lineNum = (status.cursorLine + 1).toString();
    final colNum = (status.cursorCol + 1).toString();
    final cursorSpan = TextSpan(
      style: const TextStyle(color: _kFgDim, fontSize: 10),
      children: [
        const TextSpan(text: 'Ln '),
        TextSpan(text: lineNum,
            style: const TextStyle(fontWeight: FontWeight.w700, color: _kFg)),
        const TextSpan(text: '  Col '),
        TextSpan(text: colNum,
            style: const TextStyle(fontWeight: FontWeight.w700, color: _kFg)),
        const TextSpan(text: '  '),
        TextSpan(
          text: _formattedTime(),
          style: const TextStyle(fontWeight: FontWeight.w700, color: _kFg),
        ),
      ],
    );
    final lspBadge = _badge(
      label: 'LSP',
      ok: status.lspConnected,
      tooltip: status.lspConnected
          ? 'Language server connected'
          : 'Language server unavailable',
    );
    final nvimBadge = _badge(
      label: 'nvim',
      ok: status.nvimConnected,
      tooltip: status.nvimConnected
          ? 'nvim RPC connected'
          : 'nvim RPC unavailable',
    );
    final hintRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Text('⌘K', style: TextStyle(color: _kAccent2, fontSize: 10)),
        Text(' docs   ', style: TextStyle(color: _kFgFaint, fontSize: 10)),
        Text('⌘S', style: TextStyle(color: _kAccent2, fontSize: 10)),
        Text(' save   ', style: TextStyle(color: _kFgFaint, fontSize: 10)),
        Text('⌘/', style: TextStyle(color: _kAccent2, fontSize: 10)),
        Text(' EZ↔Vim   ',
            style: TextStyle(color: _kFgFaint, fontSize: 10)),
        Text('?? ⏎', style: TextStyle(color: _kAccent2, fontSize: 10)),
        Text(' Haiku rewrite',
            style: TextStyle(color: _kFgFaint, fontSize: 10)),
      ],
    );
    // Diagnostic display takes the row when the cursor is on a
    // diagnostic line — that's the most relevant info; collapses
    // back to the hint row otherwise.
    final diagWidget = status.diagnosticMessage == null
        ? null
        : Expanded(
            child: Row(
              children: [
                Icon(
                  status.diagnosticSeverity == 1
                      ? Icons.error_outline
                      : Icons.warning_amber_outlined,
                  size: 12,
                  color: status.diagnosticSeverity == 1
                      ? const Color(0xFFE05A5A)
                      : _kDirty,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    status.diagnosticMessage!,
                    style: TextStyle(
                      color: status.diagnosticSeverity == 1
                          ? const Color(0xFFE05A5A)
                          : _kDirty,
                      fontSize: 10,
                      fontFamily: 'JetBrainsMono',
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          );
    return Container(
      decoration: const BoxDecoration(
        color: _kBgHint,
        border: Border(top: BorderSide(color: _kBorder, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      height: 22,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text.rich(cursorSpan),
          const SizedBox(width: 12),
          if (status.mode != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(status.mode!,
                  style: const TextStyle(
                      color: _kActive,
                      fontSize: 10,
                      fontWeight: FontWeight.w700)),
            ),
          lspBadge,
          const SizedBox(width: 8),
          nvimBadge,
          const SizedBox(width: 12),
          if (diagWidget != null) diagWidget,
          // Hint row shrinks with the window: the prefix pieces (Ln,
          // Col, time, badges, mode) keep their natural size; the
          // shortcut hints scroll horizontally inside whatever width
          // remains so the bar never overflows on narrow chrome.
          if (diagWidget == null)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true, // keep the rightmost (Haiku) visible
                physics: const ClampingScrollPhysics(),
                child: hintRow,
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge(
      {required String label, required bool ok, required String tooltip}) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: ok ? const Color(0xFF1F2A18) : const Color(0xFF2A1818),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: ok ? _kActive.withValues(alpha: 0.4) : _kFgFaint,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: ok ? _kActive : _kFgFaint,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? colorOverride;
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.colorOverride,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color =
        !enabled ? _kFgFaint : (colorOverride ?? _kFg);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Icon(icon, color: color, size: 18),
        ),
      ),
    );
  }
}

/// SVG-asset toolbar button. Used for the curated orchestrator-style
/// icons (save / dismiss-neo / defaults-neo) that ship with this
/// extension under `assets/icons/`. Same hit-target + tooltip
/// affordances as `_IconBtn`; no color tint is applied (the SVGs
/// are pre-tinted in their painted form), but `disabled` reduces
/// opacity to match `_IconBtn`'s faint-when-disabled treatment.
class _SvgBtn extends StatelessWidget {
  final String assetName;          // file name only, e.g. 'save.svg'
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  const _SvgBtn({
    required this.assetName,
    required this.tooltip,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 36,
          height: 32,
          alignment: Alignment.center,
          child: Opacity(
            opacity: enabled ? 1.0 : 0.35,
            child: SvgPicture.asset(
              '$_kIconPkg/$assetName',
              width: size,
              height: size,
            ),
          ),
        ),
      ),
    );
  }
}

/// Pure-display SVG (no hit target). For the Neo brand mark on the
/// right side of the toolbar.
class _BrandSvg extends StatelessWidget {
  final String assetName;
  final double size;
  const _BrandSvg({required this.assetName, this.size = 22});
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        '$_kIconPkg/$assetName',
        width: size,
        height: size,
      );
}

class _VBar extends StatelessWidget {
  const _VBar();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 18,
        color: _kDivider,
        margin: const EdgeInsets.symmetric(horizontal: 4),
      );
}

class _ModeSwitch extends StatelessWidget {
  final EditorMode mode;
  final ValueChanged<EditorMode> onChange;
  const _ModeSwitch({required this.mode, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final ezActive = mode == EditorMode.native;
    final next = ezActive ? EditorMode.nvim : EditorMode.native;
    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChange(next),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: _kBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: _kBorder),
            ),
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 11, letterSpacing: 0.4),
                children: [
                  TextSpan(
                    text: 'EZ',
                    style: TextStyle(
                      color: ezActive ? _kActive : _kFgFaint,
                      fontWeight:
                          ezActive ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const TextSpan(
                    text: '  |  ',
                    style: TextStyle(color: _kFgFaint),
                  ),
                  TextSpan(
                    text: 'Vim',
                    style: TextStyle(
                      color: !ezActive ? _kActive : _kFgFaint,
                      fontWeight:
                          !ezActive ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Unmissable banner shown directly under the toolbar when the LSP or
/// nvim connection is unhealthy. Replaces the previous silent-failure
/// mode where "completions stopped working" had zero UI signal.
///
/// Specifically called out:
///   - "LSP DOWN" with last-error tooltip when pygls disconnected
///   - "nvim DOWN" with last-error tooltip when RPC closed
///
/// Click-through to a one-line remediation suggestion. Yellow-on-red
/// so it can't be ignored.
class _HealthBanner extends StatefulWidget {
  final EditorStatus status;
  const _HealthBanner({required this.status});

  @override
  State<_HealthBanner> createState() => _HealthBannerState();
}

class _HealthBannerState extends State<_HealthBanner> {
  // Only surface the banner once a down state has PERSISTED this long.
  // The connecting window on editor open (LSP `initialize` round-trip,
  // ~tens of ms) clears well before this, so it never flashes the alarming
  // "LSP DOWN" — but a genuine sustained outage (>grace) still shows.
  static const _graceMs = 1500;
  bool _show = false;
  Timer? _graceTimer;

  List<String> _issues() {
    final s = widget.status;
    final issues = <String>[];
    if (!s.lspConnected) {
      final err = (s.lspError ?? '').isEmpty ? '(no detail)' : s.lspError!;
      issues.add('LSP DOWN — $err');
    }
    if (!s.nvimConnected) {
      final err = (s.nvimError ?? '').isEmpty ? '(no detail)' : s.nvimError!;
      issues.add('nvim DOWN — $err');
    }
    return issues;
  }

  void _evaluate() {
    final hasIssues = _issues().isNotEmpty;
    if (!hasIssues) {
      _graceTimer?.cancel();
      _graceTimer = null;
      if (_show) setState(() => _show = false);
      return;
    }
    if (_show || _graceTimer != null) return; // already shown / pending
    _graceTimer = Timer(const Duration(milliseconds: _graceMs), () {
      _graceTimer = null;
      if (mounted && _issues().isNotEmpty) setState(() => _show = true);
    });
  }

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  @override
  void didUpdateWidget(covariant _HealthBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _evaluate();
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final issues = _issues();
    if (issues.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFFB23A3A), // alert red
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFFFE08A), size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              issues.join('  •  '),
              style: const TextStyle(
                color: Color(0xFFFFE08A),
                fontSize: 11,
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Restart the lab (q + flutter run) to recover',
            style: TextStyle(
              color: Color(0xFFFFE08A),
              fontSize: 10,
              fontFamily: 'JetBrainsMono',
            ),
          ),
        ],
      ),
    );
  }
}
