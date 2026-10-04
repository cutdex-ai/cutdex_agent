import 'dart:convert';

import 'adapter.dart';
import 'messages.dart';
import 'protocol_history.dart';
import 'protocol_support.dart';

/// OpenAI Responses API, with stateless local history and encrypted reasoning.
class OpenAiResponsesAdapter extends SseProtocolAdapter {
  OpenAiResponsesAdapter({
    required super.baseUrl,
    required super.model,
    required super.apiKey,
    super.requestTimeout,
    super.maxResponseBytes,
    super.clientFactory,
  }) : super(path: 'responses');

  @override
  Map<String, String> get headers => {
    if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
  };

  @override
  Map<String, Object?> body(ModelRequest request) => {
    'model': model,
    'stream': true,
    'store': false,
    'include': ['reasoning.encrypted_content'],
    'max_output_tokens': request.maxOutputTokens,
    if (request.system.isNotEmpty) 'instructions': request.system,
    'input': [
      for (final message in request.messages)
        if (ProtocolHistory.forMessage(ModelProtocol.openAiResponses, message)
            case final history?)
          ...history.items
        else ...[
          if (message.role == MessageRole.tool)
            {
              'type': 'function_call_output',
              'call_id': message.callId,
              'output': message.text,
            }
          else if (message.text.isNotEmpty)
            {'role': message.role.name, 'content': message.text},
          for (final call in message.calls)
            {
              'type': 'function_call',
              'call_id': call.id,
              'name': call.name,
              'arguments': jsonEncode(call.arguments),
            },
        ],
    ],
    if (request.tools.isNotEmpty)
      'tools': [
        for (final tool in request.tools)
          {'type': 'function', ...tool.declaration, 'strict': false},
      ],
  };

  @override
  ModelSseDecoder createDecoder() => _ResponsesDecoder();
}

class _ResponsesDecoder implements ModelSseDecoder {
  ModelResponse? result;
  final _items = <int, Map<String, Object?>>{};
  final _complete = <int>{};
  final _deltas = StringBuffer();
  bool _sawTool = false;

  int _index(Map<String, Object?> event) {
    final index = event['output_index'];
    if (index is! int || index < 0) {
      throw const ModelProtocolException('Missing output item index');
    }
    return index;
  }

  List<Object?> _output(List<Object?> finalOutput) {
    if (finalOutput.isNotEmpty) return finalOutput;
    // Some compatible gateways omit the aggregate output from completed.
    // Only completed item events can authorize a tool call; never use argument
    // deltas as a substitute for a complete call.
    if (_items.keys.any((index) => !_complete.contains(index))) {
      throw const ModelProtocolException('Incomplete output item');
    }
    if (_items.isNotEmpty) {
      final indexes = _items.keys.toList()..sort();
      return [for (final index in indexes) _items[index]!];
    }
    if (_sawTool) {
      throw const ModelProtocolException('Missing completed tool call');
    }
    if (_deltas.isNotEmpty) {
      return [
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {
              'type': 'output_text',
              'text': _deltas.toString(),
              'annotations': [],
            },
          ],
        },
      ];
    }
    return [];
  }

  @override
  String add(String payload) {
    final event = protocolEvent(payload);
    if (result != null) {
      throw const ModelProtocolException('Content after completion');
    }
    switch (event['type']) {
      case 'response.output_text.delta':
      case 'response.refusal.delta':
        final delta = protocolString(event['delta']);
        _deltas.write(delta);
        return delta;
      case 'response.output_item.added':
      case 'response.output_item.done':
        final index = _index(event);
        final item = protocolObject(event['item']);
        if (_complete.contains(index) &&
            event['type'] != 'response.output_item.done') {
          throw const ModelProtocolException('Content after item completion');
        }
        _items[index] = item;
        if (item['type'] == 'function_call') _sawTool = true;
        if (event['type'] == 'response.output_item.done') {
          if (item['status'] != null && item['status'] != 'completed') {
            throw const ModelProtocolException('Incomplete output item');
          }
          _complete.add(index);
        }
      case 'response.function_call_arguments.delta':
        _sawTool = true;
      case 'response.function_call_arguments.done':
        _sawTool = true;
        final index = _index(event);
        final item = _items[index];
        if (item == null ||
            item['type'] != 'function_call' ||
            (event['item_id'] != null && item['id'] != event['item_id'])) {
          throw const ModelProtocolException('Missing tool item identity');
        }
        _items[index] = {
          ...item,
          'arguments': protocolString(event['arguments']),
        };
        _complete.add(index);
      case 'response.failed':
      case 'response.incomplete':
        throw const ModelProtocolException('Incomplete response');
      case 'response.completed':
        final response = protocolObject(event['response']);
        if (response['status'] != 'completed' || response['output'] is! List) {
          throw const ModelProtocolException('Missing complete response');
        }
        final text = StringBuffer();
        final calls = <ToolCall>[];
        final history = <Map<String, Object?>>[];
        for (final raw in _output(response['output']! as List)) {
          final item = protocolObject(raw);
          switch (item['type']) {
            case 'function_call':
              Object? args;
              try {
                args = jsonDecode(protocolString(item['arguments']));
              } on FormatException {
                throw const ModelProtocolException('Incomplete tool arguments');
              }
              calls.add(protocolToolCall(item['call_id'], item['name'], args));
              history.add({
                'type': 'function_call',
                'call_id': item['call_id'],
                'name': item['name'],
                'arguments': item['arguments'],
              });
            case 'message':
              if (item['content'] is! List) {
                throw const ModelProtocolException('Invalid message content');
              }
              final parts = <Map<String, Object?>>[];
              for (final rawPart in item['content']! as List) {
                final part = protocolObject(rawPart);
                if (part['type'] == 'output_text') {
                  final value = protocolString(part['text']);
                  text.write(value);
                  parts.add({
                    'type': 'output_text',
                    'text': value,
                    'annotations': part['annotations'] ?? [],
                  });
                } else if (part['type'] == 'refusal') {
                  final value = protocolString(part['refusal']);
                  text.write(value);
                  parts.add({'type': 'refusal', 'refusal': value});
                } else {
                  throw const ModelProtocolException(
                    'Unsupported response content',
                  );
                }
              }
              history.add({
                'type': 'message',
                'role': 'assistant',
                'content': parts,
              });
            case 'reasoning':
              history.add(item);
            default:
              throw const ModelProtocolException('Unsupported response output');
          }
        }
        if (calls.map((c) => c.id).toSet().length != calls.length) {
          throw const ModelProtocolException('Duplicate tool identity');
        }
        if (text.toString().trim().isEmpty && calls.isEmpty) {
          throw const ModelProtocolException('Empty completed response');
        }
        result = ModelResponse(
          text: text.toString(),
          usage: _usage(response['usage']),
          calls: calls,
          providerData: ProtocolHistory(
            protocol: ModelProtocol.openAiResponses,
            items: history,
          ).toProviderData(),
        );
    }
    return '';
  }

  TokenUsage? _usage(Object? raw) {
    if (raw is! Map) return null;
    final inputDetails = raw['input_tokens_details'];
    final outputDetails = raw['output_tokens_details'];
    return TokenUsage.fromJson({
      'inputTokens': raw['input_tokens'],
      'outputTokens': raw['output_tokens'],
      'totalTokens': raw['total_tokens'],
      'cachedInputTokens': inputDetails is Map
          ? inputDetails['cached_tokens']
          : null,
      'reasoningOutputTokens': outputDetails is Map
          ? outputDetails['reasoning_tokens']
          : null,
    });
  }

  @override
  ModelResponse finish() =>
      result ??
      (throw const ModelProtocolException('Missing response completion'));
}
