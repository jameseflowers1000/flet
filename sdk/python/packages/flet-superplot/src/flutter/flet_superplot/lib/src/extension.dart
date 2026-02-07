import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'superplot_control.dart';

class Extension extends FletExtension {
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
