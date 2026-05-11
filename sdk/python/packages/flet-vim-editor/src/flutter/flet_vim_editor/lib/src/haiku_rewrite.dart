// `??` line + Enter → call Claude Haiku to replace the line with α
// code that does what the user described. Triggered by both editors:
//   - EZ: NativeEditor's outer Focus catches Enter, checks if the
//     current line starts with `??`, runs the rewrite if so.
//   - Vim: NvimView's _onKeyEvent catches `<CR>`, same check via
//     RPC into nvim's current line.
//
// API: standard Anthropic /v1/messages with claude-haiku-4-5.
// API key from ANTHROPIC_API_KEY in the process env (Platform.environment
// on macOS desktop). Failures surface as a brief toast; no crash.
//
// Output convention: Haiku is asked to return ONLY α-canonical Python,
// no fences, no commentary. The model is given a slim schema slice
// (the master `the.*` paths) so it produces canonical bridge calls.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

const _kModel = 'claude-haiku-4-5';
const _kMaxTokens = 600;
const _kMagicPrefix = '??';

const String _kSystemPrompt = '''
You are an inline code-completion assistant for the Epyx-EDD α
paradigm. The user has typed a line that starts with `??` followed
by a natural-language description of what they want. Replace that
line with one or more lines of canonical α Python that fulfills the
request.

Rules:
- Output ONLY code, no markdown fences, no commentary, no leading
  or trailing newlines.
- Use the canonical α master bridge `the.*` (NOT `the.field.*`,
  `the.cell.*`, etc — those are deprecated).
- Common bridge surface includes:
    the.value          # current value (read/write)
    the.display = …    # formatted display string (read/write)
    the.color, the.bg, the.size, the.italic, the.underline, the.weight
    the.is_focused, the.is_editing, the.is_hovered, the.is_selected
    the.key            # last key pressed (in on_key blocks)
    the.keys           # named-key constants: the.keys.enter, .escape,
                       #   .arrow_up, .arrow_down, .arrow_left,
                       #   .arrow_right, .tab, .backspace
    the.modifiers      # set of currently-held modifiers
    the.beep(), the.banner('msg', level='info'|'warn'|'error')
    the.replace(text), the.commit(), the.cancel(), the.select_all()
- Doc-level free names in the namespace can be referenced by bare
  identifier (e.g. `principal`, `rate`).
- Indent with 4 spaces. Do not include the original `??` line in the
  output.
''';

class HaikuRewrite {
  /// Returns the (possibly multi-line) replacement code for the
  /// `??`-line `requestLine`. Strips the leading `??` plus any single
  /// space. Returns null on any failure (network, no key, parse).
  static Future<String?> rewriteLine(String requestLine) async {
    final apiKey = Platform.environment['ANTHROPIC_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      debugPrint('[haiku] ANTHROPIC_API_KEY not set in environment');
      return null;
    }
    var prompt = requestLine.trim();
    if (prompt.startsWith(_kMagicPrefix)) {
      prompt = prompt.substring(_kMagicPrefix.length).trimLeft();
    }
    if (prompt.isEmpty) return null;
    final body = {
      'model': _kModel,
      'max_tokens': _kMaxTokens,
      'system': _kSystemPrompt,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    };
    try {
      final client = HttpClient();
      final req = await client.postUrl(
          Uri.parse('https://api.anthropic.com/v1/messages'));
      req.headers.set('content-type', 'application/json');
      req.headers.set('x-api-key', apiKey);
      req.headers.set('anthropic-version', '2023-06-01');
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close();
      final raw = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) {
        debugPrint('[haiku] HTTP ${resp.statusCode}: $raw');
        return null;
      }
      final j = jsonDecode(raw);
      // Standard Anthropic shape: { content: [{type:"text", text:"…"}] }
      final content = j['content'];
      if (content is! List) return null;
      final buf = StringBuffer();
      for (final block in content) {
        if (block is Map && block['type'] == 'text' && block['text'] is String) {
          buf.write(block['text']);
        }
      }
      var text = buf.toString();
      // Defensive: strip any accidental code fences.
      text = text.trim();
      if (text.startsWith('```')) {
        final firstNl = text.indexOf('\n');
        if (firstNl > 0) text = text.substring(firstNl + 1);
        if (text.endsWith('```')) {
          text = text.substring(0, text.length - 3);
        }
        text = text.trim();
      }
      return text;
    } catch (e) {
      debugPrint('[haiku] error: $e');
      return null;
    }
  }

  /// True iff `line` is a "?? please …" magic-prefix line worth a
  /// rewrite. Strip leading whitespace before checking so indented
  /// `??` requests still trigger.
  static bool isMagicLine(String line) {
    final trimmed = line.trimLeft();
    return trimmed.startsWith(_kMagicPrefix);
  }
}
