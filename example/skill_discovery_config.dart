import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/io.dart';

/// Reads a local env file, with process environment variables taking priority.
///
/// Supports blank lines, comments, `export KEY=value`, and matching single or
/// double quotes. Values are literal; shell expansion is never evaluated.
Future<Map<String, String>> readSkillExampleEnvironment(
  String path,
  Map<String, String> environment,
) async {
  final file = File(path);
  final values = <String, String>{};
  if (await file.exists()) {
    var number = 0;
    for (var line in const LineSplitter().convert(await file.readAsString())) {
      number++;
      line = line.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.startsWith('export ')) line = line.substring(7).trimLeft();
      final equals = line.indexOf('=');
      if (equals < 1) {
        throw FormatException('Env file line $number: expected KEY=value');
      }
      final key = line.substring(0, equals).trim();
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) ||
          values.containsKey(key)) {
        throw FormatException(
          'Env file line $number: invalid or duplicate variable',
        );
      }
      var value = line.substring(equals + 1).trim();
      if (value.startsWith('"') || value.startsWith("'")) {
        if (value.length < 2 || !value.endsWith(value[0])) {
          throw FormatException('Env file line $number: unclosed quote');
        }
        value = value.substring(1, value.length - 1);
      }
      values[key] = value;
    }
  }
  return {...values, ...environment};
}

/// Creates the live Chat Completions adapter from the example configuration.
class SkillExampleLiveConfig {
  SkillExampleLiveConfig(Map<String, String> values)
    : _baseUrl = _required(values, 'CUTDEX_LIVE_BASE_URL'),
      _apiKey = _required(values, 'CUTDEX_LIVE_API_KEY'),
      model = _required(values, 'CUTDEX_LIVE_MODEL');

  final String _baseUrl;
  final String _apiKey;
  final String model;

  static String _required(Map<String, String> values, String name) {
    final value = values[name]?.trim();
    if (value == null || value.isEmpty) {
      throw FormatException(
        '$name is required for live model mode; set it in .env or the process environment',
      );
    }
    return value;
  }

  /// Builds an adapter with a bounded timeout for each request.
  OpenAiChatAdapter createModel() {
    final uri = Uri.tryParse(_baseUrl);
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path
            .replaceFirst(RegExp(r'/+$'), '')
            .endsWith('/chat/completions')) {
      throw const FormatException(
        'CUTDEX_LIVE_BASE_URL must be an HTTP API root, without credentials, query, fragment or /chat/completions',
      );
    }
    return OpenAiChatAdapter(
      baseUrl: uri,
      model: model,
      apiKey: _apiKey,
      requestTimeout: const Duration(seconds: 60),
    );
  }

  /// Removes credentials and the endpoint from console and report text.
  String redact(String text) => text
      .replaceAll(_apiKey, '[REDACTED]')
      .replaceAll(_baseUrl, '[REDACTED_ENDPOINT]');
}
