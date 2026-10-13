import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../example/skill_discovery_config.dart';
import '../example/skill_discovery_validation.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('env-file', defaultsTo: '.env', help: '模型配置文件；同名环境变量优先。')
    ..addOption(
      'report',
      defaultsTo: '.dart_tool/skill-discovery/selection-report.json',
      help: '保存两项任务的实际调用记录和检查结果。',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助。');
  final ArgResults options;
  try {
    options = parser.parse(args);
    if (options.rest.length > 1) throw const FormatException('只接受一个可选技能目录');
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(
      '用法：dart run tool/live_skill_selection_validate.dart [选项] [技能目录]\n${parser.usage}',
    );
    exitCode = 64;
    return;
  }
  if (options.flag('help')) {
    stdout.writeln(
      '用法：dart run tool/live_skill_selection_validate.dart [选项] [技能目录]\n${parser.usage}',
    );
    return;
  }
  SkillExampleLiveConfig? config;
  String redact(String text) => config?.redact(text) ?? text;
  try {
    config = SkillExampleLiveConfig(
      await readSkillExampleEnvironment(
        options.option('env-file')!,
        Platform.environment,
      ),
    );
    final model = config.createModel();
    final path = options.rest.isEmpty
        ? Directory.fromUri(Platform.script.resolve('../example/skills/')).path
        : options.rest.single;
    stdout.writeln('真实模型技能选择测试：${config.model}；两项任务使用独立会话和相同目录。');
    final report = <String, Object?>{
      'mode': 'live',
      'model': config.model,
      ...await validateSkillTaskSelection(
        model,
        skillDirectory: path,
        onLog: (message) => stdout.writeln(redact(message)),
      ),
    };
    final file = File(options.option('report')!);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      redact('${const JsonEncoder.withIndent('  ').convert(report)}\n'),
    );
    stdout.writeln('\n验证报告：${file.absolute.path}');
    for (final entry in (report['cases'] as Map).entries) {
      final result = entry.value as Map;
      stdout.writeln(
        '${entry.key}：加载 ${result['loadedSkillIds']}；状态 ${result['status']}；最终状态 ${result['finalState']}',
      );
      for (final check in (result['checks'] as Map).entries) {
        stdout.writeln(
          '${check.value == true ? 'PASS' : 'FAIL'} ${entry.key}.${check.key}',
        );
      }
      if (result['error'] != null) {
        stderr.writeln(redact('${entry.key}: ${result['error']}'));
      }
    }
    for (final check in (report['checks'] as Map).entries) {
      stdout.writeln('${check.value == true ? 'PASS' : 'FAIL'} ${check.key}');
    }
    if (report['passed'] != true) {
      stderr.writeln('真实模型技能选择测试未通过，查看报告中的具体检查项。');
      exitCode = 70;
    }
  } on FormatException catch (error) {
    stderr.writeln(redact('配置错误：${error.message}'));
    exitCode = 78;
  } catch (error) {
    stderr.writeln(redact('真实模型测试失败：$error'));
    exitCode = 70;
  }
}
