import 'dart:convert';
import 'dart:io';

import '../run/cancellation.dart';
import 'adapter.dart';
import 'messages.dart';
import 'sse_transport.dart';

export 'sse_transport.dart' show ModelHttpException, ModelProtocolException;

/// OpenAI-compatible Chat Completions over HTTP/SSE (including 9router).
/// Each request owns a client, so aborting one run cannot cancel another run.
class OpenAiChatAdapter implements ModelAdapter {
  OpenAiChatAdapter({
    required Uri baseUrl,
    required this.model,
    required String apiKey,
    this.requestTimeout = const Duration(minutes: 3),
    this.maxResponseBytes = 8 * 1024 * 1024,
    HttpClient Function()? clientFactory,
  }) : _apiKey = apiKey,
       _clientFactory = clientFactory ?? HttpClient.new,
       endpoint = baseUrl.replace(
         path:
             '${baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
       ) {
    if (!['http', 'https'].contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment) {
      throw ArgumentError(
        'Expected an HTTP base URL without credentials, query or fragment',
      );
    }
    if (model.trim().isEmpty ||
        apiKey.contains('\n') ||
        apiKey.contains('\r')) {
      throw ArgumentError('Model is required and the API key must be valid');
    }
    if (requestTimeout <= Duration.zero || maxResponseBytes <= 0) {
      throw ArgumentError('Timeout and response limit must be positive');
    }
  }
  final Uri endpoint;
  final String model;
  final String _apiKey;
  final Duration requestTimeout;
  final int maxResponseBytes;
  final HttpClient Function() _clientFactory;

  Map<String, Object?> _body(ModelRequest request) => {
    'model': model,
    'stream': true,
    'max_completion_tokens': request.maxOutputTokens,
    'messages': [
      if (request.system.isNotEmpty)
        {'role': 'system', 'content': request.system},
      for (final message in request.messages)
        {
          'role': message.role.name,
          'content': message.text,
          if (message.callId != null) 'tool_call_id': message.callId,
          if (message.calls.isNotEmpty)
            'tool_calls': [
              for (final call in message.calls)
                {
                  'id': call.id,
                  'type': 'function',
                  'function': {
                    'name': call.name,
                    'arguments': jsonEncode(call.arguments),
                  },
                },
            ],
        },
    ],
    if (request.tools.isNotEmpty)
      'tools': [
        for (final tool in request.tools)
          {'type': 'function', 'function': tool.declaration},
      ],
  };

  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    final decoder = _ChatDecoder();
    yield* streamModelSse(
      endpoint: endpoint,
      body: _body(request),
      headers: {if (_apiKey.isNotEmpty) 'authorization': 'Bearer $_apiKey'},
      cancellation: cancellation,
      decode: decoder.add,
      finish: decoder.finish,
      requestTimeout: requestTimeout,
      maxResponseBytes: maxResponseBytes,
      clientFactory: _clientFactory,
    );
  }
}

class _Call {
  String id = '';
  String name = '';
  final arguments = StringBuffer();
}

class _ChatDecoder {
  final text = StringBuffer();
  final Map<int, _Call> calls = {};
  String? finishReason;
  String add(String payload) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      throw const ModelProtocolException('Invalid streaming JSON');
    }
    if (decoded is! Map<String, Object?>) {
      throw const ModelProtocolException('Expected a streaming object');
    }
    if (decoded['error'] != null) {
      throw const ModelProtocolException('Gateway reported a streaming error');
    }
    final choices = decoded['choices'];
    if (choices is! List) throw const ModelProtocolException('Missing choices');
    if (choices.isEmpty) return ''; // Usage-only final chunk.
    if (choices.length != 1 || choices.single is! Map) {
      throw const ModelProtocolException('Expected exactly one choice');
    }
    final choice = (choices.single as Map).cast<String, Object?>();
    if (choice['index'] != 0) {
      throw const ModelProtocolException('Unexpected choice index');
    }
    if (finishReason != null) {
      throw const ModelProtocolException('Content after finish reason');
    }
    final delta = choice['delta'];
    if (delta is! Map) throw const ModelProtocolException('Missing delta');
    final content = delta['content'];
    if (content != null && content is! String) {
      throw const ModelProtocolException('Unsupported text content');
    }
    final chunk = content as String? ?? '';
    text.write(chunk);
    final toolCalls = delta['tool_calls'];
    if (toolCalls != null) {
      if (toolCalls is! List) {
        throw const ModelProtocolException('Invalid tool calls');
      }
      for (final raw in toolCalls) {
        if (raw is! Map || raw['index'] is! int || (raw['index'] as int) < 0) {
          throw const ModelProtocolException('Invalid tool call index');
        }
        final call = calls.putIfAbsent(raw['index'] as int, _Call.new);
        if (raw['type'] != null && raw['type'] != 'function') {
          throw const ModelProtocolException('Unsupported tool type');
        }
        if (raw['id'] != null) {
          if (raw['id'] is! String ||
              (call.id.isNotEmpty && call.id != raw['id'])) {
            throw const ModelProtocolException('Conflicting tool identity');
          }
          call.id = raw['id'] as String;
        }
        final function = raw['function'];
        if (function != null) {
          if (function is! Map) {
            throw const ModelProtocolException('Invalid function');
          }
          if (function['name'] != null) {
            if (function['name'] is! String) {
              throw const ModelProtocolException('Invalid function name');
            }
            call.name += function['name'] as String;
          }
          if (function['arguments'] != null) {
            if (function['arguments'] is! String) {
              throw const ModelProtocolException('Invalid function arguments');
            }
            call.arguments.write(function['arguments']);
          }
        }
      }
    }
    final reason = choice['finish_reason'];
    if (reason != null) {
      if (reason is! String) {
        throw const ModelProtocolException('Invalid finish reason');
      }
      finishReason = reason;
    }
    return chunk;
  }

  ModelResponse finish() {
    if (finishReason != 'stop' && finishReason != 'tool_calls') {
      throw const ModelProtocolException('Missing or incomplete completion');
    }
    if (calls.isEmpty && finishReason == 'tool_calls' ||
        calls.isNotEmpty && finishReason != 'tool_calls') {
      throw const ModelProtocolException(
        'Finish reason does not match tool calls',
      );
    }
    final result = <ToolCall>[];
    final indexes = calls.keys.toList()..sort();
    final ids = <String>{};
    for (var i = 0; i < indexes.length; i++) {
      if (indexes[i] != i) {
        throw const ModelProtocolException('Non-contiguous tool call indexes');
      }
      final call = calls[i]!;
      if (call.id.isEmpty || call.name.isEmpty || !ids.add(call.id)) {
        throw const ModelProtocolException(
          'Missing or duplicate tool identity',
        );
      }
      Object? arguments;
      try {
        arguments = jsonDecode(call.arguments.toString());
      } on FormatException {
        throw const ModelProtocolException('Incomplete tool arguments');
      }
      if (arguments is! Map<String, Object?>) {
        throw const ModelProtocolException('Tool arguments must be an object');
      }
      result.add(ToolCall(id: call.id, name: call.name, arguments: arguments));
    }
    return ModelResponse(text: text.toString(), calls: result);
  }
}
