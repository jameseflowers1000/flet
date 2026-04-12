import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'einput_text_widget.dart';

/// Per-control-id GlobalKey registry. Critical for preserving widget State
/// across widget tree movements.
///
/// ValueKey is sufficient when a widget stays at the same position in the
/// tree across rebuilds, but for our use case Flet's ContainerControl /
/// ControlInheritedNotifier dance can effectively move the widget into a
/// new subtree (mount-new-before-dispose-old) when properties update.
/// Under that pattern, only a GlobalKey will preserve the State (and with
/// it, our FocusNode + TextEditingController + in-flight typing).
final Map<int, GlobalKey> _einputKeys = {};

GlobalKey _keyFor(int id) => _einputKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'einput_$id'));

/// Flet extension for flet-einput.
///
/// Registers the EInputText custom widget. The MicroPython `field` prelude
/// is already registered by the flet-micropython extension, so we don't
/// need to install anything here — we just consume the existing render plane
/// projection registry via [RenderPlaneControl.getProjection].
class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    switch (control.type) {
      case "flet_einput_text":
        // Always use a per-control-id GlobalKey. See _einputKeys above.
        return EInputTextWidget(
          key: _keyFor(control.id),
          control: control,
        );
      default:
        return null;
    }
  }
}
