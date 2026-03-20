/// API key resolution with fallback chain.
///
/// 1. ANTHROPIC_API_KEY environment variable
/// 2. ~/Library/Application Support/Epyx/config.yaml → ai.anthropic_api_key
/// 3. null (triggers first-run dialog in UI)

import 'dart:io';

String? resolveApiKey() {
  // 1. Environment variable
  final envKey = Platform.environment['ANTHROPIC_API_KEY'];
  if (envKey != null && envKey.isNotEmpty) return envKey;

  // 2. Config file
  final configKey = _readFromConfig();
  if (configKey != null && configKey.isNotEmpty) return configKey;

  return null;
}

String? _readFromConfig() {
  try {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return null;

    String configPath;
    if (Platform.isMacOS) {
      configPath = '$home/Library/Application Support/Epyx/config.yaml';
    } else if (Platform.isLinux) {
      final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
      configPath = '$xdg/epyx/config.yaml';
    } else if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      configPath = '$appData\\Epyx\\config.yaml';
    } else {
      return null;
    }

    final file = File(configPath);
    if (!file.existsSync()) return null;

    // Simple YAML parsing for anthropic_api_key — avoid adding yaml dependency
    // just for this one value. Looks for:
    //   ai:
    //     anthropic_api_key: sk-ant-...
    final lines = file.readAsLinesSync();
    bool inAiSection = false;
    for (final line in lines) {
      if (line.startsWith('ai:')) {
        inAiSection = true;
        continue;
      }
      if (inAiSection) {
        if (!line.startsWith(' ') && !line.startsWith('\t') && line.isNotEmpty) {
          break; // Left ai section
        }
        final trimmed = line.trim();
        if (trimmed.startsWith('anthropic_api_key:')) {
          final value = trimmed.substring('anthropic_api_key:'.length).trim();
          // Remove quotes if present
          if (value.startsWith("'") && value.endsWith("'")) {
            return value.substring(1, value.length - 1);
          }
          if (value.startsWith('"') && value.endsWith('"')) {
            return value.substring(1, value.length - 1);
          }
          return value;
        }
      }
    }
  } catch (_) {
    // Config file read error — fall through
  }
  return null;
}

/// Save API key to the Epyx config file.
void saveApiKey(String apiKey) {
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

    if (file.existsSync()) {
      // Read existing, update or add the key
      final content = file.readAsStringSync();
      final lines = content.split('\n');
      bool foundAi = false;
      bool foundKey = false;
      final newLines = <String>[];

      for (int i = 0; i < lines.length; i++) {
        if (lines[i].startsWith('ai:')) {
          foundAi = true;
          newLines.add(lines[i]);
          continue;
        }
        if (foundAi &&
            !foundKey &&
            lines[i].trim().startsWith('anthropic_api_key:')) {
          newLines.add('  anthropic_api_key: $apiKey');
          foundKey = true;
          continue;
        }
        if (foundAi &&
            !foundKey &&
            !lines[i].startsWith(' ') &&
            !lines[i].startsWith('\t') &&
            lines[i].isNotEmpty) {
          // End of ai section without finding key — insert before this line
          newLines.add('  anthropic_api_key: $apiKey');
          foundKey = true;
        }
        newLines.add(lines[i]);
      }

      if (!foundAi) {
        newLines.add('ai:');
        newLines.add('  anthropic_api_key: $apiKey');
      } else if (!foundKey) {
        newLines.add('  anthropic_api_key: $apiKey');
      }

      file.writeAsStringSync(newLines.join('\n'));
    } else {
      file.writeAsStringSync('ai:\n  anthropic_api_key: $apiKey\n');
    }
  } catch (_) {
    // Best effort
  }
}
