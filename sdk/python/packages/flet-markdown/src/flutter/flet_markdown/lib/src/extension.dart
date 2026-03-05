import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'markdown_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_markdown":
        return MarkdownWidget(key: key, control: control);
      default:
        return null;
    }
  }
}
