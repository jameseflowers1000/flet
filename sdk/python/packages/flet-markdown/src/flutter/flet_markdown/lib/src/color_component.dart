import 'package:flutter/widgets.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';

/// Custom inline component that parses <color=VALUE>text</color> syntax.
///
/// Supports named colors (red, green, blue, etc.) and hex colors (#FF6B00, #f00).
class ColorInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<color=(#?[a-zA-Z0-9]+)>(.*?)</color>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) {
      return TextSpan(text: text, style: config.style);
    }

    final colorValue = match.group(1)!;
    final content = match.group(2)!;
    final color = _parseColor(colorValue);

    final style = (config.style ?? const TextStyle()).copyWith(color: color);

    // Recursively process the inner content for nested markdown
    return TextSpan(text: content, style: style);
  }

  static Color _parseColor(String value) {
    // Hex color
    if (value.startsWith('#')) {
      final hex = value.substring(1);
      if (hex.length == 3) {
        // Short hex (#f00 -> #ff0000)
        final r = int.parse(hex[0] + hex[0], radix: 16);
        final g = int.parse(hex[1] + hex[1], radix: 16);
        final b = int.parse(hex[2] + hex[2], radix: 16);
        return Color.fromARGB(255, r, g, b);
      } else if (hex.length == 6) {
        final r = int.parse(hex.substring(0, 2), radix: 16);
        final g = int.parse(hex.substring(2, 4), radix: 16);
        final b = int.parse(hex.substring(4, 6), radix: 16);
        return Color.fromARGB(255, r, g, b);
      } else if (hex.length == 8) {
        final a = int.parse(hex.substring(0, 2), radix: 16);
        final r = int.parse(hex.substring(2, 4), radix: 16);
        final g = int.parse(hex.substring(4, 6), radix: 16);
        final b = int.parse(hex.substring(6, 8), radix: 16);
        return Color.fromARGB(a, r, g, b);
      }
    }

    // Named colors
    switch (value.toLowerCase()) {
      case 'red':
        return const Color(0xFFFF0000);
      case 'green':
        return const Color(0xFF00FF00);
      case 'blue':
        return const Color(0xFF0000FF);
      case 'yellow':
        return const Color(0xFFFFFF00);
      case 'orange':
        return const Color(0xFFFF9800);
      case 'purple':
        return const Color(0xFF9C27B0);
      case 'pink':
        return const Color(0xFFE91E63);
      case 'cyan':
        return const Color(0xFF00BCD4);
      case 'white':
        return const Color(0xFFFFFFFF);
      case 'black':
        return const Color(0xFF000000);
      case 'grey':
      case 'gray':
        return const Color(0xFF9E9E9E);
      case 'teal':
        return const Color(0xFF009688);
      case 'amber':
        return const Color(0xFFFFC107);
      case 'indigo':
        return const Color(0xFF3F51B5);
      case 'lime':
        return const Color(0xFFCDDC39);
      case 'brown':
        return const Color(0xFF795548);
      default:
        return const Color(0xFFFFFFFF); // fallback to white
    }
  }
}
