/// Web implementation of DOM mirror helpers. Calls the JS bridge functions
/// installed by index.html (`window._epyxSetBanner`, `window._epyxBeep`)
/// so headless tests can read the latest banner/beep from the DOM.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void publishBanner(String message, String level) {
  try {
    final fn = globalContext['_epyxSetBanner'];
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(null, message.toJS, level.toJS);
    }
  } catch (_) {}
}

void publishBeep() {
  try {
    final fn = globalContext['_epyxBeep'];
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(null);
    }
  } catch (_) {}
}
