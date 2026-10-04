import 'dart:convert';

import 'adapter.dart';
import 'messages.dart';
import 'protocol_history.dart';
import 'protocol_support.dart';

/// Anthropic Messages API. Tool results are user content blocks, not tool roles.
class AnthropicMessagesAdapter extends SseProtocolAdapter {
  AnthropicMessagesAdapter({
    required super.baseUrl,
    required super.model,
    required super.apiKey,
    super.requestTimeout,
    super.maxResponseBytes,
    super.clientFactory,
  }) : super(path: 'messages');

  @override
  Map<String, String> get headers => {
    'anthropic-version': '2023-06-01',
    if (apiKey.isNotEmpty) 'x-api-key': apiKey,
  };

  @override
  Map<String, Object?> body(ModelRequest request) {
    final messages = <Map<String, Object?>>[];
    for (final message in request.messages) {
      final role = message.role == MessageRole.assistant ? 'assistant' : 'user';
      final blocks = <Object?>[
        if (message.role == MessageRole.tool)
          {
            'type': 'tool_result',
            'tool_use_id': message.callId,
            'content': message.text,
            'is_error': message.isError,
          }
        else if (ProtocolHistory.forMessage(
              ModelProtocol.anthropicMessages,
              message,
            )
            case final history?)
          ...history.items
        else ...[
          if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
          for (final call in message.calls)
            {
              'type': 'tool_use',
              'id': call.id,
              'name': call.name,
              'input': call.arguments,
            },
        ],
      ];
      if (blocks.isEmpty) continue;
      if (messages.isNotEmpty && messages.last['role'] == role) {
        (messages.last['content']! as List<Object?>).addAll(blocks);
      } else {
        messages.add({'role': role, 'content': blocks});
      }
    }
    return {
      'model': model,
      'stream': true,
      'max_tokens': request.maxOutputTokens,
      if (request.system.isNotEmpty) 'system': request.system,
      'messages': messages,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.parameters,
            },
        ],
    };
  }

  @override
  ModelSseDecoder createDecoder() => _MessagesDecoder();
}

class _MessagesDecoder implements ModelSseDecoder {
  final blocks = <int, Map<String, Object?>>{};
  final arguments = <int, StringBuffer>{};
  final active = <int>{};
  bool started = false;
  bool stopped = false;
  String? reason;
  @override
  String add(String payload) {
    final event = protocolEvent(payload);
    if (event['type'] == 'ping') return '';
    if (stopped) {
      throw const ModelProtocolException('Content after message stop');
    }
    final type = event['type'];
    if (type == 'message_start') {
      if (started) {
        throw const ModelProtocolException('Duplicate message start');
      }
      started = true;
      return '';
    }
    if (!started) throw const ModelProtocolException('Missing message start');
    switch (type) {
      case 'content_block_start':
        final index = event['index'];
        if (index is! int || index < 0 || blocks.containsKey(index)) {
          throw const ModelProtocolException('Invalid content block index');
        }
        final block = Map<String, Object?>.of(
          protocolObject(event['content_block']),
        );
        if (![
          'text',
          'tool_use',
          'thinking',
          'redacted_thinking',
        ].contains(block['type'])) {
          throw const ModelProtocolException('Unsupported content block');
        }
        blocks[index] = block;
        active.add(index);
        if (block['type'] == 'tool_use') arguments[index] = StringBuffer();
        if (block['type'] == 'text') return protocolString(block['text']);
      case 'content_block_delta':
        final index = event['index'];
        if (index is! int || !active.contains(index)) {
          throw const ModelProtocolException('Delta outside content block');
        }
        final block = blocks[index]!;
        final delta = protocolObject(event['delta']);
        switch (delta['type']) {
          case 'text_delta':
            if (block['type'] != 'text') {
              throw const ModelProtocolException('Unexpected text delta');
            }
            final value = protocolString(delta['text']);
            block['text'] = '${block['text']}$value';
            return value;
          case 'input_json_delta':
            if (block['type'] != 'tool_use') {
              throw const ModelProtocolException('Unexpected tool delta');
            }
            arguments[index]!.write(protocolString(delta['partial_json']));
          case 'thinking_delta':
            if (block['type'] != 'thinking') {
              throw const ModelProtocolException('Unexpected thinking delta');
            }
            block['thinking'] =
                '${block['thinking'] ?? ''}${protocolString(delta['thinking'])}';
          case 'signature_delta':
            if (block['type'] != 'thinking') {
              throw const ModelProtocolException('Unexpected signature delta');
            }
            block['signature'] =
                '${block['signature'] ?? ''}${protocolString(delta['signature'])}';
          default:
            throw const ModelProtocolException('Unsupported content delta');
        }
      case 'content_block_stop':
        final index = event['index'];
        if (index is! int || !active.remove(index)) {
          throw const ModelProtocolException('Invalid block stop');
        }
        final json = arguments[index]?.toString();
        if (json != null && json.isNotEmpty) {
          try {
            blocks[index]!['input'] = protocolObject(jsonDecode(json));
          } on FormatException {
            throw const ModelProtocolException('Incomplete tool arguments');
          }
        }
      case 'message_delta':
        final stopReason = protocolObject(event['delta'])['stop_reason'];
        if (stopReason != null) reason = protocolString(stopReason);
      case 'message_stop':
        if (active.isNotEmpty) {
          throw const ModelProtocolException('Unfinished content blocks');
        }
        stopped = true;
      default:
        // The API permits new event types; ignore events we do not consume.
        break;
    }
    return '';
  }

  @override
  ModelResponse finish() {
    if (!stopped ||
        !['end_turn', 'stop_sequence', 'tool_use'].contains(reason)) {
      throw const ModelProtocolException('Missing or incomplete message');
    }
    final text = StringBuffer();
    final calls = <ToolCall>[];
    final indexes = blocks.keys.toList()..sort();
    final history = <Map<String, Object?>>[];
    for (var i = 0; i < indexes.length; i++) {
      if (indexes[i] != i) {
        throw const ModelProtocolException('Non-contiguous content indexes');
      }
      final block = blocks[i]!;
      history.add(block);
      if (block['type'] == 'text') text.write(protocolString(block['text']));
      if (block['type'] == 'tool_use') {
        calls.add(protocolToolCall(block['id'], block['name'], block['input']));
      }
    }
    if ((reason == 'tool_use') != calls.isNotEmpty ||
        calls.map((c) => c.id).toSet().length != calls.length) {
      throw const ModelProtocolException('Invalid tool completion');
    }
    return ModelResponse(
      text: text.toString(),
      calls: calls,
      providerData: ProtocolHistory(
        protocol: ModelProtocol.anthropicMessages,
        items: history,
      ).toProviderData(),
    );
  }
}
