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

    // Tag the iframe AFTER the platform view is in the DOM, then apply
    // the interactive state — order matters: the JS bridge selects by
    // data-flet-id, so the tag must exist before the state apply.
    //
    // CRITICAL retry loop: platform views in Flutter web are inserted
    // into the DOM asynchronously by Flutter's renderer, often AFTER
    // the first frame's PostFrameCallback fires. A single tag attempt
    // can race the iframe creation, fail to find anything, and leave
    // the iframe forever `pointer-events: auto` — which then captures
    // every click on widgets layered over its rect (the orchestrator's
    // vim editor sits over the Python WebView; before this fix every
    // save click hit the underlying ttyd iframe instead of the
    // editor's save button).
    //
    // Try every 100ms for up to 3 seconds, and ALSO call the JS bridge
    // each iteration so that once the tag lands the per-iframe state
    // immediately picks up. Stops early when the iframe is found.
    _tagAndSyncInteractiveWithRetry();
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

  /// Retry-tagging loop: every 100ms try to find and tag the iframe,
  /// then re-apply the interactive state. Stops when the iframe is
  /// tagged or after ~3s. See the long comment in initState.
  void _tagAndSyncInteractiveWithRetry() {
    var attempts = 0;
    void tick() {
      if (!mounted) return;
      attempts += 1;
      _tagIframe();
      _setIframeInteractive(_currentInteractive);
      final tagged = _isIframeTagged();
      if (tagged || attempts >= 30) return;
      Future.delayed(const Duration(milliseconds: 100), tick);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  /// Check via JS whether an iframe with our controlId is in the DOM.
  bool _isIframeTagged() {
    final evalFn = globalContext['eval'];
    if (evalFn == null || !evalFn.isA<JSFunction>()) return false;
    final js =
        "(function(){return !!document.querySelector('[data-flet-id=\"$_controlId\"]');})()";
    final res = (evalFn as JSFunction).callAsFunction(null, js.toJS);
    return res != null && res.dartify() == true;
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
    // Belt-and-suspenders: also directly set pointer-events on any
    // iframe with this control's `data-flet-id`. The bridge call above
    // is supposed to do this, but if the iframe was added after the
    // iframeStates entry, the bridge's `applyIframeState` may have
    // run before the tag landed and missed the iframe. A direct DOM
    // mutation here is idempotent and immediate.
    final evalFn = globalContext['eval'];
    if (evalFn != null && evalFn.isA<JSFunction>()) {
      final pe = interactive ? 'auto' : 'none';
      final js = """
        (function(){
          var el = document.querySelector('[data-flet-id="$_controlId"]');
          if (el) {
            el.style.setProperty('pointer-events', '$pe', 'important');
            var ifr = el.tagName === 'IFRAME' ? el : el.querySelector('iframe');
            if (ifr) ifr.style.setProperty('pointer-events', '$pe', 'important');
          }
        })();
      """;
      (evalFn as JSFunction).callAsFunction(null, js.toJS);
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
