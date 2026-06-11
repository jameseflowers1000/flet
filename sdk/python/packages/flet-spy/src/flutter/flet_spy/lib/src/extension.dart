import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'spy_tutor_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_spy_tutor":
        return SpyTutorWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
