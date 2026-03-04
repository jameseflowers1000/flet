import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'thumbnail_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    if (control.type == "flet_thumbnail") {
      return ThumbnailWidget(key: key, control: control);
    }
    return null;
  }
}
