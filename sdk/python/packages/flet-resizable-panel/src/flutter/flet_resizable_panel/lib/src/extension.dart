import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'resizable_panel_control.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "resizable_panel":
        return ResizablePanelControl(key: key, control: control);
      default:
        return null;
    }
  }
}
