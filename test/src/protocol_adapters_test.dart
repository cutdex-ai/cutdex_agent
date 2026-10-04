import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

final tool = AgentTool(
  name: 'edit',
  description: 'Edit timeline',
  parameters: {'type': 'object'},
  validate: (_) => null,
  execute: (_, _) async => ToolResult('done'),
);
ModelRequest request([List<AgentMessage>? messages]) => ModelRequest(
  system: 'policy',
  messages: messages ?? [AgentMessage(role: MessageRole.user, text: 'edit')],
  tools: [tool],
  maxOutputTokens: 256,
);
Map<String, Object?> completed(List<Object?> output) => {
  'type': 'response.completed',
  'response': {'status': 'completed', 'output': output},
};
Map<String, Object?> textOutput(String text) => {
  'type': 'message',
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': []},
  ],
};
List<Map<String, Object?>> messageText(String text) => [
  {
    'type': 'message_start',
    'message': {'role': 'assistant', 'content': []},
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
  },
  {'type': 'message_stop'},
];
void main() {
  late HttpServer server;
  final handlers = <Future<void>>[];
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
  tearDown(() async {
    await server.close(force: true);
    await Future.wait(handlers);
    handlers.clear();
  });
  Uri base() => Uri.parse('http://127.0.0.1:${server.port}/v1/');
  void serve(Future<void> Function(HttpRequest) handler) {
    server.listen((req) => handlers.add(handler(req)));
  }

  Future<void> respond(
    HttpRequest req,
    List<Map<String, Object?>> events,
  ) async {
    req.response.headers.contentType = ContentType('text', 'event-stream');
    for (final byte in utf8.encode(
      events
          .map((e) => 'event: ${e['type']}\r\ndata: ${jsonEncode(e)}\r\n\r\n')
          .join(),
    )) {
      req.response.add([byte]);
    }
    await req.response.close();
  }

  test(
    'Responses reconstructs completed gateway items and executes tools once',
    () async {
      final adapter = OpenAiResponsesAdapter(
        baseUrl: base(),
        model: 'test-model',
        apiKey: 'test-only',
      );
      var executions = 0;
      var round = 0;
      final editing = AgentTool(
        name: 'edit',
        description: 'Edit timeline',
        parameters: {'type': 'object'},
        validate: (_) => null,
        execute: (call, _) async {
          expect(call.arguments, {'seconds': 30});
          executions++;
          return ToolResult('split confirmed');
        },
      );
      final call = <String, Object?>{
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'edit',
        'arguments': '{"seconds":30}',
      };
      serve((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        if (round++ == 0) {
          await respond(req, [
            {
              'type': 'response.output_item.added',
              'output_index': 0,
              'item': {...call, 'arguments': ''},
            },
            {
              'type': 'response.function_call_arguments.delta',
              'output_index': 0,
              'item_id': 'fc_1',
              'delta': '{"seconds":',
            },
            {
              'type': 'response.function_call_arguments.done',
              'output_index': 0,
              'item_id': 'fc_1',
              'arguments': '{"seconds":30}',
            },
            {
              'type': 'response.output_item.done',
              'output_index': 0,
              'item': call,
            },
            completed([]),
          ]);
        } else {
          expect((body['input'] as List).last, {
            'type': 'function_call_output',
            'call_id': 'call_1',
            'output': jsonEncode(ToolResult('split confirmed').toJson()),
          });
          await respond(req, [
            {'type': 'response.output_text.delta', 'delta': '已完成分割'},
            {
              'type': 'response.output_item.done',
              'output_index': 0,
              'item': textOutput('已完成分割'),
            },
            completed([]),
          ]);
        }
      });
      final manager = SessionManager(
        model: adapter,
        store: InMemorySessionStore(),
        tools: [editing],
      );
      final session = await manager.create();
      final result = await (await manager.prompt(
        session.id,
        'split at 30 seconds',
      )).done;
      expect(result.status, RunStatus.completed);
      expect(executions, 1);
      expect(round, 2);
      expect(result.history.last.text, '已完成分割');
      expect(result.history.where((m) => m.calls.isNotEmpty), hasLength(1));
      final replay = adapter.body(request([result.history.last]));
      expect((replay['input'] as List).single['content'][0]['text'], '已完成分割');
    },
  );

  test(
    'Responses retains text deltas when a gateway omits aggregate output',
    () async {
      serve(
        (req) => respond(req, [
          {'type': 'response.output_text.delta', 'delta': '你好'},
          completed([]),
        ]),
      );
      final adapter = OpenAiResponsesAdapter(
        baseUrl: base(),
        model: 'test-model',
        apiKey: 'test-only',
      );
      final events = await adapter
          .stream(request(), CancellationToken())
          .toList();
      expect((events.last as ModelResponse).text, '你好');
    },
  );

  for (final events in <List<Map<String, Object?>>>[
    [completed([])],
    [
      {
        'type': 'response.function_call_arguments.delta',
        'output_index': 0,
        'delta': '{}',
      },
      completed([]),
    ],
    [
      {
        'type': 'response.output_item.added',
        'output_index': 0,
        'item': {
          'type': 'function_call',
          'call_id': 'c',
          'name': 'edit',
          'arguments': '{}',
        },
      },
      completed([]),
    ],
    [
      {
        'type': 'response.output_item.done',
        'output_index': 0,
        'item': {
          'type': 'function_call',
          'call_id': 'c',
          'name': 'edit',
          'arguments': '{}',
        },
      },
    ],
  ]) {
    test(
      'Responses rejects empty or unconfirmed gateway output ${events.first['type']}',
      () async {
        serve((req) => respond(req, events));
        final adapter = OpenAiResponsesAdapter(
          baseUrl: base(),
          model: 'test-model',
          apiKey: 'test-only',
        );
        await expectLater(
          adapter.stream(request(), CancellationToken()).toList(),
          throwsA(isA<ModelProtocolException>()),
        );
      },
    );
  }

  test(
    'Responses tools and encrypted reasoning survive history persistence',
    () async {
      final adapter = OpenAiResponsesAdapter(
        baseUrl: base(),
        model: 'test-model',
        apiKey: 'test-only',
      );
      final reasoning = {
        'type': 'reasoning',
        'id': 'rs_1',
        'summary': [],
        'encrypted_content': 'opaque',
      };
      final call = {
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'edit',
        'arguments': '{"value":2}',
      };
      var round = 0;
      serve((req) async {
        expect(req.uri.path, '/v1/responses');
        expect(req.headers.value('authorization'), 'Bearer test-only');
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body['store'], false);
        expect(body['stream'], true);
        expect(body['instructions'], 'policy');
        expect(body['max_output_tokens'], 256);
        expect(body['include'], ['reasoning.encrypted_content']);
        expect(body['tools'][0]['parameters'], tool.parameters);
        expect(body['tools'][0]['strict'], false);
        if (round++ == 0) {
          await respond(req, [
            {'type': 'response.output_text.delta', 'delta': '你好🎬'},
            {
              'type': 'response.function_call_arguments.delta',
              'delta': '{"value":',
            },
            {'type': 'response.function_call_arguments.delta', 'delta': '2}'},
            completed([reasoning, textOutput('你好🎬'), call]),
          ]);
        } else {
          expect(body['input'][1], reasoning);
          expect(body['input'][3], call);
          expect(body['input'][4], {
            'type': 'function_call_output',
            'call_id': 'call_1',
            'output': 'done',
          });
          await respond(req, [
            completed([textOutput('finished')]),
          ]);
        }
      });
      final events = await adapter
          .stream(request(), CancellationToken())
          .toList();
      expect(events.whereType<TextDelta>().single.text, '你好🎬');
      final result = events.whereType<ModelResponse>().single;
      expect(result.text, '你好🎬');
      expect(result.calls.single.arguments, {'value': 2});
      final persisted = AgentMessage.fromJson(
        AgentMessage(
          role: MessageRole.assistant,
          text: result.text,
          calls: result.calls,
          providerData: result.providerData,
        ).toJson(),
      );
      final next = await adapter
          .stream(
            request([
              AgentMessage(role: MessageRole.user, text: 'edit'),
              persisted,
              AgentMessage(
                role: MessageRole.tool,
                callId: 'call_1',
                text: 'done',
              ),
            ]),
            CancellationToken(),
          )
          .toList();
      expect(next.whereType<ModelResponse>().single.text, 'finished');
    },
  );
  test(
    'Messages supports parallel tools and signed thinking history',
    () async {
      final adapter = AnthropicMessagesAdapter(
        baseUrl: base(),
        model: 'claude-test',
        apiKey: 'test-only',
      );
      var round = 0;
      serve((req) async {
        expect(req.uri.path, '/v1/messages');
        expect(req.headers.value('x-api-key'), 'test-only');
        expect(req.headers.value('authorization'), isNull);
        expect(req.headers.value('anthropic-version'), '2023-06-01');
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        expect(body['system'], 'policy');
        expect(body['max_tokens'], 256);
        expect(body['tools'][0]['input_schema'], tool.parameters);
        if (round++ == 0) {
          await respond(req, [
            {
              'type': 'message_start',
              'message': {'role': 'assistant', 'content': []},
            },
            {'type': 'ping'},
            {
              'type': 'content_block_start',
              'index': 0,
              'content_block': {
                'type': 'thinking',
                'thinking': '',
                'signature': '',
              },
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'thinking_delta', 'thinking': 'plan'},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': {'type': 'signature_delta', 'signature': 'signed'},
            },
            {'type': 'content_block_stop', 'index': 0},
            for (var i = 1; i <= 2; i++) ...[
              {
                'type': 'content_block_start',
                'index': i,
                'content_block': {
                  'type': 'tool_use',
                  'id': 'tool_$i',
                  'name': 'edit',
                  'input': {},
                },
              },
              {
                'type': 'content_block_delta',
                'index': i,
                'delta': {
                  'type': 'input_json_delta',
                  'partial_json': '{"value":',
                },
              },
              {
                'type': 'content_block_delta',
                'index': i,
                'delta': {'type': 'input_json_delta', 'partial_json': '$i}'},
              },
              {'type': 'content_block_stop', 'index': i},
            ],
            {
              'type': 'message_delta',
              'delta': {'stop_reason': 'tool_use'},
            },
            {'type': 'message_stop'},
          ]);
        } else {
          expect(body['messages'].length, 3);
          expect(body['messages'][1]['content'][0], {
            'type': 'thinking',
            'thinking': 'plan',
            'signature': 'signed',
          });
          expect(body['messages'][2]['role'], 'user');
          expect(body['messages'][2]['content'].length, 2);
          expect(body['messages'][2]['content'][1]['is_error'], true);
          await respond(req, messageText('完成🎬'));
        }
      });
      final result =
          (await adapter.stream(request(), CancellationToken()).toList())
              .whereType<ModelResponse>()
              .single;
      expect(result.calls.map((c) => c.id), ['tool_1', 'tool_2']);
      expect(result.calls.last.arguments, {'value': 2});
      final next = await adapter
          .stream(
            request([
              AgentMessage(role: MessageRole.user, text: 'edit'),
              AgentMessage.fromJson(
                AgentMessage(
                  role: MessageRole.assistant,
                  calls: result.calls,
                  providerData: result.providerData,
                ).toJson(),
              ),
              AgentMessage(
                role: MessageRole.tool,
                callId: 'tool_1',
                text: 'done',
              ),
              AgentMessage(
                role: MessageRole.tool,
                callId: 'tool_2',
                text: 'failed',
                isError: true,
              ),
            ]),
            CancellationToken(),
          )
          .toList();
      expect(next.whereType<TextDelta>().single.text, '完成🎬');
      expect(next.whereType<ModelResponse>().single.text, '完成🎬');
    },
  );
  for (final anthropic in [false, true]) {
    ModelAdapter adapter({Duration? timeout}) => anthropic
        ? AnthropicMessagesAdapter(
            baseUrl: base(),
            model: 'test',
            apiKey: '',
            requestTimeout: timeout ?? const Duration(seconds: 2),
          )
        : OpenAiResponsesAdapter(
            baseUrl: base(),
            model: 'test',
            apiKey: '',
            requestTimeout: timeout ?? const Duration(seconds: 2),
          );
    final name = anthropic ? 'Messages' : 'Responses';
    test('$name rejects HTTP errors', () async {
      serve((req) async {
        await req.drain<void>();
        req.response.statusCode = 401;
        req.response.write('secret');
        await req.response.close();
      });
      await expectLater(
        adapter().stream(request(), CancellationToken()).toList(),
        throwsA(isA<ModelHttpException>()),
      );
    });
    test('$name rejects truncated streams', () async {
      serve((req) async {
        await req.drain<void>();
        await respond(
          req,
          anthropic
              ? messageText('text').sublist(0, 3)
              : [
                  {'type': 'response.output_text.delta', 'delta': 'text'},
                ],
        );
      });
      await expectLater(
        adapter().stream(request(), CancellationToken()).toList(),
        throwsA(isA<ModelProtocolException>()),
      );
    });
    test('$name rejects token-limited output', () async {
      serve((req) async {
        await req.drain<void>();
        final events = anthropic
            ? messageText('text')
            : [
                {'type': 'response.incomplete'},
              ];
        if (anthropic) {
          events[4] = {
            'type': 'message_delta',
            'delta': {'stop_reason': 'max_tokens'},
          };
        }
        await respond(req, events);
      });
      await expectLater(
        adapter().stream(request(), CancellationToken()).toList(),
        throwsA(isA<ModelProtocolException>()),
      );
    });
    test('$name cancels a stalled connection', () async {
      final connected = Completer<void>();
      serve((req) async {
        await req.drain<void>();
        connected.complete();
      });
      final token = CancellationToken();
      final pending = adapter().stream(request(), token).toList();
      final assertion = expectLater(pending, throwsA(isA<AgentCancelled>()));
      await connected.future;
      token.cancel();
      await assertion;
    });
    test('$name times out a stalled connection', () async {
      serve((req) async {
        await req.drain<void>();
      });
      await expectLater(
        adapter(
          timeout: const Duration(milliseconds: 100),
        ).stream(request(), CancellationToken()).toList(),
        throwsA(
          isA<ModelConnectionException>().having(
            (e) => e.kind,
            'kind',
            ModelConnectionKind.timeout,
          ),
        ),
      );
    });
  }
}
