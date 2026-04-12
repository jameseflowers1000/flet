/// Debug logger for desktop — writes to /tmp/superplot_debug.log.
import 'dart:io';

void superplotLog(String msg) {
  print(msg);
  try {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    File('/tmp/superplot_debug.log').writeAsStringSync(
      '$ts $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}
