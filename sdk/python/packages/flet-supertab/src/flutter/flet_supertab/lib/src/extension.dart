import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'epyx_grid.dart';

class Extension extends FletExtension {
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
