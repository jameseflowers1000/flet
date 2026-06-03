import 'package:flet/flet.dart';
import 'package:flutter/widgets.dart';

import 'pdf_capture_widget.dart';

class Extension extends FletExtension {
  @override
  Widget? createWidget(Key? key, Control control) {
    if (control.type == "flet_pdf_capture") {
      return PdfCaptureWidget(key: key, control: control);
    }
    return null;
  }
}
