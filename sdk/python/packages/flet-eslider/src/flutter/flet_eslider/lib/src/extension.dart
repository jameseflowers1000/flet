import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'einput_slider_widget.dart';

/// Per-control-id GlobalKey registry — see flet-einput/extension.dart for
/// the rationale (Flet's mount-new-before-dispose-old pattern requires
/// GlobalKey to preserve State across widget tree movements).
final Map<int, GlobalKey> _esliderKeys = {};

GlobalKey _keyFor(int id) =>
    _esliderKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'eslider_$id'));

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_eslider_input":
        return EInputSliderWidget(
          key: _keyFor(control.id),
          control: control,
        );
      default:
        return null;
    }
  }
}
