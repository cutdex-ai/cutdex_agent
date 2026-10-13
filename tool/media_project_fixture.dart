import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:path/path.dart' as p;

/// Runs bounded FFmpeg processes and aborts them when the task is cancelled.
class MediaCommands {
  MediaCommands({this.ffmpeg = 'ffmpeg', this.ffprobe = 'ffprobe'});
  final String ffmpeg;
  final String ffprobe;

  Future<List<int>> run(
    String executable,
    List<String> arguments,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();
    final process = await Process.start(executable, arguments);
    var settled = false;
    var timedOut = false;
    unawaited(
      token.whenCancelled.then((_) {
        if (!settled) process.kill();
      }),
    );
    final timer = Timer(const Duration(seconds: 60), () {
      timedOut = true;
      process.kill();
    });
    try {
      final output = process.stdout.fold<List<int>>(
        [],
        (buffer, bytes) => buffer..addAll(bytes),
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final status = await process.exitCode;
      final bytes = await output;
      final stderrText = await errors;
      token.throwIfCancelled();
      if (timedOut || status != 0) {
        throw StateError(
          '$executable failed ($status, timeout=$timedOut): $stderrText',
        );
      }
      return bytes;
    } finally {
      settled = true;
      timer.cancel();
    }
  }

  Future<void> encode(List<String> arguments, CancellationToken token) async {
    await run(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      ...arguments,
    ], token);
  }

  Future<Map<String, Object?>> probe(
    String path,
    CancellationToken token,
  ) async {
    final bytes = await run(ffprobe, [
      '-v',
      'error',
      '-show_format',
      '-show_streams',
      '-of',
      'json',
      path,
    ], token);
    final data = jsonDecode(utf8.decode(bytes)) as Map;
    return {
      'durationSeconds': double.parse(
        (data['format'] as Map)['duration'] as String,
      ),
      'hasVideo': (data['streams'] as List).any(
        (stream) => (stream as Map)['codec_type'] == 'video',
      ),
      'hasAudio': (data['streams'] as List).any(
        (stream) => (stream as Map)['codec_type'] == 'audio',
      ),
    };
  }

  Future<String> audioHash(
    String path,
    double duration,
    CancellationToken token,
  ) async {
    final bytes = await run(ffmpeg, [
      '-nostdin',
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-t',
      '$duration',
      '-ac',
      '1',
      '-ar',
      '48000',
      '-c:a',
      'pcm_s16le',
      '-f',
      'hash',
      '-hash',
      'sha256',
      '-',
    ], token);
    return utf8.decode(bytes).trim();
  }

  Future<Map<String, double>> frameStats(
    String path,
    CancellationToken token,
  ) async {
    final rgb = await run(ffmpeg, [
      '-nostdin',
      '-v',
      'error',
      '-i',
      path,
      '-map',
      '0:v:0',
      '-frames:v',
      '1',
      '-pix_fmt',
      'rgb24',
      '-f',
      'rawvideo',
      '-',
    ], token);
    if (rgb.isEmpty || rgb.length % 3 != 0) {
      throw StateError('Invalid decoded RGB frame');
    }
    var red = 0.0, green = 0.0, blue = 0.0;
    for (var i = 0; i < rgb.length; i += 3) {
      red += rgb[i];
      green += rgb[i + 1];
      blue += rgb[i + 2];
    }
    final pixels = rgb.length ~/ 3;
    return {
      'meanLuma': (0.2126 * red + 0.7152 * green + 0.0722 * blue) / pixels,
      'redToBlueRatio': red / (blue == 0 ? 1 : blue),
    };
  }
}

/// Provides file-backed field patches and a real FFmpeg export for the scenario.
///
/// Writes are serialized, preserve peer fields and record operation receipts in
/// the same JSON replacement. The guard validates authority at publication.
class MediaProjectFixture {
  MediaProjectFixture(this.directory, this.commands, this.guard);
  final Directory directory;
  final MediaCommands commands;
  final ResourceCommitGuard guard;
  final List<Map<String, Object?>> actions = [];

  /// Observes child completion when rendering starts without gating execution.
  Future<bool> Function(String parentSessionId)? childrenCompleteAtRender;
  Future<void> _tail = Future.value();
  String get sourcePath => p.join(directory.path, 'source.mp4');
  String get outputPath => p.join(directory.path, 'output.mp4');
  String get projectPath => p.join(directory.path, 'project.json');

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    final previous = _tail;
    final released = Completer<void>();
    _tail = released.future;
    await previous;
    try {
      return await body();
    } finally {
      released.complete();
    }
  }

  Future<void> prepare() async {
    await directory.create(recursive: true);
    final token = CancellationToken();
    await commands.encode([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=320x180:rate=24:duration=12',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000:duration=12',
      '-c:v',
      'libx264',
      '-preset',
      'ultrafast',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-shortest',
      sourcePath,
    ], token);
    final source = await commands.probe(sourcePath, token);
    await File(projectPath).writeAsString(
      jsonEncode({
        'version': 0,
        'source': sourcePath,
        'sourceDurationSeconds': source['durationSeconds'],
        'durationSeconds': 12.0,
        'preserveAudio': true,
        'exposureEv': 0.0,
        'whiteBalanceKelvin': 6500,
        'render': null,
        'receipts': <String, Object?>{},
      }),
    );
  }

  Future<Map<String, Object?>> state() async =>
      (jsonDecode(await File(projectPath).readAsString()) as Map)
          .cast<String, Object?>();

  Map<String, Object?> _publicState(Map<String, Object?> state) =>
      {...state}..remove('receipts');

  void _saveSync(Map<String, Object?> state) {
    final temporary = File(p.setExtension(projectPath, '.json.tmp'));
    temporary.writeAsStringSync(jsonEncode(state), flush: true);
    temporary.renameSync(projectPath);
  }

  Future<ToolResult> _patch(
    ToolCall call,
    ToolContext context,
    Map<String, Object?> fields,
  ) => _exclusive(() async {
    final permit = guard.issue(context);
    final current = await state();
    final receipt = (current['receipts'] as Map)[context.operationId];
    if (receipt != null) {
      return ToolResult.fromJson((receipt as Map).cast<String, Object?>());
    }
    final next = {
      ...current,
      ...fields,
      'version': (current['version'] as int) + 1,
      'render': null,
    };
    final result = ToolResult('项目字段已更新，请回读验证', data: _publicState(next));
    next['receipts'] = {
      ...(current['receipts'] as Map).cast<String, Object?>(),
      context.operationId: result.toJson(),
    };
    return guard.commit(permit, () {
      _saveSync(next);
      actions.add({
        'tool': call.name,
        'sessionId': context.sessionId,
        'operationId': context.operationId,
        'version': next['version'],
        'fields': fields,
      });
      return result;
    });
  });

  Future<ToolRecovery> _recover(ToolCall call, ToolContext context) async {
    final receipt = ((await state())['receipts'] as Map)[context.operationId];
    if (receipt != null) {
      return ToolRecovery.completed(
        ToolResult.fromJson((receipt as Map).cast<String, Object?>()),
      );
    }
    return call.name == 'render_media_project'
        ? const ToolRecovery.unknown()
        : const ToolRecovery.notStarted();
  }

  List<AgentTool> get tools => [
    AgentTool(
      name: 'read_media_project',
      description: '读取磁盘媒体项目和当前编辑计划，包括版本、源时长、剪辑时长、曝光与白平衡。项目计划修改后，由主代理渲染实际视频。',
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (args) => args.isEmpty ? null : 'No arguments',
      execute: (call, context) => _exclusive(() async {
        context.cancellation.throwIfCancelled();
        final data = _publicState(await state());
        actions.add({
          'tool': call.name,
          'sessionId': context.sessionId,
          'operationId': context.operationId,
          'state': data,
        });
        return ToolResult('实际磁盘项目状态', data: data);
      }),
      recover: (_, _) async => const ToolRecovery.notStarted(),
    ),
    AgentTool(
      name: 'set_cut_duration',
      description: '只更新剪辑计划时长并保留音频，保留其他代理的调色字段。需要先读取项目，再回读验证。',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'durationSeconds': {
            'type': 'number',
            'exclusiveMinimum': 0,
            'maximum': 12,
          },
          'preserveAudio': {'type': 'boolean'},
        },
        'required': ['durationSeconds', 'preserveAudio'],
      },
      validate: (args) =>
          args.keys.any(
                (key) => !{'durationSeconds', 'preserveAudio'}.contains(key),
              ) ||
              args['durationSeconds'] is! num ||
              !(args['durationSeconds'] as num).isFinite ||
              (args['durationSeconds'] as num) <= 0 ||
              (args['durationSeconds'] as num) > 12 ||
              args['preserveAudio'] != true
          ? 'Supply duration 0..12 and preserveAudio=true'
          : null,
      execute: (call, context) => _patch(call, context, {
        'durationSeconds': (call.arguments['durationSeconds'] as num)
            .toDouble(),
        'preserveAudio': true,
      }),
      recover: _recover,
    ),
    AgentTool(
      name: 'set_color_grade',
      description: '只更新调色计划的曝光补偿和白平衡，保留其他代理的剪辑时长与音频。需要先读取项目，再回读验证。',
      parameters: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'exposureEv': {'type': 'number', 'minimum': -2, 'maximum': 2},
          'whiteBalanceKelvin': {
            'type': 'integer',
            'minimum': 2000,
            'maximum': 10000,
          },
        },
        'required': ['exposureEv', 'whiteBalanceKelvin'],
      },
      validate: (args) =>
          args.keys.any(
                (key) => !{'exposureEv', 'whiteBalanceKelvin'}.contains(key),
              ) ||
              args['exposureEv'] is! num ||
              !(args['exposureEv'] as num).isFinite ||
              (args['exposureEv'] as num) < -2 ||
              (args['exposureEv'] as num) > 2 ||
              args['whiteBalanceKelvin'] is! int ||
              (args['whiteBalanceKelvin'] as int) < 2000 ||
              (args['whiteBalanceKelvin'] as int) > 10000
          ? 'Supply exposure -2..2 EV and integer white balance 2000..10000 K'
          : null,
      execute: (call, context) => _patch(call, context, {
        'exposureEv': (call.arguments['exposureEv'] as num).toDouble(),
        'whiteBalanceKelvin': call.arguments['whiteBalanceKelvin'],
      }),
      recover: _recover,
    ),
    AgentTool(
      name: 'render_media_project',
      description:
          '主代理在子任务完成后，将磁盘项目当前剪辑与调色计划通过 FFmpeg 渲染为实际 MP4，回读 ffprobe 时长、音频哈希和画面指标。',
      alwaysAvailable: true,
      parameters: {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      validate: (args) => args.isEmpty ? null : 'No arguments',
      recover: _recover,
      execute: (call, context) => _exclusive(() async {
        final permit = guard.issue(context);
        final current = await state();
        final childrenComplete =
            await childrenCompleteAtRender?.call(context.sessionId) ?? false;
        final saved = (current['receipts'] as Map)[context.operationId];
        if (saved != null) {
          return ToolResult.fromJson((saved as Map).cast<String, Object?>());
        }
        final temporary = p.join(
          directory.path,
          'render-${current['version']}.mp4',
        );
        final duration = (current['durationSeconds'] as num).toDouble();
        final filters =
            'exposure=exposure=${current['exposureEv']},colortemperature=temperature=${current['whiteBalanceKelvin']}';
        try {
          await commands.encode([
            '-i',
            sourcePath,
            '-t',
            '$duration',
            '-vf',
            filters,
            '-c:v',
            'libx264',
            '-preset',
            'ultrafast',
            '-pix_fmt',
            'yuv420p',
            '-c:a',
            'copy',
            temporary,
          ], context.cancellation);
          final probe = await commands.probe(temporary, context.cancellation);
          final sourceHash = await commands.audioHash(
            sourcePath,
            duration,
            context.cancellation,
          );
          final outputHash = await commands.audioHash(
            temporary,
            duration,
            context.cancellation,
          );
          final sourceFrame = await commands.frameStats(
            sourcePath,
            context.cancellation,
          );
          final outputFrame = await commands.frameStats(
            temporary,
            context.cancellation,
          );
          final data = <String, Object?>{
            'childrenCompleteAtRenderStart': childrenComplete,
            'outputVideo': outputPath,
            'projectVersion': current['version'],
            'durationSeconds': probe['durationSeconds'],
            'hasVideo': probe['hasVideo'],
            'hasAudio': probe['hasAudio'],
            'originalAudioPreserved': sourceHash == outputHash,
            'sourceAudioHash': sourceHash,
            'outputAudioHash': outputHash,
            'sourceFrame': sourceFrame,
            'outputFrame': outputFrame,
            'filters': filters,
            'exposureEv': current['exposureEv'],
            'whiteBalanceKelvin': current['whiteBalanceKelvin'],
          };
          final result = ToolResult('实际视频已渲染并回读验证', data: data);
          return guard.commit(permit, () {
            File(temporary).renameSync(outputPath);
            _saveSync({
              ...current,
              'render': data,
              'receipts': {
                ...(current['receipts'] as Map).cast<String, Object?>(),
                context.operationId: result.toJson(),
              },
            });
            actions.add({
              'tool': call.name,
              'sessionId': context.sessionId,
              'operationId': context.operationId,
              'state': data,
            });
            return result;
          });
        } finally {
          if (await File(temporary).exists()) await File(temporary).delete();
        }
      }),
    ),
  ];
}
