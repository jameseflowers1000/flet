import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'flet_supertab_control.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_supertab":
        return SuperTabControl(control: control);
      default:
        return null;
    }
  }
}
