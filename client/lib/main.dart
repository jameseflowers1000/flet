import 'dart:async';
import 'package:flet/flet.dart';
import 'package:flet_ads/flet_ads.dart' as flet_ads;
// --FAT_CLIENT_START--
import 'package:flet_audio/flet_audio.dart' as flet_audio;
// --FAT_CLIENT_END--
import 'package:flet_audio_recorder/flet_audio_recorder.dart'
    as flet_audio_recorder;
import 'package:flet_camera/flet_camera.dart' as flet_camera;
import 'package:flet_charts/flet_charts.dart' as flet_charts;
import 'package:flet_code_editor/flet_code_editor.dart' as flet_code_editor;
import 'package:flet_color_pickers/flet_color_pickers.dart'
    as flet_color_picker;
import 'package:flet_datatable2/flet_datatable2.dart' as flet_datatable2;
import "package:flet_flashlight/flet_flashlight.dart" as flet_flashlight;
import 'package:flet_geolocator/flet_geolocator.dart' as flet_geolocator;
import 'package:flet_lottie/flet_lottie.dart' as flet_lottie;
import 'package:flet_map/flet_map.dart' as flet_map;
import 'package:flet_permission_handler/flet_permission_handler.dart'
    as flet_permission_handler;
// --FAT_CLIENT_START--
// --RIVE_IMPORT_START--
// import 'package:flet_rive/flet_rive.dart' as flet_rive;
// --RIVE_IMPORT_END--
// --FAT_CLIENT_END--
import 'package:flet_secure_storage/flet_secure_storage.dart'
    as flet_secure_storage;
// --FAT_CLIENT_START--
import 'package:flet_video/flet_video.dart' as flet_video;
// --FAT_CLIENT_END--
import 'package:flet_webview/flet_webview.dart' as flet_webview;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flet_einput/flet_einput.dart' as flet_einput;
import 'package:flet_eslider/flet_eslider.dart' as flet_eslider;
import 'package:flet_supertab/flet_supertab.dart' as flet_supertab;
import 'package:flet_superplot/flet_superplot.dart' as flet_superplot;
import 'package:flet_agentview/flet_agentview.dart' as flet_agentview;
import 'package:flet_terminal/flet_terminal.dart' as flet_terminal;
import 'package:flet_micropython/flet_micropython.dart' as flet_micropython;
import 'package:flet_resizable_panel/flet_resizable_panel.dart' as flet_resizable_panel;
import 'package:flet_pane/flet_pane.dart' as flet_pane;
import 'package:flet_thumbnail/flet_thumbnail.dart' as flet_thumbnail;
import 'package:flet_markdown/flet_markdown.dart' as flet_markdown;
import 'package:flet_spy/flet_spy.dart' as flet_spy;
import 'package:flet_marching_ants/flet_marching_ants.dart' as flet_marching_ants;
import 'package:flet_vim_editor/flet_vim_editor.dart' as flet_vim_editor;
import 'package:flet_window_manager/flet_window_manager.dart' as flet_window_manager;
import 'package:flet_pdf_capture/flet_pdf_capture.dart' as flet_pdf_capture;
import 'package:syncfusion_flutter_core/core.dart';

import 'orchestrator_overlay.dart';

const bool isProduction = bool.fromEnvironment('dart.vm.product');

Tester? tester;

// -- Epyx extension list (shared between native and connected modes) --
List<FletExtension> _buildExtensions() {
  final extensions = <FletExtension>[
    flet_ads.Extension(),
    flet_audio_recorder.Extension(),
    flet_camera.Extension(),
    flet_charts.Extension(),
    flet_code_editor.Extension(),
    flet_color_picker.Extension(),
    flet_datatable2.Extension(),
    flet_flashlight.Extension(),
    flet_geolocator.Extension(),
    flet_lottie.Extension(),
    flet_map.Extension(),
    flet_permission_handler.Extension(),
    // Epyx custom extensions:
    flet_einput.Extension(),
    flet_eslider.Extension(),
    flet_supertab.Extension(),
    flet_superplot.Extension(),
    flet_agentview.Extension(),
    flet_terminal.Extension(),
    flet_micropython.Extension(),
    flet_resizable_panel.Extension(),
    flet_pane.Extension(),
    flet_thumbnail.Extension(),
    flet_markdown.Extension(),
    flet_spy.Extension(),
    flet_marching_ants.Extension(),
    flet_vim_editor.Extension(),
    flet_window_manager.Extension(),
    flet_pdf_capture.Extension(),
    flet_secure_storage.Extension(),
    flet_webview.Extension(),
    _EpyxLogoExtension(),
    // --FAT_CLIENT_START--
    // --RIVE_EXTENSION_START--
    // flet_rive.Extension(),
    // --RIVE_EXTENSION_END--
    flet_audio.Extension(),
    flet_video.Extension(),
    // --FAT_CLIENT_END--
  ];
  for (var extension in extensions) {
    extension.ensureInitialized();
  }
  return extensions;
}

// -- Resolve the Flet page URL from args/platform --
String _resolvePageUrl(List<String>? args) {
  if (kDebugMode) return "http://localhost:8550";
  if (kIsWeb) {
    // ?welcome=1 means static serve with no Flet server — show welcome screen
    if (Uri.base.queryParameters.containsKey('welcome')) return "";
    return Uri.base.toString();
  }
  if (args != null && args.isNotEmpty) return args[0];
  return "";
}

void main([List<String>? args]) async {
  if (isProduction) {
    // ignore: avoid_returning_null_for_void
    debugPrint = (String? message, {int? wrapWidth}) => null;
  }

  await setupDesktop();
  WidgetsFlutterBinding.ensureInitialized();

  final extensions = _buildExtensions();
  final pageUrl = _resolvePageUrl(args);

  // Handle PID file and assets dir from args (desktop mode)
  var assetsDir = "";
  if (!kIsWeb && args != null) {
    if (args.length > 1) {
      var pidFilePath = args[1];
      debugPrint("Args contain a path to PID file: $pidFilePath}");
      var pidFile = await File(pidFilePath).create();
      await pidFile.writeAsString("$pid");
    }
    if (args.length > 2) {
      assetsDir = args[2];
      debugPrint("Args contain a path assets directory: $assetsDir}");
    }
  }

  if (kIsWeb) {
    debugPrint("Flet View is running in Web mode");
    var routeUrlStrategy = getFletRouteUrlStrategy();
    debugPrint("URL Strategy: $routeUrlStrategy");
    if (routeUrlStrategy == "path") {
      usePathUrlStrategy();
    }
    assetsDir = getAssetsDir();
  }

  FletAppErrorsHandler errorsHandler = FletAppErrorsHandler();
  if (!kDebugMode) {
    FlutterError.onError = (details) {
      _logGreyBoxDiag('FlutterError.onError', details);
      errorsHandler.onError(details.exceptionAsString());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _logGreyBoxAsyncError(error, stack);
      errorsHandler.onError(error.toString());
      return true;
    };
  }
  // ETB-09b Task #8 — chain ErrorWidget.builder so a widget that throws
  // during build (which becomes a grey RenderErrorBox in release) gets
  // its exception + stack logged to ~/.epyx/grey_box_diag.log. Per
  // feedback_flutter_release_renderbox_diag: release strips the yellow
  // error text, so the grey box looks like a layout bug — instrument
  // up front, name the actual throw. Probe is PASSIVE — defers to the
  // default builder for the visual; only writes a log entry on the way.
  final ErrorWidgetBuilder _defaultErrorBuilder = ErrorWidget.builder;
  ErrorWidget.builder = (FlutterErrorDetails details) {
    _logGreyBoxDiag('ErrorWidget.builder (widget threw during build)', details);
    return _defaultErrorBuilder(details);
  };

  debugPrint("Page URL: $pageUrl");

  // -- SPIKE: Native app shell with lazy Flet embedding --
  // The app starts as a native MaterialApp. When the user opens a doclet,
  // FletApp is embedded as a child widget within the native shell.
  runApp(EpyxApp(
    pageUrl: pageUrl,
    assetsDir: assetsDir,
    extensions: extensions,
    errorsHandler: errorsHandler,
  ));
}

/// ETB-09b Task #8 — append a grey-box diagnostic entry to
/// `~/.epyx/grey_box_diag.log`. Best-effort; swallows file errors so
/// the diagnostic never makes the underlying widget crash worse.
/// Web is excluded — no dart:io, and web didn't reproduce the bug.
void _logGreyBoxDiag(String tag, FlutterErrorDetails details) {
  if (kIsWeb) return;
  try {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dir = Directory('$home/.epyx');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('$home/.epyx/grey_box_diag.log');
    final ts = DateTime.now().toIso8601String();
    final stackStr = details.stack?.toString() ?? '<no stack>';
    // Cap stack to the first ~60 frames so the file stays readable
    // when a widget throws on every rebuild.
    final stackTrimmed =
        stackStr.split('\n').take(60).join('\n');
    final ctx = details.context?.toString() ?? '';
    final lib = details.library ?? '';
    final msg = StringBuffer()
      ..writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
      ..writeln('[$ts] $tag')
      ..writeln('EXCEPTION: ${details.exceptionAsString()}')
      ..writeln('LIBRARY:   $lib')
      ..writeln('CONTEXT:   $ctx')
      ..writeln('STACK (first 60 frames):')
      ..writeln(stackTrimmed)
      ..writeln();
    f.writeAsStringSync(msg.toString(), mode: FileMode.append);
  } catch (_) {
    // Swallow — the diagnostic must never make things worse.
  }
}

void _logGreyBoxAsyncError(Object error, StackTrace stack) {
  if (kIsWeb) return;
  try {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final dir = Directory('$home/.epyx');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final f = File('$home/.epyx/grey_box_diag.log');
    final ts = DateTime.now().toIso8601String();
    final stackTrimmed = stack.toString().split('\n').take(60).join('\n');
    final msg = StringBuffer()
      ..writeln('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
      ..writeln('[$ts] PlatformDispatcher async error')
      ..writeln('ERROR: $error')
      ..writeln('STACK (first 60 frames):')
      ..writeln(stackTrimmed)
      ..writeln();
    f.writeAsStringSync(msg.toString(), mode: FileMode.append);
  } catch (_) {}
}

/// The top-level native Flutter app.
/// Shows a welcome screen, then lazily embeds FletApp when connecting.
class EpyxApp extends StatefulWidget {
  final String pageUrl;
  final String assetsDir;
  final List<FletExtension> extensions;
  final FletAppErrorsHandler errorsHandler;

  const EpyxApp({
    super.key,
    required this.pageUrl,
    required this.assetsDir,
    required this.extensions,
    required this.errorsHandler,
  });

  @override
  State<EpyxApp> createState() => _EpyxAppState();
}

class _EpyxAppState extends State<EpyxApp> {
  bool get _hasServer => widget.pageUrl.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (_hasServer) {
      return FletApp(
        pageUrl: widget.pageUrl,
        assetsDir: widget.assetsDir,
        errorsHandler: widget.errorsHandler,
        showAppStartupScreen: true,
        appStartupScreenMessage: "Working...",
        appErrorMessage: "The application encountered an error: {message}",
        extensions: widget.extensions,
        multiView: isMultiView(),
        tester: tester,
      );
    }

    return MaterialApp(
      title: 'epyx',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF4410AA),
          secondary: const Color(0xFF6C3EBF),
          surface: const Color(0xFF1A1A2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0D1A),
        useMaterial3: true,
      ),
      home: const CatalogScreen(),
    );
  }
}

// -- Animated Epyx logo (per-letter neon glow, matching Python NeonLogo) --
class EpyxLogo extends StatefulWidget {
  final double height;
  // Force the neon (hover) appearance without a real mouse hover — used
  // by external callers (e.g. dialog highlight via NeonLogo.neon_enter).
  final bool forceNeon;
  const EpyxLogo({super.key, this.height = 60, this.forceNeon = false});

  @override
  State<EpyxLogo> createState() => EpyxLogoState();
}

class EpyxLogoState extends State<EpyxLogo> with TickerProviderStateMixin {
  bool _hovering = false;
  bool _busy = false;
  int _currentGlow = 0;
  Timer? _animTimer;

  // Letter order matches Python LETTER_ORDER in neon.py
  static const _letters = ['e', 'p', 'y', 'x', 'dot', 'a', 'i'];
  // Neon logo is ~1.46× taller than flat (same ratio as Python NeonLogo)
  static const _neonRatio = 1.46;
  // Aspect ratio from generated assets (width/height = 462/180)
  static const _aspect = 2.5667;
  // Animation timing (matches Python _FADE_MS=200, interval=0.6)
  static const _fadeDuration = Duration(milliseconds: 200);
  static const _glowInterval = Duration(milliseconds: 600);

  void startBusy() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _currentGlow = 0;
    });
    _animTimer = Timer.periodic(_glowInterval, (_) {
      if (!mounted) return;
      setState(() => _currentGlow = (_currentGlow + 1) % _letters.length);
    });
  }

  void stopBusy() {
    if (!_busy) return;
    _animTimer?.cancel();
    _animTimer = null;
    setState(() => _busy = false);
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final neonHeight = widget.height;
    final flatHeight = widget.height / _neonRatio;

    return MouseRegion(
      onEnter: (_) { if (!_busy) setState(() => _hovering = true); },
      onExit: (_) { if (!_busy) setState(() => _hovering = false); },
      child: SizedBox(
        height: neonHeight,
        width: neonHeight * _aspect,
        child: _busy ? _buildBusyStack(neonHeight) : _buildIdleStack(neonHeight, flatHeight),
      ),
    );
  }

  /// Normal state: flat logo centered, neon on hover
  Widget _buildIdleStack(double neonHeight, double flatHeight) {
    final neon = _hovering || widget.forceNeon;
    return Stack(
      children: [
        // Flat logo (normal)
        AnimatedOpacity(
          opacity: neon ? 0.0 : 1.0,
          duration: _fadeDuration,
          child: Center(
            child: Image.asset('assets/epyx-logo.png',
              height: flatHeight, fit: BoxFit.fitHeight),
          ),
        ),
        // Full neon logo (hover / forced)
        AnimatedOpacity(
          opacity: neon ? 1.0 : 0.0,
          duration: _fadeDuration,
          child: Image.asset('assets/epyx-logo-neon.png',
            height: neonHeight, fit: BoxFit.fitHeight),
        ),
      ],
    );
  }

  /// Busy state: flat base (constant) + per-letter glow overlays (cycling)
  /// Architecture matches Python NeonLogo: 3 layers in Stack —
  ///   1. Flat base (all letters, always visible)
  ///   2. Per-letter glow overlays (one at a time, crossfade via AnimatedOpacity)
  Widget _buildBusyStack(double neonHeight) {
    return Stack(
      children: [
        // Layer 1: flat base — all letters, constant, no flicker
        Image.asset('assets/epyx-anim-base.png',
          height: neonHeight, fit: BoxFit.fitHeight),
        // Layer 2: per-letter glow overlays
        for (int i = 0; i < _letters.length; i++)
          AnimatedOpacity(
            opacity: i == _currentGlow ? 1.0 : 0.0,
            duration: _fadeDuration,
            child: Image.asset('assets/epyx-glow-${_letters[i]}.png',
              height: neonHeight, fit: BoxFit.fitHeight),
          ),
      ],
    );
  }
}

// -- Flet control wrapper around EpyxLogo --
// Lets the IN-DOCLET logo (built by Python in main.py) reuse the SAME
// client-side neon animation as the catalog logo. The `busy` property is
// driven by Python around recalc; the Dart Timer runs in the client, so
// it keeps animating even while the Python event loop is blocked by a
// long fixed-point recalc. Control type "epyx_logo".
class _EpyxLogoControl extends StatefulWidget {
  final Control control;
  const _EpyxLogoControl({super.key, required this.control});

  @override
  State<_EpyxLogoControl> createState() => _EpyxLogoControlState();
}

class _EpyxLogoControlState extends State<_EpyxLogoControl> {
  final GlobalKey<EpyxLogoState> _logoKey = GlobalKey<EpyxLogoState>();

  void _syncBusy() {
    final st = _logoKey.currentState;
    if (st == null) return;
    if (widget.control.getBool("busy", false) ?? false) {
      st.startBusy();
    } else {
      st.stopBusy();
    }
  }

  @override
  Widget build(BuildContext context) {
    // build() re-runs whenever the control notifies (property change),
    // so sync the busy state after this frame onto the (mounted) State.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBusy();
    });
    return EpyxLogo(
      key: _logoKey,
      height: widget.control.getDouble("height") ?? 60,
      forceNeon: widget.control.getBool("force_neon", false) ?? false,
    );
  }
}

class _EpyxLogoExtension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    if (control.type == "epyx_logo") {
      return _EpyxLogoControl(key: key, control: control);
    }
    return null;
  }
}

// -- Data model for a doclet entry --
class DocletInfo {
  final String dirName;
  final String path;
  final String name;
  final String vin;
  final String template;
  final String? description;
  final DateTime? createdAt;
  final DateTime? modifiedAt;
  final String? thumbnailPath;

  DocletInfo({
    required this.dirName,
    required this.path,
    required this.name,
    required this.vin,
    required this.template,
    this.description,
    this.createdAt,
    this.modifiedAt,
    this.thumbnailPath,
  });

  static DocletInfo? fromDirectory(Directory dir) {
    final manifest = File('${dir.path}/manifest.json');
    if (!manifest.existsSync()) return null;
    try {
      final data = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
      final thumbFile = File('${dir.path}/.meta/thumbnail.png');
      return DocletInfo(
        dirName: dir.path.split('/').last,
        path: dir.path,
        name: data['name'] as String? ?? dir.path.split('/').last,
        vin: data['vin'] as String? ?? '',
        template: data['template'] as String? ?? 'Unknown',
        description: data['description'] as String?,
        createdAt: data['created_at'] != null
            ? DateTime.tryParse(data['created_at'] as String)
            : null,
        modifiedAt: data['modified_at'] != null
            ? DateTime.tryParse(data['modified_at'] as String)
            : null,
        thumbnailPath: thumbFile.existsSync() ? thumbFile.path : null,
      );
    } catch (_) {
      return null;
    }
  }
}

// -- Native catalog browser screen --
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  List<DocletInfo> _doclets = [];
  bool _loading = true;
  String _searchQuery = '';
  final _logoKey = GlobalKey<EpyxLogoState>();
  bool _showOrchestrator = false;
  List<String> _docletPaths = [];

  @override
  void initState() {
    super.initState();
    _docletPaths = _loadDocletPaths();
    _scanDoclets();
  }

  /// Default doclet path based on platform.
  String get _defaultDocletsPath {
    if (Platform.isMacOS) {
      return '${Platform.environment['HOME']}/Library/Application Support/Epyx/Doclets';
    } else if (Platform.isLinux) {
      return '${Platform.environment['HOME']}/.local/share/epyx/doclets';
    } else if (Platform.isWindows) {
      return '${Platform.environment['APPDATA']}\\Epyx\\Doclets';
    }
    return '';
  }

  /// Load doclet search paths from config, falling back to default.
  List<String> _loadDocletPaths() {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return [_defaultDocletsPath];

      String configPath;
      if (Platform.isMacOS) {
        configPath = '$home/Library/Application Support/Epyx/config.yaml';
      } else if (Platform.isLinux) {
        final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
        configPath = '$xdg/epyx/config.yaml';
      } else {
        return [_defaultDocletsPath];
      }

      final file = File(configPath);
      if (!file.existsSync()) return [_defaultDocletsPath];

      // Simple YAML parsing for storage.doclet_paths list
      final lines = file.readAsLinesSync();
      bool inStorage = false;
      bool inDocletPaths = false;
      final paths = <String>[];

      for (final line in lines) {
        if (line.startsWith('storage:')) {
          inStorage = true;
          continue;
        }
        if (inStorage && !line.startsWith(' ') && !line.startsWith('\t') && line.isNotEmpty) {
          inStorage = false;
        }
        if (inStorage && line.trim().startsWith('doclet_paths:')) {
          inDocletPaths = true;
          continue;
        }
        if (inDocletPaths) {
          final trimmed = line.trim();
          if (trimmed.startsWith('- ')) {
            paths.add(trimmed.substring(2).trim());
          } else {
            inDocletPaths = false;
          }
        }
      }

      if (paths.isNotEmpty) return paths;
    } catch (_) {
      // Fall through to default
    }
    return [_defaultDocletsPath];
  }

  void _scanDoclets() {
    final doclets = <DocletInfo>[];
    final seenVins = <String>{};

    for (final path in _docletPaths) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is Directory) {
          final info = DocletInfo.fromDirectory(entity);
          if (info != null && !seenVins.contains(info.vin)) {
            doclets.add(info);
            if (info.vin.isNotEmpty) seenVins.add(info.vin);
          }
        }
      }
    }
    // Sort by modified date descending (most recent first)
    doclets.sort((a, b) {
      final am = a.modifiedAt ?? a.createdAt ?? DateTime(2000);
      final bm = b.modifiedAt ?? b.createdAt ?? DateTime(2000);
      return bm.compareTo(am);
    });
    setState(() {
      _doclets = doclets;
      _loading = false;
    });
  }

  List<DocletInfo> get _filtered {
    if (_searchQuery.isEmpty) return _doclets;
    final q = _searchQuery.toLowerCase();
    return _doclets.where((d) =>
        d.name.toLowerCase().contains(q) ||
        d.template.toLowerCase().contains(q) ||
        (d.description?.toLowerCase().contains(q) ?? false)).toList();
  }

  /// Build doclet context list for the agent.
  List<Map<String, dynamic>> get _docletContextForAgent {
    return _doclets.map((d) => {
      'name': d.name,
      'template': d.template,
      'description': d.description ?? '',
      'modified': d.modifiedAt?.toIso8601String(),
      'path': d.path,
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              _buildHeader(),
              if (!_loading) _buildSearchBar(),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _filtered.isEmpty
                        ? _buildEmptyState()
                        : _buildGrid(),
              ),
            ],
          ),
          if (_showOrchestrator)
            OrchestratorOverlay(
              onClose: () {
                _logoKey.currentState?.stopBusy();
                setState(() => _showOrchestrator = false);
              },
              doclets: _docletContextForAgent,
              docletPaths: _docletPaths,
              onDocletCreated: () {
                _logoKey.currentState?.stopBusy();
                setState(() {
                  _showOrchestrator = false;
                  _loading = true;
                });
                _scanDoclets();
              },
              onDocletPathsChanged: (paths) {
                setState(() {
                  _docletPaths = paths;
                  _loading = true;
                });
                _scanDoclets();
              },
              onBusyChanged: (busy) {
                if (busy) {
                  _logoKey.currentState?.startBusy();
                } else {
                  _logoKey.currentState?.stopBusy();
                }
              },
              onOpenDoclet: (name) {
                _logoKey.currentState?.stopBusy();
                setState(() => _showOrchestrator = false);
                // Find the doclet by name and open it
                final match = _doclets.where(
                    (d) => d.name.toLowerCase() == name.toLowerCase());
                if (match.isNotEmpty) {
                  _openDoclet(match.first);
                } else {
                  // Try opening by dirName directly
                  _launchEdd(['open', name]);
                }
              },
            ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_showOrchestrator) _logoKey.currentState?.stopBusy();
              setState(() => _showOrchestrator = !_showOrchestrator);
            },
            child: EpyxLogo(key: _logoKey, height: 60),
          ),
          const SizedBox(width: 16),
          Text(
            'Documents',
            style: TextStyle(
              fontSize: 24,
              color: Colors.grey[300],
              fontWeight: FontWeight.w300,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open doclet from folder...',
            onPressed: _pickAndOpenDoclet,
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              setState(() => _loading = true);
              _scanDoclets();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
      child: TextField(
        decoration: InputDecoration(
          hintText: 'Search doclets...',
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor: const Color(0xFF1A1A2E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  Widget _buildEmptyState() {
    if (_doclets.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text('No doclets found', style: TextStyle(color: Colors.grey[500], fontSize: 18)),
            const SizedBox(height: 8),
            Text('Use  edd create  to create a new document',
                style: TextStyle(color: Colors.grey[600], fontSize: 14)),
          ],
        ),
      );
    }
    return Center(
      child: Text('No matches for "$_searchQuery"',
          style: TextStyle(color: Colors.grey[500])),
    );
  }

  Widget _buildGrid() {
    return LayoutBuilder(builder: (context, constraints) {
      final crossAxisCount = (constraints.maxWidth / 260).floor().clamp(1, 6);
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          childAspectRatio: 0.85,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: _filtered.length,
        itemBuilder: (context, index) => _buildCard(_filtered[index]),
      );
    });
  }

  Widget _buildCard(DocletInfo doclet) {
    return Card(
      color: const Color(0xFF1E1E30),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: () => _openDoclet(doclet),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: doclet.thumbnailPath != null
                  ? Image.file(File(doclet.thumbnailPath!), fit: BoxFit.cover)
                  : Container(
                      color: const Color(0xFF14142A),
                      child: Center(
                        child: Icon(Icons.description,
                            size: 48, color: Colors.grey[700]),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doclet.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4410AA).withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          doclet.template,
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[300]),
                        ),
                      ),
                      const Spacer(),
                      if (doclet.modifiedAt != null)
                        Text(
                          _formatDate(doclet.modifiedAt!),
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  Future<void> _pickAndOpenDoclet() async {
    // Native folder picker via osascript (macOS) or zenity (Linux)
    String? dirPath;
    if (Platform.isMacOS) {
      final result = await Process.run('osascript', [
        '-e',
        'set f to POSIX path of (choose folder with prompt "Select a doclet directory")',
      ]);
      if (result.exitCode == 0) {
        dirPath = (result.stdout as String).trim();
        // osascript adds trailing slash — remove it
        if (dirPath.endsWith('/') && dirPath.length > 1) {
          dirPath = dirPath.substring(0, dirPath.length - 1);
        }
      }
    } else if (Platform.isLinux) {
      final result = await Process.run('zenity', ['--file-selection', '--directory']);
      if (result.exitCode == 0) dirPath = (result.stdout as String).trim();
    }
    if (dirPath == null || dirPath.isEmpty) return;

    // Validate it's a doclet (must have manifest.json)
    if (!File('$dirPath/manifest.json').existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Not a doclet: $dirPath (no manifest.json found)'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
      return;
    }

    // Pass the absolute path to edd open — resolve_doclet handles paths
    final eddPath = _findEdd();
    if (eddPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: edd not found on PATH or in ~/bin')),
        );
      }
      return;
    }
    _launchEdd(['open', dirPath]);
  }

  String? _findEdd() {
    // Resolve the edd script path. Try: PATH, ~/bin, known symlink.
    final result = Process.runSync('which', ['edd']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
    final home = Platform.environment['HOME'] ?? '';
    final homeBin = '$home/bin/edd';
    if (File(homeBin).existsSync()) return homeBin;
    return null;
  }

  Future<void> _openDoclet(DocletInfo doclet) async {
    _launchEdd(['open', doclet.dirName]);
  }

  static final _errorPattern = RegExp(
    r'(^error\b|^fatal\b|cannot connect|connection refused|no such file|server error|traceback|exception)',
    caseSensitive: false,
  );

  /// Launch edd with args. Watches stderr in real-time and shows
  /// genuine errors in a SnackBar (filters out routine log chatter).
  Future<void> _launchEdd(List<String> args) async {
    final eddPath = _findEdd();
    if (eddPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: edd not found on PATH or in ~/bin')),
        );
      }
      return;
    }
    // Start busy animation while container launches
    _logoKey.currentState?.startBusy();
    final process = await Process.start(eddPath, args);
    bool errorShown = false;
    bool busyStopped = false;
    void stopBusy() {
      if (busyStopped) return;
      busyStopped = true;
      _logoKey.currentState?.stopBusy();
    }
    // Safety timeout in case handshake never arrives
    final busyTimer = Timer(const Duration(seconds: 30), stopBusy);
    // Watch stdout for EPYX_CLIENT_READY handshake from startup agent
    process.stdout.transform(const SystemEncoding().decoder).listen((data) {
      if (data.contains('EPYX_CLIENT_READY')) {
        busyTimer.cancel();
        stopBusy();
      }
    });
    process.stderr.transform(const SystemEncoding().decoder).listen((data) {
      if (errorShown || !mounted) return;
      for (final line in data.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty && _errorPattern.hasMatch(trimmed)) {
          errorShown = true;
          busyTimer.cancel();
          stopBusy();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(trimmed),
              duration: const Duration(seconds: 10),
            ),
          );
          break;
        }
      }
    });
    process.exitCode.then((code) {
      busyTimer.cancel();
      stopBusy();
      if (code != 0 && !errorShown && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('edd exited with code $code'),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    });
  }
}
