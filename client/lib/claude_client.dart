/// Claude API implementation of LlmClient.
///
/// HTTP POST to https://api.anthropic.com/v1/messages with tool calling.

import 'dart:convert';
import 'dart:io';

import 'llm_client.dart';

class ClaudeClient implements LlmClient {
  final String apiKey;
  final String model;
  final HttpClient _httpClient = HttpClient();

  ClaudeClient({
    required this.apiKey,
    this.model = 'claude-sonnet-4-5-20250929',
  });

  @override
  bool get isAvailable => apiKey.isNotEmpty;

  @override
  Future<LlmResponse> sendMessage(
    List<LlmMessage> messages, {
    String? systemPrompt,
    List<ToolDefinition>? tools,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 4096,
      'messages': messages.map((m) => m.toJson()).toList(),
    };

    if (systemPrompt != null) {
      body['system'] = systemPrompt;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toJson()).toList();
    }

    final request = await _httpClient.postUrl(
      Uri.parse('https://api.anthropic.com/v1/messages'),
    );
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('x-api-key', apiKey);
    request.headers.set('anthropic-version', '2023-06-01');
    request.add(utf8.encode(jsonEncode(body)));

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode != 200) {
      throw Exception(
          'Claude API error ${response.statusCode}: $responseBody');
    }

    final data = jsonDecode(responseBody) as Map<String, dynamic>;
    return _parseResponse(data);
  }

  LlmResponse _parseResponse(Map<String, dynamic> data) {
    final content = data['content'] as List<dynamic>? ?? [];
    final stopReason = data['stop_reason'] as String?;

    String? text;
    final toolCalls = <ToolCall>[];

    for (final block in content) {
      final blockMap = block as Map<String, dynamic>;
      final type = blockMap['type'] as String;

      if (type == 'text') {
        text = (text ?? '') + (blockMap['text'] as String);
      } else if (type == 'tool_use') {
        toolCalls.add(ToolCall(
          id: blockMap['id'] as String,
          name: blockMap['name'] as String,
          arguments: blockMap['input'] as Map<String, dynamic>? ?? {},
        ));
      }
    }

    return LlmResponse(
      text: text,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      stopReason: stopReason,
    );
  }
}
