import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'vim_editor_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "vim_editor":
        return VimEditorFletWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
