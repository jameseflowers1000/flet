import 'package:flet/flet.dart';
import 'package:flet_micropython/flet_micropython.dart';
import 'package:flutter/widgets.dart';

import 'cell_bridge_prelude.dart';
import 'epyx_grid.dart';

class Extension extends FletExtension {
  Extension() {
    // Register the CellBridge prelude — installs `cell` as a singleton
    // in the MicroPython global namespace, available to ETab's
    // def render() function for per-cell formatting.
    MicroPythonService.registerPrelude('cell', cellBridgePrelude);
  }

  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_supertab":
        return EpyxGrid(control: control);
      default:
        return null;
    }
  }
}
