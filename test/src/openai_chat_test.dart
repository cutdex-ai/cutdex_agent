import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

Map<String, Object?> chunk(Map<String, Object?> delta, [String? reason]) => {
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': reason},
  ],
};
String event(Object payload) => 'data: ${jsonEncode(payload)}\n\n';
ModelRequest request() => ModelRequest(
  system: 'system',
  messages: [AgentMessage(role: MessageRole.user, text: 'hello')],
  tools: [],
  maxOutputTokens: 128,
);

void main() {
  late HttpServer server;
  late OpenAiChatAdapter adapter;
  final handled = <Future<void>>[];
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    adapter = OpenAiChatAdapter(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1/'),
      model: 'cx/gpt-5.6-sol',
      apiKey: 'test-only',
    );
  });
  tearDown(() async {
    await server.close(force: true);
    await Future.wait(handled);
    handled.clear();
  });
  void serve(Future<void> Function(HttpRequest) handler) {
    server.listen((req) {
      handled.add(handler(req));
    });
  }

  Future<void> respond(HttpRequest req, String text) async {
    await req.drain<void>();
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.write(text);
    await req.response.close();
  }

  test('serializes config and parses split UTF-8 and SSE chunks', () async {
    serve((req) async {
      expect(req.uri.path, '/v1/chat/completions');
      expect(req.headers.value('authorization'), 'Bearer test-only');
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
      expect(body['model'], 'cx/gpt-5.6-sol');
      expect(body['max_completion_tokens'], 128);
      expect(body['tools'], isNull);
      expect(body['messages'][0]['role'], 'system');
      req.response.headers.contentType = ContentType('text', 'event-stream');
      final bytes = utf8.encode(
        ': heartbeat\n\n${event(chunk({'content': '你好🎬'}))}${event(chunk({}, 'stop'))}data: [DONE]\n\n',
      );
      for (final byte in bytes) {
        req.response.add([byte]);
      }
      await req.response.close();
    });
    final events = await adapter
        .stream(request(), CancellationToken())
        .toList();
    expect(events.whereType<TextDelta>().single.text, '你好🎬');
    expect(events.whereType<ModelResponse>().single.text, '你好🎬');
  });

  test('omits authorization for endpoints without an API key', () async {
    final keyless = OpenAiChatAdapter(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'local-model',
      apiKey: '',
    );
    serve((req) async {
      expect(req.headers.value('authorization'), isNull);
      await respond(
        req,
        '${event(chunk({'content': 'local'}, 'stop'))}data: [DONE]\n\n',
      );
    });
    final events = await keyless
        .stream(request(), CancellationToken())
        .toList();
    expect(events.whereType<ModelResponse>().single.text, 'local');
  });

  test(
    'assembles interleaved tool argument fragments before final response',
    () async {
      serve(
        (req) => respond(
          req,
          '${event(chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'a',
                'type': 'function',
                'function': {'name': 'read', 'arguments': '{"id":'},
              },
              {
                'index': 1,
                'id': 'b',
                'type': 'function',
                'function': {'name': 'read', 'arguments': '{"id":'},
              },
            ],
          }))}${event(chunk({
            'tool_calls': [
              {
                'index': 1,
                'function': {'arguments': '2}'},
              },
              {
                'index': 0,
                'function': {'arguments': '1}'},
              },
            ],
          }, 'tool_calls'))}data: [DONE]\n\n',
        ),
      );
      final response =
          (await adapter.stream(request(), CancellationToken()).toList())
              .whereType<ModelResponse>()
              .single;
      expect(response.calls.map((c) => c.id), ['a', 'b']);
      expect(response.calls.map((c) => c.arguments['id']), [1, 2]);
    },
  );

  test(
    '9router completion ends with finish_reason and clean EOF without DONE',
    () async {
      serve(
        (req) => respond(
          req,
          '${event(chunk({'content': 'ROUTER_OK'}))}${event({
            ...chunk({}, 'stop'),
            'usage': {'total_tokens': 12},
          })}',
        ),
      );
      final events = await adapter
          .stream(request(), CancellationToken())
          .toList();
      expect(events.whereType<ModelResponse>().single.text, 'ROUTER_OK');
    },
  );

  test(
    '9router tool completion accepts clean EOF only after complete arguments',
    () async {
      serve(
        (req) => respond(
          req,
          event(
            chunk({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call',
                  'type': 'function',
                  'function': {'name': 'read', 'arguments': '{}'},
                },
              ],
            }, 'tool_calls'),
          ),
        ),
      );
      final events = await adapter
          .stream(request(), CancellationToken())
          .toList();
      expect(
        events.whereType<ModelResponse>().single.calls.single.name,
        'read',
      );
    },
  );

  test('HTTP failures expose status without response body or key', () async {
    serve((req) async {
      await req.drain<void>();
      req.response.statusCode = 401;
      req.response.write('secret from upstream');
      await req.response.close();
    });
    await expectLater(
      adapter.stream(request(), CancellationToken()).toList(),
      throwsA(
        isA<ModelHttpException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.toString(), 'message', isNot(contains('secret'))),
      ),
    );
  });

  test('redirect is rejected without forwarding credentials', () async {
    var requests = 0;
    serve((req) async {
      requests++;
      await req.drain<void>();
      req.response.statusCode = 307;
      req.response.headers.set('location', '/other');
      await req.response.close();
    });
    await expectLater(
      adapter.stream(request(), CancellationToken()).toList(),
      throwsA(isA<ModelHttpException>()),
    );
    expect(requests, 1);
  });

  for (final bad in [
    'truncated',
    'length',
    'arguments',
    'error',
    'missing-finish',
  ]) {
    test('rejects $bad without a completed response', () async {
      final payload = switch (bad) {
        'truncated' => event(chunk({'content': 'partial'})),
        'length' =>
          '${event(chunk({'content': 'partial'}, 'length'))}data: [DONE]\n\n',
        'arguments' =>
          '${event(chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'a',
                'function': {'name': 'read', 'arguments': '{'},
              },
            ],
          }, 'tool_calls'))}data: [DONE]\n\n',
        'error' => event({
          'error': {'message': 'upstream failure'},
        }),
        _ => 'data: [DONE]\n\n',
      };
      serve((req) => respond(req, payload));
      final events = <ModelEvent>[];
      await expectLater(
        adapter.stream(request(), CancellationToken()).forEach(events.add),
        throwsA(isA<ModelProtocolException>()),
      );
      expect(events.whereType<ModelResponse>(), isEmpty);
    });
  }

  test('cancels an HTTP request waiting for response headers', () async {
    final entered = Completer<void>();
    serve((req) async {
      await req.drain<void>();
      entered.complete();
    });
    final token = CancellationToken();
    final result = adapter.stream(request(), token).toList();
    final checked = expectLater(result, throwsA(isA<AgentCancelled>()));
    await entered.future;
    token.cancel();
    await checked.timeout(const Duration(seconds: 3));
  });

  test('cancels while receiving SSE without yielding final response', () async {
    serve((req) async {
      await req.drain<void>();
      req.response.bufferOutput = false;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.write(event(chunk({'content': 'partial'})));
      await req.response.flush();
    });
    final token = CancellationToken();
    final events = <ModelEvent>[];
    await expectLater(
      adapter.stream(request(), token).forEach((e) {
        events.add(e);
        token.cancel();
      }),
      throwsA(isA<AgentCancelled>()),
    );
    expect(events.whereType<ModelResponse>(), isEmpty);
  });

  test('request timeout settles a stalled HTTP call', () async {
    serve((req) async {
      await req.drain<void>();
    });
    final short = OpenAiChatAdapter(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
      model: 'model',
      apiKey: 'test-only',
      requestTimeout: const Duration(milliseconds: 80),
    );
    await expectLater(
      short.stream(request(), CancellationToken()).toList(),
      throwsA(
        isA<ModelConnectionException>().having(
          (e) => e.kind,
          'kind',
          ModelConnectionKind.timeout,
        ),
      ),
    );
  });

  test('cancellation affects only its own concurrent request', () async {
    var count = 0;
    final entered = Completer<void>();
    serve((req) async {
      count++;
      if (count == 1) {
        await req.drain<void>();
        entered.complete();
      } else {
        await respond(
          req,
          '${event(chunk({'content': 'second'}, 'stop'))}data: [DONE]\n\n',
        );
      }
    });
    final token = CancellationToken();
    final first = expectLater(
      adapter.stream(request(), token).toList(),
      throwsA(isA<AgentCancelled>()),
    );
    await entered.future;
    final second = adapter.stream(request(), CancellationToken()).toList();
    token.cancel();
    await first;
    expect((await second).whereType<ModelResponse>().single.text, 'second');
  });

  test(
    'real HTTP adapter completes agent tool loop and serializes tool history',
    () async {
      var requests = 0;
      var edits = 0;
      serve((req) async {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        req.response.headers.contentType = ContentType('text', 'event-stream');
        if (requests++ == 0) {
          expect(body['tools'][0]['function']['name'], 'edit');
          req.response.write(
            event(
              chunk({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call',
                    'type': 'function',
                    'function': {'name': 'edit', 'arguments': '{"duration":5}'},
                  },
                ],
              }, 'tool_calls'),
            ),
          );
        } else {
          expect(
            body['messages'][2]['tool_calls'][0]['function']['arguments'],
            '{"duration":5}',
          );
          expect(body['messages'][3]['role'], 'tool');
          expect(body['messages'][3]['tool_call_id'], 'call');
          req.response.write(event(chunk({'content': 'done'}, 'stop')));
        }
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });
      final manager = SessionManager(
        model: adapter,
        contextBuilder: HarnessContextBuilder(directTools: const {'edit'}),
        store: InMemorySessionStore(),
        tools: [
          AgentTool(
            name: 'edit',
            description: 'edit',
            parameters: {'type': 'object'},
            validate: (_) => null,
            execute: (_, _) async {
              edits++;
              return ToolResult('ok');
            },
          ),
        ],
      );
      final session = await manager.create(system: 'edit');
      expect(
        (await (await manager.prompt(session.id, 'edit')).done).status,
        RunStatus.completed,
      );
      expect(edits, 1);
      expect(requests, 2);
    },
  );
}
