import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'window_manager_widget.dart';
import 'floating_window_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "window_manager":
        return WindowManagerWidget(key: key, control: control);
      case "floating_window":
        return FloatingWindowWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
