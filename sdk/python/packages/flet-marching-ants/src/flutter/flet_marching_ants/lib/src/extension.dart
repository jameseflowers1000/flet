import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'marching_ants_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_marching_ants":
        return MarchingAntsWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
