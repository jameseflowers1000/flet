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

  String get _controlId => widget.control.id.toString();

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

    // Set initial iframe interactive state via JS bridge (per-control)
    _setIframeInteractive(_currentInteractive);
    // Tag the iframe with data-flet-id after build
    WidgetsBinding.instance.addPostFrameCallback((_) => _tagIframe());
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

  /// Tag the iframe element with data-flet-id so the JS bridge can target it.
  void _tagIframe() {
    // Use JS interop to find and tag the iframe created by the platform view.
    // The platform view creates an iframe; we tag it with the Flet control ID.
    final js = '''
      (function() {
        // Find iframes without data-flet-id and tag the most recently added one
        var iframes = document.querySelectorAll('iframe:not([data-flet-id])');
        if (iframes.length > 0) {
          iframes[iframes.length - 1].setAttribute('data-flet-id', '${_controlId}');
          return;
        }
        // Also check shadow roots
        document.querySelectorAll('flutter-view, flt-glass-pane').forEach(function(el) {
          if (el.shadowRoot) {
            var sIframes = el.shadowRoot.querySelectorAll('iframe:not([data-flet-id])');
            if (sIframes.length > 0) {
              sIframes[sIframes.length - 1].setAttribute('data-flet-id', '${_controlId}');
            }
          }
        });
      })();
    ''';
    final evalFn = globalContext['eval'];
    if (evalFn != null && evalFn.isA<JSFunction>()) {
      (evalFn as JSFunction).callAsFunction(null, js.toJS);
    }
  }

  /// Call into the index.html JS bridge to enable/disable iframe pointer events.
  ///
  /// Uses per-control targeting: passes widget.control.id so the JS side
  /// can target this specific iframe via data-flet-id attribute.
  void _setIframeInteractive(bool interactive) {
    final fn = globalContext['_epyxSetIframeInteractive'];
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(null, _controlId.toJS, interactive.toJS);
    }
    // When becoming interactive, also focus this specific iframe
    if (interactive) {
      final focusFn = globalContext['_epyxFocusIframe'];
      if (focusFn != null && focusFn.isA<JSFunction>()) {
        (focusFn as JSFunction).callAsFunction(null, _controlId.toJS);
      }
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
