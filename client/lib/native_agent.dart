/// Native Dart agent for the bodyless orchestrator.
///
/// Manages conversation, tool dispatch, and LLM calls without
/// any Python or Flet server dependency.

import 'dart:convert';
import 'dart:io';

import 'llm_client.dart';
import 'generated/template_catalog.g.dart';

/// Callback for when the agent produces text or completes a tool action.
typedef AgentCallback = void Function(String role, String content);

/// Callback for actions that need CatalogScreen to respond.
typedef AgentActionCallback = void Function(String action, Map<String, dynamic> data);

class NativeAgent {
  final LlmClient llmClient;
  final AgentCallback onMessage;
  final AgentActionCallback onAction;

  final List<LlmMessage> _conversationHistory = [];
  List<Map<String, dynamic>> _docletContext = [];
  List<String> _docletPaths = [];
  bool _processing = false;

  NativeAgent({
    required this.llmClient,
    required this.onMessage,
    required this.onAction,
  });

  bool get isProcessing => _processing;

  /// Update the doclet context (called when catalog rescans).
  void updateDocletContext(List<Map<String, dynamic>> doclets) {
    _docletContext = doclets;
  }

  /// Update the list of doclet search paths.
  void updateDocletPaths(List<String> paths) {
    _docletPaths = paths;
  }

  /// Send a user message and get the agent's response.
  Future<void> sendMessage(String userText) async {
    if (_processing || !llmClient.isAvailable) return;
    _processing = true;

    _conversationHistory.add(LlmMessage(role: 'user', content: userText));

    try {
      await _runAgentLoop();
    } catch (e) {
      onMessage('assistant', 'Sorry, I encountered an error: $e');
    } finally {
      _processing = false;
    }
  }

  Future<void> _runAgentLoop() async {
    const maxIterations = 10;

    for (int i = 0; i < maxIterations; i++) {
      final response = await llmClient.sendMessage(
        _conversationHistory,
        systemPrompt: _buildSystemPrompt(),
        tools: _toolDefinitions,
      );

      // Add assistant text to conversation
      if (response.text != null && response.text!.isNotEmpty) {
        onMessage('assistant', response.text!);
      }

      // If there are tool calls, process them
      if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
        // Add the assistant message with tool calls to history
        for (final toolCall in response.toolCalls!) {
          _conversationHistory.add(LlmMessage(
            role: 'assistant',
            content: response.text ?? '',
            toolUseId: toolCall.id,
            toolName: toolCall.name,
            toolArguments: toolCall.arguments,
          ));

          // Execute the tool
          final result = await _executeTool(toolCall);

          // Add tool result to history
          _conversationHistory.add(LlmMessage(
            role: 'tool_result',
            content: result,
            toolUseId: toolCall.id,
          ));
        }
        // Continue loop to let LLM process tool results
        continue;
      }

      // No tool calls — add the final text response to history and stop
      if (response.text != null && response.text!.isNotEmpty) {
        _conversationHistory.add(LlmMessage(
          role: 'assistant',
          content: response.text!,
        ));
      }
      break;
    }
  }

  String _buildSystemPrompt() {
    final templateList = kTemplateCatalog
        .map((t) =>
            '- **${t.name}**: ${t.description} (${t.numPanes} panes: ${t.slotNames.join(", ")}). Best for: ${t.bestFor}${t.isFavorite ? " [DEFAULT]" : ""}')
        .join('\n');

    final docletList = _docletContext.isEmpty
        ? 'No doclets found.'
        : _docletContext
            .map((d) =>
                '- "${d["name"]}" (template: ${d["template"]}, modified: ${d["modified"] ?? "unknown"})')
            .join('\n');

    final pathList = _docletPaths.isEmpty
        ? 'Default location only.'
        : _docletPaths.map((p) => '- $p').join('\n');

    return '''You are the Epyx assistant, running natively in the desktop app (no container, no Python).
You help users choose templates, browse doclets, and create new documents.

## Available Templates
$templateList

## Current Doclets
$docletList

## Doclet Search Locations
$pathList

## What you CAN do
- Suggest which template to use based on the user's description
- Explain what each template offers (slot layout, pane structure)
- Help users browse and find doclets by description
- Answer general questions about Epyx
- Create a new doclet via the create_doclet tool
- Open an existing doclet by name
- Manage doclet search locations (add/remove folders)
- Save/dump the conversation to a file

## What you CANNOT do (needs a running container)
- Execute formulas or code
- Modify document properties
- Run the REPL or terminal
- Edit in neovim

## Guidelines
- Be concise and helpful
- When suggesting templates, explain WHY a template fits the user's needs
- If the user describes what they want to build, suggest a specific template
- When creating a doclet, confirm the template and name with the user first
- Use markdown formatting in your responses''';
  }

  Future<String> _executeTool(ToolCall toolCall) async {
    switch (toolCall.name) {
      case 'list_templates':
        return _toolListTemplates();
      case 'suggest_template':
        return _toolSuggestTemplate(toolCall.arguments);
      case 'explain_template':
        return _toolExplainTemplate(toolCall.arguments);
      case 'search_doclets':
        return _toolSearchDoclets(toolCall.arguments);
      case 'create_doclet':
        return await _toolCreateDoclet(toolCall.arguments);
      case 'list_doclet_locations':
        return _toolListDocletLocations();
      case 'add_doclet_location':
        return await _toolAddDocletLocation(toolCall.arguments);
      case 'remove_doclet_location':
        return await _toolRemoveDocletLocation(toolCall.arguments);
      case 'open_doclet':
        return _toolOpenDoclet(toolCall.arguments);
      case 'dump_conversation':
        return await _toolDumpConversation(toolCall.arguments);
      default:
        return 'Unknown tool: ${toolCall.name}';
    }
  }

  String _toolListTemplates() {
    final items = kTemplateCatalog.map((t) => {
          'name': t.name,
          'description': t.description,
          'numPanes': t.numPanes,
          'slotNames': t.slotNames,
          'bestFor': t.bestFor,
          'isFavorite': t.isFavorite,
        });
    return jsonEncode(items.toList());
  }

  String _toolSuggestTemplate(Map<String, dynamic> args) {
    final description = (args['description'] as String? ?? '').toLowerCase();

    final scored = <Map<String, dynamic>>[];
    for (final t in kTemplateCatalog) {
      int score = 0;
      final combined =
          '${t.description} ${t.bestFor} ${t.slotNames.join(" ")}'.toLowerCase();

      for (final word in description.split(' ')) {
        if (word.length > 2 && combined.contains(word)) score += 2;
      }

      if (description.contains('chart') || description.contains('plot') || description.contains('graph')) {
        if (t.name.toLowerCase().contains('chart') ||
            t.slotNames.any((s) => s.contains('chart'))) {
          score += 5;
        }
      }
      if (description.contains('simple') || description.contains('basic')) {
        if (t.name.toLowerCase().contains('simple') || t.numPanes <= 2) {
          score += 3;
        }
      }
      if (description.contains('tab')) {
        if (t.name.toLowerCase().contains('tab')) score += 5;
      }
      if (description.contains('grid') || description.contains('card') || description.contains('dashboard')) {
        if (t.name.toLowerCase().contains('grid')) score += 5;
      }
      if (description.contains('quad') || description.contains('four') || description.contains('4')) {
        if (t.name.toLowerCase().contains('quad')) score += 5;
      }
      if (description.contains('sidebar') || description.contains('side bar')) {
        if (t.name.toLowerCase().contains('sidebar') ||
            t.name.toLowerCase().contains('focus')) {
          score += 5;
        }
      }
      if (description.contains('report') || description.contains('document')) {
        if (t.name.toLowerCase().contains('stacked')) score += 5;
      }

      if (t.isFavorite) score += 1;

      scored.add({
        'name': t.name,
        'description': t.description,
        'bestFor': t.bestFor,
        'score': score,
        'numPanes': t.numPanes,
        'slotNames': t.slotNames,
      });
    }

    scored.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    return jsonEncode(scored.take(3).toList());
  }

  String _toolExplainTemplate(Map<String, dynamic> args) {
    final name = args['name'] as String? ?? '';
    final template = kTemplateCatalog.where(
        (t) => t.name.toLowerCase() == name.toLowerCase());

    if (template.isEmpty) {
      return 'Template "$name" not found. Available: ${kTemplateCatalog.map((t) => t.name).join(", ")}';
    }

    final t = template.first;
    final slotDetails = t.slots.map((s) {
      final parts = <String>['name: ${s["name"]}'];
      if (s['preferred_usages'] != null) {
        parts.add('usages: ${(s["preferred_usages"] as List).join(", ")}');
      }
      if (s['preferred_roles'] != null) {
        parts.add('roles: ${(s["preferred_roles"] as List).join(", ")}');
      }
      return '{${parts.join(", ")}}';
    }).join('\n  ');

    return jsonEncode({
      'name': t.name,
      'description': t.description,
      'numPanes': t.numPanes,
      'bestFor': t.bestFor,
      'isFavorite': t.isFavorite,
      'slots': slotDetails,
    });
  }

  String _toolSearchDoclets(Map<String, dynamic> args) {
    final query = (args['query'] as String? ?? '').toLowerCase();
    final matches = _docletContext.where((d) {
      final name = (d['name'] as String? ?? '').toLowerCase();
      final template = (d['template'] as String? ?? '').toLowerCase();
      final desc = (d['description'] as String? ?? '').toLowerCase();
      return name.contains(query) ||
          template.contains(query) ||
          desc.contains(query);
    }).toList();

    if (matches.isEmpty) {
      return 'No doclets match "$query".';
    }
    return jsonEncode(matches);
  }

  Future<String> _toolCreateDoclet(Map<String, dynamic> args) async {
    final name = args['name'] as String? ?? '';
    final template = args['template'] as String? ?? '';
    final description = args['description'] as String? ?? '';
    final creationContext = args['creation_context'] as String? ?? '';
    final greeting = args['greeting'] as String? ?? '';

    if (name.isEmpty || template.isEmpty) {
      return 'Error: both name and template are required.';
    }

    if (!kTemplateCatalog.any(
        (t) => t.name.toLowerCase() == template.toLowerCase())) {
      return 'Error: unknown template "$template". Available: ${kTemplateCatalog.map((t) => t.name).join(", ")}';
    }

    final eddPath = _findEdd();
    if (eddPath == null) {
      return 'Error: edd command not found on PATH or in ~/bin.';
    }

    try {
      final cmdArgs = ['create', '--template', template];
      if (description.isNotEmpty) {
        cmdArgs.addAll(['--desc', description]);
      }
      cmdArgs.add(name);
      final result = await Process.run(eddPath, cmdArgs);
      if (result.exitCode == 0) {
        // Write the creation conversation as the first session in the new doclet,
        // using the same format as ConversationStore (conversation.py).
        _writeCreationSession(name, creationContext, greeting);
        onAction('doclet_created', {'name': name, 'template': template});
        return 'Successfully created doclet "$name" with template "$template".';
      } else {
        return 'Error creating doclet: ${result.stderr}';
      }
    } catch (e) {
      return 'Error running edd create: $e';
    }
  }

  String _toolListDocletLocations() {
    return jsonEncode(_docletPaths);
  }

  Future<String> _toolAddDocletLocation(Map<String, dynamic> args) async {
    final path = args['path'] as String? ?? '';
    if (path.isEmpty) return 'Error: path is required.';

    final expandedPath = path.startsWith('~')
        ? path.replaceFirst('~', Platform.environment['HOME'] ?? '')
        : path;

    final dir = Directory(expandedPath);
    if (!dir.existsSync()) {
      return 'Error: directory "$expandedPath" does not exist.';
    }

    if (_docletPaths.contains(expandedPath)) {
      return '"$expandedPath" is already a search location.';
    }

    _saveDocletPaths([..._docletPaths, expandedPath]);
    onAction('doclet_paths_changed', {'paths': [..._docletPaths, expandedPath]});
    return 'Added "$expandedPath" as a doclet search location.';
  }

  Future<String> _toolRemoveDocletLocation(Map<String, dynamic> args) async {
    final path = args['path'] as String? ?? '';
    if (path.isEmpty) return 'Error: path is required.';

    final expandedPath = path.startsWith('~')
        ? path.replaceFirst('~', Platform.environment['HOME'] ?? '')
        : path;

    if (!_docletPaths.contains(expandedPath)) {
      return '"$expandedPath" is not in the search locations. Current: ${_docletPaths.join(", ")}';
    }

    if (_docletPaths.length <= 1) {
      return 'Cannot remove the last search location.';
    }

    final newPaths = _docletPaths.where((p) => p != expandedPath).toList();
    _saveDocletPaths(newPaths);
    onAction('doclet_paths_changed', {'paths': newPaths});
    return 'Removed "$expandedPath" from doclet search locations.';
  }

  void _saveDocletPaths(List<String> paths) {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      String configPath;
      if (Platform.isMacOS) {
        configPath = '$home/Library/Application Support/Epyx/config.yaml';
      } else if (Platform.isLinux) {
        final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
        configPath = '$xdg/epyx/config.yaml';
      } else {
        return;
      }

      final file = File(configPath);
      file.parent.createSync(recursive: true);

      String content = file.existsSync() ? file.readAsStringSync() : '';
      final lines = content.split('\n');
      final newLines = <String>[];
      bool inStorage = false;
      bool inDocletPaths = false;
      bool wroteDocletPaths = false;

      for (final line in lines) {
        if (line.startsWith('storage:')) {
          inStorage = true;
          newLines.add(line);
          continue;
        }
        if (inStorage &&
            !line.startsWith(' ') &&
            !line.startsWith('\t') &&
            line.isNotEmpty) {
          if (!wroteDocletPaths) {
            _writeDocletPathsYaml(newLines, paths);
            wroteDocletPaths = true;
          }
          inStorage = false;
        }
        if (inStorage && line.trim().startsWith('doclet_paths:')) {
          inDocletPaths = true;
          _writeDocletPathsYaml(newLines, paths);
          wroteDocletPaths = true;
          continue;
        }
        if (inDocletPaths) {
          if (line.trim().startsWith('- ')) {
            continue; // Skip old list items
          }
          inDocletPaths = false;
        }
        newLines.add(line);
      }

      if (!wroteDocletPaths) {
        if (!lines.any((l) => l.startsWith('storage:'))) {
          newLines.add('storage:');
        }
        _writeDocletPathsYaml(newLines, paths);
      }

      file.writeAsStringSync(newLines.join('\n'));
    } catch (_) {
      // Best effort
    }
  }

  void _writeDocletPathsYaml(List<String> lines, List<String> paths) {
    lines.add('  doclet_paths:');
    for (final p in paths) {
      lines.add('  - $p');
    }
  }

  /// Write the bodyless creation conversation as the first session in the
  /// new doclet's .meta/conversations/ — same JSON format as ConversationStore.
  /// Tagged "creation" so the in-document orchestrator can identify it.
  void _writeCreationSession(String docletName, String creationContext, String greeting) {
    try {
      // Find the doclet directory — scan all doclet paths for a match
      String? docletPath;
      for (final searchPath in _docletPaths) {
        final dir = Directory(searchPath);
        if (!dir.existsSync()) continue;
        for (final entity in dir.listSync()) {
          if (entity is Directory) {
            final manifest = File('${entity.path}/manifest.json');
            if (manifest.existsSync()) {
              final data = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
              if (data['name'] == docletName) {
                docletPath = entity.path;
                break;
              }
            }
          }
        }
        if (docletPath != null) break;
      }
      if (docletPath == null) return;

      final convDir = Directory('$docletPath/.meta/conversations');
      convDir.createSync(recursive: true);

      final now = DateTime.now().toUtc().toIso8601String();
      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:T.]'), '').substring(0, 14);
      final sessionId = 'sess_${ts}_0000';

      // Build messages from conversation history — user and assistant only
      final messages = <Map<String, dynamic>>[];
      for (final msg in _conversationHistory) {
        if (msg.role == 'user' || (msg.role == 'assistant' && msg.toolName == null)) {
          messages.add({
            'role': msg.role,
            'content': msg.content,
            'ts': now,
          });
        }
      }

      // Add the creation_context as a summary if provided
      final session = {
        'session_id': sessionId,
        'started_at': now,
        'ended_at': now,
        'messages': messages,
        'summary': creationContext.isNotEmpty ? creationContext : null,
        'greeting': greeting.isNotEmpty ? greeting : null,
        'tags': ['creation'],
      };

      final sessionFile = File('${convDir.path}/$sessionId.json');
      sessionFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(session));
    } catch (_) {
      // Best effort — don't fail the create if this doesn't work
    }
  }

  String? _findEdd() {
    final result = Process.runSync('which', ['edd']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
    final home = Platform.environment['HOME'] ?? '';
    final homeBin = '$home/bin/edd';
    if (File(homeBin).existsSync()) return homeBin;
    return null;
  }

  String _toolOpenDoclet(Map<String, dynamic> args) {
    final name = args['name'] as String? ?? '';
    if (name.isEmpty) return 'Error: name is required.';

    // Find the doclet in our context
    final match = _docletContext.where(
        (d) => (d['name'] as String? ?? '').toLowerCase() == name.toLowerCase());
    if (match.isEmpty) {
      return 'Error: doclet "$name" not found.';
    }

    onAction('open_doclet', match.first);
    return 'Opening doclet "$name"...';
  }

  Future<String> _toolDumpConversation(Map<String, dynamic> args) async {
    final path = args['path'] as String? ?? '';

    // Build readable transcript from messages shown to user
    final buf = StringBuffer();
    buf.writeln('# Epyx Orchestrator Conversation');
    buf.writeln('# ${DateTime.now().toIso8601String()}');
    buf.writeln();

    // Include the full LLM conversation history (has tool calls too)
    for (final msg in _conversationHistory) {
      if (msg.role == 'user') {
        buf.writeln('> **User**: ${msg.content}');
        buf.writeln();
      } else if (msg.role == 'assistant' && msg.toolName == null) {
        buf.writeln('**Assistant**: ${msg.content}');
        buf.writeln();
      } else if (msg.role == 'assistant' && msg.toolName != null) {
        buf.writeln('_[tool_use: ${msg.toolName}(${jsonEncode(msg.toolArguments)})]_');
        buf.writeln();
      } else if (msg.role == 'tool_result') {
        final preview = msg.content.length > 200
            ? '${msg.content.substring(0, 200)}...'
            : msg.content;
        buf.writeln('_[tool_result: $preview]_');
        buf.writeln();
      }
    }

    // Determine output path
    String outputPath;
    if (path.isNotEmpty) {
      outputPath = path.startsWith('~')
          ? path.replaceFirst('~', Platform.environment['HOME'] ?? '')
          : path;
    } else {
      final home = Platform.environment['HOME'] ?? '/tmp';
      outputPath = '$home/epyx-conversation-${DateTime.now().millisecondsSinceEpoch}.md';
    }

    try {
      final file = File(outputPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(buf.toString());
      return 'Conversation saved to $outputPath';
    } catch (e) {
      return 'Error saving conversation: $e';
    }
  }

  void clearHistory() {
    _conversationHistory.clear();
  }

  // ── Tool Definitions ────────────────────────────────────────────────

  static final _toolDefinitions = <ToolDefinition>[
    const ToolDefinition(
      name: 'list_templates',
      description: 'List all available document templates with descriptions.',
      inputSchema: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
    ),
    const ToolDefinition(
      name: 'suggest_template',
      description:
          'Suggest the best template(s) for a user\'s described use case. Returns top 3 matches.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'description': {
            'type': 'string',
            'description': 'What the user wants to build',
          },
        },
        'required': ['description'],
      },
    ),
    const ToolDefinition(
      name: 'explain_template',
      description:
          'Get detailed information about a specific template including slot layout.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Template name (e.g., "Simple-Three-Pane")',
          },
        },
        'required': ['name'],
      },
    ),
    const ToolDefinition(
      name: 'search_doclets',
      description: 'Search existing doclets by name, template, or description.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search query',
          },
        },
        'required': ['query'],
      },
    ),
    const ToolDefinition(
      name: 'create_doclet',
      description:
          'Create a new doclet with the given name and template. Confirm with the user before calling. Always include description, creation_context, and greeting.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Name for the new doclet',
          },
          'template': {
            'type': 'string',
            'description': 'Template name to use',
          },
          'description': {
            'type': 'string',
            'description': 'Brief description of the doclet based on the conversation (e.g. "Table for entering and reconciling values")',
          },
          'creation_context': {
            'type': 'string',
            'description': 'Factual summary of what the user wants to build, for the in-document agent system prompt. Include requirements, decisions made, and template choice rationale.',
          },
          'greeting': {
            'type': 'string',
            'description': 'A warm, natural greeting for the user when they first open this doclet. Address them directly, reference what they want to build, and offer to help. E.g. "Hi! I see you need a table for reconciliation. Would you like me to help you set that up?"',
          },
        },
        'required': ['name', 'template'],
      },
    ),
    const ToolDefinition(
      name: 'list_doclet_locations',
      description: 'List all directories being scanned for doclets.',
      inputSchema: {
        'type': 'object',
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
    ),
    const ToolDefinition(
      name: 'add_doclet_location',
      description:
          'Add a new directory to scan for doclets. The directory must exist.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to directory',
          },
        },
        'required': ['path'],
      },
    ),
    const ToolDefinition(
      name: 'remove_doclet_location',
      description:
          'Remove a directory from the doclet search locations.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Path to remove',
          },
        },
        'required': ['path'],
      },
    ),
    const ToolDefinition(
      name: 'open_doclet',
      description: 'Open an existing doclet by name. Use this when the user asks to open a doclet.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': 'Name of the doclet to open',
          },
        },
        'required': ['name'],
      },
    ),
    const ToolDefinition(
      name: 'dump_conversation',
      description:
          'Save the full conversation transcript to a file. The user may ask to "save this conversation" or "dump the chat".',
      inputSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Output file path (optional — defaults to ~/epyx-conversation-<timestamp>.md)',
          },
        },
        'required': <String>[],
      },
    ),
  ];
}
