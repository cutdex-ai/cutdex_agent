import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'skill_discovery_config.dart';
import 'skill_discovery_validation.dart';

/// Simulates model decisions using only requests, catalog summaries and results.
///
/// This offline adapter has no filesystem access or skill provider reference.
/// A real model adapter can replace it without changing the host setup.
class SkillDiscoveryExampleModel implements ModelAdapter {
  final List<ModelRequest> requests = [];
  String? selectedSkillId;
  double? targetDuration;

  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    cancellation.throwIfCancelled();
    requests.add(request);
    final last = request.messages.last;
    if (last.role == MessageRole.user) {
      // The runtime adds this JSON catalog to the system prompt. Read summaries
      // as a model would; the host never selects a skill or loads its body.
      final catalogLine = request.system
          .split('\n')
          .singleWhere((line) => line.startsWith('{"skills":'));
      final catalog = jsonDecode(catalogLine) as Map;
      stdout.writeln('\n1. 模型收到技能目录摘要：');
      for (final descriptor in catalog['skills'] as List) {
        final entry = descriptor as Map;
        stdout.writeln(
          '   ${entry['id']}@${entry['version']}：${entry['description']}',
        );
      }
      stdout.writeln(
        '   首次请求含技能正文：${request.system.contains('Skill source:')}',
      );
      stdout.writeln(
        '   首次请求含剪辑工具：${request.tools.any((tool) => tool.name == 'trim_example_clip')}',
      );
      if (!last.text.contains('剪辑')) {
        throw StateError('这个离线示例仅演示剪辑任务。');
      }
      yield ModelResponse(
        calls: [
          ToolCall(
            id: 'discover',
            name: 'list_skills',
            arguments: {'query': '剪辑'},
          ),
        ],
      );
      return;
    }

    final result = ToolResult.fromJson(
      (jsonDecode(last.text) as Map).cast<String, Object?>(),
    );
    if (last.isError || result.isError) {
      yield ModelResponse(text: '示例流程遇到工具错误：${result.text}');
      return;
    }
    final previous = request.messages.expand((message) => message.calls).last;
    switch (previous.name) {
      case 'list_skills':
        final matches = (result.data['skills'] as List).cast<Map>();
        final selected = matches.firstWhere(
          (entry) => (entry['description'] as String).contains('剪辑'),
        );
        selectedSkillId = selected['id'] as String;
        stdout.writeln('\n2. 模型按目录描述选择技能：$selectedSkillId');
        yield ModelResponse(
          calls: [
            ToolCall(
              id: 'activate',
              name: 'load_skill',
              arguments: {'id': selectedSkillId},
            ),
          ],
        );
      case 'load_skill':
        final heading =
            'Skill ${result.data['id']}@${result.data['version']}:\n';
        final start = request.system.indexOf(heading);
        if (start < 0) throw StateError('技能正文没有进入后续请求。');
        final bodyStart = start + heading.length;
        final end = request.system.indexOf(
          '\n\nAvailable skill catalog',
          bodyStart,
        );
        stdout.writeln('\n3. 按需加载后，模型收到技能正文：');
        stdout.writeln(
          request.system
              .substring(bodyStart, end < 0 ? request.system.length : end)
              .trim(),
        );
        if (!request.tools.any((tool) => tool.name == 'trim_example_clip')) {
          throw StateError('技能所需的剪辑工具没有激活。');
        }
        stdout.writeln('   技能依赖的剪辑工具已可调用。');
        yield ModelResponse(
          calls: [ToolCall(id: 'inspect-before', name: 'read_example_clip')],
        );
      case 'read_example_clip':
        final seconds = (result.data['durationSeconds'] as num).toDouble();
        final trimmed = request.messages
            .expand((message) => message.calls)
            .any((call) => call.name == 'trim_example_clip');
        if (!trimmed) {
          targetDuration = seconds > 10 ? 10 : seconds;
          stdout.writeln('\n4. 模型读取素材：$seconds 秒，计划剪辑为 $targetDuration 秒。');
          yield ModelResponse(
            calls: [
              ToolCall(
                id: 'trim',
                name: 'trim_example_clip',
                arguments: {
                  'durationSeconds': targetDuration,
                  'preserveAudio': true,
                },
              ),
            ],
          );
        } else {
          if (seconds != targetDuration ||
              result.data['originalAudioPreserved'] != true) {
            throw StateError('素材回读验证失败。');
          }
          stdout.writeln('\n6. 模型回读验证：$seconds 秒，原始音频已保留。');
          yield ModelResponse(text: '完成：视频已剪辑为 $seconds 秒，并保留原始音频；已通过回读验证。');
        }
      case 'trim_example_clip':
        stdout.writeln('\n5. 剪辑工具已执行，模型继续回读实际状态。');
        yield ModelResponse(
          calls: [ToolCall(id: 'inspect-after', name: 'read_example_clip')],
        );
      default:
        throw StateError('Unexpected example tool: ${previous.name}');
    }
  }
}

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('live', negatable: false, help: '使用真实模型；默认使用离线模拟模型。')
    ..addOption('env-file', defaultsTo: '.env', help: '真实模型配置文件；同名环境变量优先。')
    ..addOption('report', help: '保存包含实际调用记录和检查结果的 JSON 报告。')
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助。');
  final ArgResults options;
  try {
    options = parser.parse(args);
    if (options.rest.length > 1) throw const FormatException('只接受一个可选技能目录');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(
      '用法：dart run example/skill_discovery.dart [选项] [技能目录]\n${parser.usage}',
    );
    exitCode = 64;
    return;
  }
  if (options.flag('help')) {
    stdout.writeln(
      '用法：dart run example/skill_discovery.dart [选项] [技能目录]\n${parser.usage}',
    );
    return;
  }
  SkillExampleLiveConfig? config;
  String redact(String text) => config?.redact(text) ?? text;
  try {
    final live = options.flag('live');
    final ModelAdapter model;
    if (live) {
      config = SkillExampleLiveConfig(
        await readSkillExampleEnvironment(
          options.option('env-file')!,
          Platform.environment,
        ),
      );
      model = config.createModel();
      stdout.writeln('真实模型模式：${config.model}（Chat Completions）；素材仍使用内存测试数据。');
    } else {
      model = SkillDiscoveryExampleModel();
      stdout.writeln('离线示例：模拟模型决策，无需密钥、网络或真实媒体文件。');
    }
    final path = options.rest.isEmpty
        ? Directory.fromUri(Platform.script.resolve('skills/')).path
        : options.rest.single;
    stdout.writeln('宿主技能目录：${Directory(path).absolute.path}');
    final report = <String, Object?>{
      'mode': live ? 'live' : 'offline',
      if (live) 'model': config!.model,
      ...await validateSkillDiscovery(
        model,
        skillDirectory: path,
        onLog: (message) => stdout.writeln(redact(message)),
      ),
    };
    final reportPath = options.option('report');
    if (reportPath != null) {
      final file = File(reportPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        redact('${const JsonEncoder.withIndent('  ').convert(report)}\n'),
      );
      stdout.writeln('验证报告：${file.absolute.path}');
    }
    final checks = report['checks'] as Map;
    for (final entry in checks.entries) {
      stdout.writeln('${entry.value == true ? 'PASS' : 'FAIL'} ${entry.key}');
    }
    stdout.writeln(redact('\n${report['answer']}'));
    if (report['passed'] != true) {
      stderr.writeln(
        redact(
          '验证失败：状态 ${report['status']}；${report['error'] ?? '查看未通过的检查项和实际调用记录'}',
        ),
      );
      exitCode = 70;
      return;
    }
    stdout.writeln(
      '验证通过：实际加载正文 ${report['loadedSkillIds']}；最终素材 ${report['finalState']}。',
    );
  } on FormatException catch (error) {
    stderr.writeln(redact('配置错误：${error.message}'));
    exitCode = 78;
  } catch (error) {
    stderr.writeln(redact('示例运行失败：$error'));
    exitCode = 70;
  }
}
