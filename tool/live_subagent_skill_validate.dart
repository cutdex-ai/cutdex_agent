import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../example/skill_discovery_config.dart';
import 'media_project_fixture.dart';
import 'subagent_skill_validation.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('env-file', defaultsTo: '.env')
    ..addOption(
      'skills-dir',
      defaultsTo: Directory.fromUri(
        Platform.script.resolve('../example/media_skills/'),
      ).path,
    )
    ..addOption('output-root', defaultsTo: '.dart_tool/subagent-skills')
    ..addOption(
      'report',
      defaultsTo: '.dart_tool/subagent-skills/latest-report.json',
    )
    ..addOption('ffmpeg', defaultsTo: 'ffmpeg')
    ..addOption('ffprobe', defaultsTo: 'ffprobe')
    ..addFlag(
      'multi-level',
      negatable: false,
      help: '主代理创建协调子代理，再由协调子代理创建两位孙代理。',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults options;
  try {
    options = parser.parse(args);
    if (options.rest.isNotEmpty) {
      throw const FormatException('Use named options');
    }
  } on FormatException catch (error) {
    stderr.writeln('${error.message}\n${parser.usage}');
    exitCode = 64;
    return;
  }
  if (options.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final multiLevel = options.flag('multi-level');
  final outputRoot = multiLevel && !options.wasParsed('output-root')
      ? '.dart_tool/multilevel-subagent-skills'
      : options.option('output-root')!;
  final reportPath = multiLevel && !options.wasParsed('report')
      ? '.dart_tool/multilevel-subagent-skills/latest-report.json'
      : options.option('report')!;
  SkillExampleLiveConfig? config;
  String redact(String text) => config?.redact(text) ?? text;
  try {
    config = SkillExampleLiveConfig(
      await readSkillExampleEnvironment(
        options.option('env-file')!,
        Platform.environment,
      ),
    );
    stdout.writeln(
      '真实${multiLevel ? '多层' : ''}子代理 + Skill + FFmpeg 场景，模型：${config.model}',
    );
    final report = <String, Object?>{
      'model': config.model,
      ...await validateSubagentSkills(
        config.createModel(),
        skillDirectory: options.option('skills-dir')!,
        outputRoot: outputRoot,
        multiLevel: multiLevel,
        timeout: const Duration(minutes: 8),
        commands: MediaCommands(
          ffmpeg: options.option('ffmpeg')!,
          ffprobe: options.option('ffprobe')!,
        ),
        onLog: (message) => stdout.writeln(redact(message)),
      ),
    };
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      redact('${const JsonEncoder.withIndent('  ').convert(report)}\n'),
    );
    stdout.writeln('报告：${file.absolute.path}');
    for (final coordinator in report['coordinators'] as List) {
      final entry = coordinator as Map;
      stdout.writeln('${entry['name']}: coordinator passed=${entry['passed']}');
    }
    for (final child in report['children'] as List) {
      final entry = child as Map;
      stdout.writeln(
        '${entry['name']}: ${entry['loadedSkillIds']} passed=${entry['passed']}',
      );
    }
    for (final check in (report['checks'] as Map).entries) {
      stdout.writeln('${check.value == true ? 'PASS' : 'FAIL'} ${check.key}');
    }
    stdout.writeln(redact('主代理答复：${report['finalAnswer']}'));
    if (report['passed'] != true) {
      stderr.writeln('场景验证失败，查看实际调用和媒体指标。');
      exitCode = 70;
    }
  } catch (error) {
    stderr.writeln(redact('场景测试失败：$error'));
    exitCode = 70;
  }
}
