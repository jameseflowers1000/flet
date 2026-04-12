import 'package:flet/flet.dart';
import 'package:flet_micropython/flet_micropython.dart';
import 'package:flutter/widgets.dart';

import 'chart_bridge_prelude.dart';
import 'superplot_control.dart';

class Extension extends FletExtension {
  Extension() {
    // Register the ChartBridge prelude with the shared MicroPython
    // service. The bridge becomes a singleton named `chart` in the
    // MicroPython global namespace, available to every render function
    // evaluation. The prelude is loaded once MicroPython init completes.
    MicroPythonService.registerPrelude('chart', chartBridgePrelude);
  }

  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_superplot":
        return SuperPlotControl(key: key, control: control);
      default:
        return null;
    }
  }
}
