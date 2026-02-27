/// Stub implementation for non-web platforms.
///
/// MicroPython WASM is web-only. On desktop/mobile this is a no-op.
class MicroPythonService {
  MicroPythonService._();

  static Future<void> init() async {}

  static bool get isReady => false;

  static dynamic eval(String code, [Map<String, dynamic>? context]) {
    throw UnsupportedError('MicroPython WASM is only available on web');
  }

  static String? fmt(String code, [Map<String, dynamic>? context]) => null;

  static dynamic execEval(String execBody, String evalExpr,
      [Map<String, dynamic>? context]) => null;

  static void exec(String code) {
    throw UnsupportedError('MicroPython WASM is only available on web');
  }

  static String getError() => 'Not available on this platform';
}
