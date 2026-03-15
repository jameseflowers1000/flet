import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';

// ---------------------------------------------------------------------------
// Shared color parser — used by color, bg, glow, shadow, opacity components
// ---------------------------------------------------------------------------
Color parseColor(String value) {
  if (value.startsWith('#')) {
    final hex = value.substring(1);
    if (hex.length == 3) {
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
    case 'gold':
      return const Color(0xFFFFD700);
    case 'silver':
      return const Color(0xFFC0C0C0);
    case 'coral':
      return const Color(0xFFFF7F50);
    case 'salmon':
      return const Color(0xFFFA8072);
    case 'crimson':
      return const Color(0xFFDC143C);
    case 'magenta':
      return const Color(0xFFFF00FF);
    case 'violet':
      return const Color(0xFFEE82EE);
    case 'navy':
      return const Color(0xFF000080);
    case 'olive':
      return const Color(0xFF808000);
    case 'maroon':
      return const Color(0xFF800000);
    default:
      return const Color(0xFFFFFFFF);
  }
}

// ---------------------------------------------------------------------------
// <color=VALUE>text</color>
// ---------------------------------------------------------------------------
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
    if (match == null) return TextSpan(text: text, style: config.style);

    final color = parseColor(match.group(1)!);
    final content = match.group(2)!;
    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(color: color),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <size=VALUE>text</size>
// ---------------------------------------------------------------------------
class SizeInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<size=([0-9]+(?:\.[0-9]+)?)>(.*?)</size>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final fontSize = double.tryParse(match.group(1)!) ?? 14.0;
    final content = match.group(2)!;
    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(fontSize: fontSize),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <bg=VALUE>text</bg>  — background highlight
// ---------------------------------------------------------------------------
class BgInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<bg=(#?[a-zA-Z0-9]+)>(.*?)</bg>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final bgColor = parseColor(match.group(1)!);
    final content = match.group(2)!;
    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        backgroundColor: bgColor,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <glow=VALUE>text</glow>  — neon glow (multi-layer blur shadows, no offset)
// ---------------------------------------------------------------------------
class GlowInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<glow=(#?[a-zA-Z0-9]+)>(.*?)</glow>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final glowColor = parseColor(match.group(1)!);
    final content = match.group(2)!;
    final baseStyle = config.style ?? const TextStyle();

    // Multi-layer glow: tight core + medium halo + wide atmospheric
    // Append to existing shadows so glow + shadow can combine
    final existing = baseStyle.shadows ?? [];
    final glowShadows = [
      Shadow(color: glowColor, blurRadius: 4),
      Shadow(color: glowColor, blurRadius: 12),
      Shadow(color: glowColor, blurRadius: 24),
      Shadow(color: glowColor.withAlpha(128), blurRadius: 48),
    ];
    // Don't override text color — let <color> control that independently
    final conf = config.copyWith(
      style: baseStyle.copyWith(
        shadows: [...existing, ...glowShadows],
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <shadow=VALUE>text</shadow>  — drop shadow (offset down-right)
// ---------------------------------------------------------------------------
class ShadowInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<shadow=(#?[a-zA-Z0-9]+)>(.*?)</shadow>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final shadowColor = parseColor(match.group(1)!);
    final content = match.group(2)!;
    final baseStyle = config.style ?? const TextStyle();

    // Append to existing shadows so shadow + glow can combine
    final existing = baseStyle.shadows ?? [];
    final conf = config.copyWith(
      style: baseStyle.copyWith(
        shadows: [
          ...existing,
          Shadow(
            color: shadowColor,
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ],
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <opacity=VALUE>text</opacity>  — fade text (0.0 to 1.0)
// ---------------------------------------------------------------------------
class OpacityInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<opacity=([0-9]+(?:\.[0-9]+)?)>(.*?)</opacity>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final opacity = (double.tryParse(match.group(1)!) ?? 1.0).clamp(0.0, 1.0);
    final content = match.group(2)!;
    final baseStyle = config.style ?? const TextStyle();
    final baseColor = baseStyle.color ?? const Color(0xFFFFFFFF);

    final conf = config.copyWith(
      style: baseStyle.copyWith(
        color: baseColor.withAlpha((255 * opacity).round()),
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <font=VALUE>text</font>  — font family switch
// ---------------------------------------------------------------------------
class FontInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<font=([a-zA-Z0-9_\- ]+)>(.*?)</font>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final fontFamily = match.group(1)!.trim();
    final content = match.group(2)!;

    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        fontFamily: fontFamily,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <spacing=VALUE>text</spacing>  — letter spacing in logical pixels
// ---------------------------------------------------------------------------
class SpacingInlineComponent extends InlineMd {
  @override
  RegExp get exp =>
      RegExp(r'<spacing=([0-9]+(?:\.[0-9]+)?)>(.*?)</spacing>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final spacing = double.tryParse(match.group(1)!) ?? 0.0;
    final content = match.group(2)!;

    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        letterSpacing: spacing,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}

// ---------------------------------------------------------------------------
// <u>text</u>  — underline
// ---------------------------------------------------------------------------
class UnderlineInlineComponent extends InlineMd {
  @override
  RegExp get exp => RegExp(r'<u>(.*?)</u>', dotAll: true);

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    final match = exp.firstMatch(text);
    if (match == null) return TextSpan(text: text, style: config.style);

    final content = match.group(1)!;

    final conf = config.copyWith(
      style: (config.style ?? const TextStyle()).copyWith(
        decoration: TextDecoration.underline,
      ),
    );
    return TextSpan(
      children: MarkdownComponent.generate(context, content, conf, false),
    );
  }
}
