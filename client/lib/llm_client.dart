/// Abstract LLM interface for the native bodyless agent.
///
/// Allows Claude to be swapped for another LLM provider without
/// touching agent logic.

/// A single message in a conversation.
class LlmMessage {
  final String role; // 'user', 'assistant', 'tool_use', 'tool_result'
  final String content;
  final String? toolUseId;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;

  const LlmMessage({
    required this.role,
    required this.content,
    this.toolUseId,
    this.toolName,
    this.toolArguments,
  });

  Map<String, dynamic> toJson() {
    if (role == 'tool_result') {
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': toolUseId,
            'content': content,
          }
        ],
      };
    }
    if (role == 'assistant' && toolName != null) {
      // Assistant message with tool_use block
      final blocks = <Map<String, dynamic>>[];
      if (content.isNotEmpty) {
        blocks.add({'type': 'text', 'text': content});
      }
      blocks.add({
        'type': 'tool_use',
        'id': toolUseId,
        'name': toolName,
        'input': toolArguments ?? {},
      });
      return {'role': 'assistant', 'content': blocks};
    }
    return {'role': role, 'content': content};
  }
}

/// Response from the LLM.
class LlmResponse {
  final String? text;
  final List<ToolCall>? toolCalls;
  final String? stopReason;

  const LlmResponse({this.text, this.toolCalls, this.stopReason});
}

/// A tool call requested by the LLM.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// Definition of a tool the LLM can call.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
}

/// Abstract LLM client interface.
abstract class LlmClient {
  /// Send a conversation to the LLM and get a response.
  Future<LlmResponse> sendMessage(
    List<LlmMessage> messages, {
    String? systemPrompt,
    List<ToolDefinition>? tools,
  });

  /// Whether the client has valid credentials configured.
  bool get isAvailable;
}
