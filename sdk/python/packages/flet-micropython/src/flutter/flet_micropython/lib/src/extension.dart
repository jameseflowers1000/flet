import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'field_bridge_prelude.dart';
import 'micropython_eval_control.dart';
import 'render_plane_control.dart';
import 'micropython_service.dart'
    if (dart.library.io) 'micropython_service_native.dart';

class Extension extends FletExtension {
  Extension() {
    // Register the FieldBridge prelude — installs `field` as a singleton
    // in the MicroPython global namespace, available to EScalar's
    // def render() function for setting display/color/size/etc.
    MicroPythonService.registerPrelude('field', fieldBridgePrelude);
  }

  @override
  void ensureInitialized() {
    // Fire-and-forget init — the bridge auto-inits on page load,
    // but this ensures it's ready before any control tries to eval.
    MicroPythonService.init().catchError((e) {
      debugPrint('[flet_micropython] init error: $e');
    });
  }

  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_micropython_eval":
        return MicroPythonEvalControl(key: key, control: control);
      case "render_plane":
        return RenderPlaneControl(key: key, control: control);
      default:
        return null;
    }
  }
}
