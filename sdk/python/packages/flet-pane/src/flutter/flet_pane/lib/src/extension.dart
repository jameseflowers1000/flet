import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'pane_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_pane":
        return PaneWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
