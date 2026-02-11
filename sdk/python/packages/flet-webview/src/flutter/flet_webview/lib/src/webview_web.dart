import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flet/flet.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_web/webview_flutter_web.dart';

class WebviewWeb extends StatefulWidget {
  final Control control;

  const WebviewWeb({super.key, required this.control});

  @override
  State<WebviewWeb> createState() => _WebviewWebState();
}

class _WebviewWebState extends State<WebviewWeb> {
  late PlatformWebViewController controller;
  String _currentUrl = "";
  bool _currentInteractive = true;

  @override
  void initState() {
    super.initState();
    WebViewPlatform.instance = WebWebViewPlatform();

    _currentUrl = widget.control.getString("url", "https://flet.dev")!;
    _currentInteractive = widget.control.getBool("interactive", true) ?? true;
    controller = PlatformWebViewController(
      const PlatformWebViewControllerCreationParams(),
    )..loadRequest(
        LoadRequestParams(uri: Uri.parse(_currentUrl)),
      );

    // Set initial iframe interactive state via JS bridge
    _setIframeInteractive(_currentInteractive);
  }

  @override
  void didUpdateWidget(WebviewWeb oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newUrl = widget.control.getString("url", "https://flet.dev")!;
    if (newUrl != _currentUrl) {
      _currentUrl = newUrl;
      controller.loadRequest(
        LoadRequestParams(uri: Uri.parse(newUrl)),
      );
    }
    final newInteractive = widget.control.getBool("interactive", true) ?? true;
    if (newInteractive != _currentInteractive) {
      _currentInteractive = newInteractive;
      _setIframeInteractive(newInteractive);
    }
  }

  /// Call into the index.html JS bridge to enable/disable iframe pointer events.
  ///
  /// LIMITATION: This is a blanket toggle — it affects ALL iframes on the page.
  /// Before adding a second WebView to the Orchestrator, refactor to pass
  /// widget.control.id so the JS side can target individual iframes.
  /// See: notes/dart_widgets_plan.md § "Per-Iframe Pointer-Events Targeting"
  void _setIframeInteractive(bool interactive) {
    final fn = globalContext['_epyxSetIframeInteractive'];
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(null, interactive.toJS);
    }
  }

  @override
  Widget build(BuildContext context) {
    final interactive = widget.control.getBool("interactive", true) ?? true;
    Widget view = PlatformWebViewWidget(
      PlatformWebViewWidgetCreationParams(controller: controller),
    ).build(context);
    // Always wrap in IgnorePointer to keep widget tree structure stable.
    // Toggling between IgnorePointer(child) and bare child causes Flutter
    // to recreate the platform view iframe (flash on mode switch).
    return IgnorePointer(ignoring: !interactive, child: view);
  }
}
