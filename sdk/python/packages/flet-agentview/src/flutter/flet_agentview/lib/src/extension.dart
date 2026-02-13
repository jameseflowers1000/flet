import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'agentview_control.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_agentview":
        return AgentViewControl(key: key, control: control);
      default:
        return null;
    }
  }
}
