import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:test/test.dart';

import '../../example/skill_discovery_config.dart';
import '../../example/skill_discovery_validation.dart';
import '../src/agent_test.dart' show ScriptedModel;

String get skillsPath => Directory('example/skills').absolute.path;

ModelResponse call(
  String id,
  String name, [
  Map<String, Object?> args = const {},
]) => ModelResponse(
  calls: [ToolCall(id: id, name: name, arguments: args)],
);

List<ModelResponse> steps({bool load = true, bool verify = true}) => [
  call('list', 'list_skills', {'query': '剪辑'}),
  if (load) call('load', 'load_skill', {'id': 'video-editing'}),
  call('read', 'read_example_clip'),
  call('trim', 'trim_example_clip', {
    'durationSeconds': 10,
    'preserveAudio': true,
  }),
  if (verify) call('verify', 'read_example_clip'),
  ModelResponse(text: '完成'),
];

ModelAdapter scripted(List<ModelResponse> replies) {
  var index = 0;
  return ScriptedModel((_, _) async* {
    yield replies[index++];
  });
}

List<ModelResponse> colorSteps({
  String skillId = 'color-grading',
  bool extraSkill = false,
}) => [
  call('list', 'list_skills', {'query': '调色'}),
  call('load', 'load_skill', {'id': skillId}),
  if (extraSkill) call('unrelated', 'load_skill', {'id': 'video-editing'}),
  call('read', 'read_example_color'),
  call('grade', 'grade_example_clip', {
    'exposureEv': 0.5,
    'whiteBalanceKelvin': 5600,
  }),
  call('verify', 'read_example_color'),
  ModelResponse(text: '调色完成'),
];

void main() {
  group('live configuration', () {
    late Directory directory;
    late File envFile;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('cutdex-skill-env-');
      envFile = File.fromUri(directory.uri.resolve('.env'));
    });
    tearDown(() => directory.delete(recursive: true));

    test(
      'reads literal quoted env values and honors environment overrides',
      () async {
        await envFile.writeAsString('''# test credentials only
export CUTDEX_LIVE_BASE_URL="http://127.0.0.1:1234/v1"
CUTDEX_LIVE_API_KEY='test-key-with=equals'
CUTDEX_LIVE_MODEL=file-model
LITERAL=\${VALUE}
''');
        final values = await readSkillExampleEnvironment(envFile.path, {
          'CUTDEX_LIVE_MODEL': 'environment-model',
        });
        expect(values['LITERAL'], r'${VALUE}');
        final config = SkillExampleLiveConfig(values);
        final model = config.createModel();
        expect(model.model, 'environment-model');
        expect(model.endpoint.path, '/v1/chat/completions');
        expect(
          config.redact('test-key-with=equals http://127.0.0.1:1234/v1'),
          '[REDACTED] [REDACTED_ENDPOINT]',
        );
      },
    );

    test('a missing file can use environment-only configuration', () async {
      final values = await readSkillExampleEnvironment(envFile.path, {
        'CUTDEX_LIVE_BASE_URL': 'http://127.0.0.1/v1',
        'CUTDEX_LIVE_API_KEY': 'test-only',
        'CUTDEX_LIVE_MODEL': 'test-model',
      });
      expect(SkillExampleLiveConfig(values).createModel().model, 'test-model');
    });

    test('missing configuration fails before network access', () {
      for (final missing in [
        'CUTDEX_LIVE_BASE_URL',
        'CUTDEX_LIVE_API_KEY',
        'CUTDEX_LIVE_MODEL',
      ]) {
        final values = {
          'CUTDEX_LIVE_BASE_URL': 'http://127.0.0.1/v1',
          'CUTDEX_LIVE_API_KEY': 'test-only',
          'CUTDEX_LIVE_MODEL': 'test-model',
        }..remove(missing);
        expect(
          () => SkillExampleLiveConfig(values),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains(missing),
            ),
          ),
        );
      }
    });

    test('malformed env lines are rejected without including values', () async {
      for (final source in [
        'CUTDEX_LIVE_API_KEY="hidden-test-value',
        'CUTDEX_LIVE_API_KEY=hidden-test-value\nCUTDEX_LIVE_API_KEY=duplicate',
        'BAD KEY=hidden-test-value',
        'missing-equals',
      ]) {
        await envFile.writeAsString(source);
        await expectLater(
          readSkillExampleEnvironment(envFile.path, {}),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              isNot(contains('hidden-test-value')),
            ),
          ),
        );
      }
    });

    test('rejects full endpoint paths and credential-bearing URLs', () {
      for (final url in [
        'https://example.test/v1/chat/completions',
        'https://user:password@example.test/v1',
        'file:///tmp/v1',
        'https://example.test/v1?key=test',
      ]) {
        final config = SkillExampleLiveConfig({
          'CUTDEX_LIVE_BASE_URL': url,
          'CUTDEX_LIVE_API_KEY': 'test-only',
          'CUTDEX_LIVE_MODEL': 'test-model',
        });
        expect(config.createModel, throwsFormatException);
      }
    });
  });

  group('evidence validation', () {
    test(
      'two fresh sessions select different skills from the same catalog',
      () async {
        final report = await validateSkillTaskSelection(
          scripted([...steps(), ...colorSteps()]),
          skillDirectory: skillsPath,
        );
        expect(report['passed'], isTrue);
        final cases = report['cases'] as Map;
        final editing = cases['editing'] as Map;
        final grading = cases['colorGrading'] as Map;
        expect(editing['loadedSkillIds'], ['video-editing']);
        expect(grading['loadedSkillIds'], ['color-grading']);
        expect(editing['sessionId'], isNot(grading['sessionId']));
        expect((grading['finalState'] as Map)['durationSeconds'], 12);
        expect((grading['finalState'] as Map)['exposureEv'], 0.5);
        expect((grading['finalState'] as Map)['whiteBalanceKelvin'], 5600);
        expect((grading['checks'] as Map)['noUnrelatedSkillLoads'], isTrue);
        expect((editing['checks'] as Map)['noUnrelatedSkillLoads'], isTrue);
      },
    );

    test(
      'correct color results cannot hide selection of the editing skill',
      () async {
        final report = await validateSkillDiscovery(
          scripted(colorSteps(skillId: 'video-editing')),
          skillDirectory: skillsPath,
          task: SkillDiscoveryTask.colorGrading,
        );
        expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
        expect(
          (report['checks'] as Map)['modelSelectedRelevantSkill'],
          isFalse,
        );
        expect((report['checks'] as Map)['noUnrelatedSkillLoads'], isFalse);
        expect(report['passed'], isFalse);
      },
    );

    test(
      'loading an unrelated skill fails even if all business results are correct',
      () async {
        final report = await validateSkillDiscovery(
          scripted(colorSteps(extraSkill: true)),
          skillDirectory: skillsPath,
          task: SkillDiscoveryTask.colorGrading,
        );
        expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
        expect((report['checks'] as Map)['verifiedAfterGrade'], isTrue);
        expect((report['checks'] as Map)['noUnrelatedSkillLoads'], isFalse);
        expect(report['passed'], isFalse);
      },
    );

    test(
      'grading during an editing task is rejected as an unrelated operation',
      () async {
        final replies = steps();
        replies.insert(
          4,
          call('unrelated-grade', 'grade_example_clip', {
            'exposureEv': 0.5,
            'whiteBalanceKelvin': 5600,
          }),
        );
        final report = await validateSkillDiscovery(
          scripted(replies),
          skillDirectory: skillsPath,
        );
        expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
        expect((report['checks'] as Map)['noUnrelatedBusinessCalls'], isFalse);
        expect((report['checks'] as Map)['unrelatedStateUnchanged'], isFalse);
        expect(report['passed'], isFalse);
      },
    );

    test('passes the complete discovery, loading and business flow', () async {
      final report = await validateSkillDiscovery(
        scripted(steps()),
        skillDirectory: skillsPath,
      );
      expect(report['passed'], isTrue);
      expect(report['loadedSkillIds'], ['video-editing']);
      expect((report['modelRequests'] as List).length, 6);
    });

    test('rejects claimed completion without tool operations', () async {
      final report = await validateSkillDiscovery(
        scripted([ModelResponse(text: '已剪辑为 10 秒并验证')]),
        skillDirectory: skillsPath,
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['trimExecuted'], isFalse);
    });

    test('rejects correct business results without skill loading', () async {
      final report = await validateSkillDiscovery(
        scripted(steps(load: false)),
        skillDirectory: skillsPath,
      );
      expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
      expect((report['checks'] as Map)['modelSelectedRelevantSkill'], isFalse);
      expect(report['passed'], isFalse);
    });

    test('rejects missing verification after trimming', () async {
      final report = await validateSkillDiscovery(
        scripted(steps(verify: false)),
        skillDirectory: skillsPath,
      );
      expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
      expect((report['checks'] as Map)['verifiedAfterTrim'], isFalse);
      expect(report['passed'], isFalse);
    });

    test(
      'rejects business calls batched with loading before the body is delivered',
      () async {
        final report = await validateSkillDiscovery(
          scripted([
            ModelResponse(
              calls: [
                ToolCall(
                  id: 'load',
                  name: 'load_skill',
                  arguments: {'id': 'video-editing'},
                ),
                ToolCall(id: 'read', name: 'read_example_clip'),
                ToolCall(
                  id: 'trim',
                  name: 'trim_example_clip',
                  arguments: {'durationSeconds': 10, 'preserveAudio': true},
                ),
              ],
            ),
            call('verify', 'read_example_clip'),
            ModelResponse(text: 'done'),
          ]),
          skillDirectory: skillsPath,
        );
        expect((report['checks'] as Map)['finalStateCorrect'], isTrue);
        expect((report['checks'] as Map)['verifiedAfterTrim'], isTrue);
        expect(
          (report['checks'] as Map)['bodyDeliveredBeforeBusinessCalls'],
          isFalse,
        );
        expect(report['passed'], isFalse);
      },
    );
  });

  test(
    'live adapter completes the flow against a local HTTP/SSE endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final handled = <Future<void>>[];
      addTearDown(() async {
        await server.close(force: true);
        await Future.wait(handled);
      });
      final replies = steps();
      var round = 0;
      server.listen((request) {
        handled.add(() async {
          expect(request.uri.path, '/v1/chat/completions');
          expect(request.headers.value('authorization'), 'Bearer test-only');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['model'], 'test-model');
          expect(body['stream'], isTrue);
          final toolNames = (body['tools'] as List).map(
            (tool) => (tool as Map)['function']['name'],
          );
          if (round < 2) {
            expect(toolNames, isNot(contains('trim_example_clip')));
          }
          if (round == 2) expect(toolNames, contains('trim_example_clip'));
          final reply = replies[round++];
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          final delta = <String, Object?>{
            if (reply.text.isNotEmpty) 'content': reply.text,
            if (reply.calls.isNotEmpty)
              'tool_calls': [
                for (var i = 0; i < reply.calls.length; i++)
                  {
                    'index': i,
                    'id': reply.calls[i].id,
                    'type': 'function',
                    'function': {
                      'name': reply.calls[i].name,
                      'arguments': jsonEncode(reply.calls[i].arguments),
                    },
                  },
              ],
          };
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': reply.calls.isEmpty ? 'stop' : 'tool_calls'},
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        }());
      });
      final config = SkillExampleLiveConfig({
        'CUTDEX_LIVE_BASE_URL': 'http://127.0.0.1:${server.port}/v1',
        'CUTDEX_LIVE_API_KEY': 'test-only',
        'CUTDEX_LIVE_MODEL': 'test-model',
      });
      final report = await validateSkillDiscovery(
        config.createModel(),
        skillDirectory: skillsPath,
      );
      expect(report['passed'], isTrue);
      expect(round, 6);
      expect(jsonEncode(report), isNot(contains('test-only')));
    },
  );
}
