/// Web implementation of grid DOM mirror helpers. Calls the JS bridge
/// `window._epyxSetGridSelection(controlId, row, col)` installed by
/// index.html so headless tests can read the focused cell via the DOM.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void publishGridSelection(String controlId, int row, int col) {
  try {
    final fn = globalContext['_epyxSetGridSelection'];
    if (fn != null && fn.isA<JSFunction>()) {
      (fn as JSFunction).callAsFunction(
        null, controlId.toJS, row.toJS, col.toJS);
    }
  } catch (_) {}
}
