import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';

/// Faults injected at the old generation's real HTTP revocation boundary.
enum RemoteRevokeFault { none, timeoutBeforeCommit, lostAcknowledgement }

/// Owns the independent, loopback-only durable resource service used by tests.
class RemoteTestService {
  RemoteTestService._(
    this.process,
    this.lines,
    this.errors,
    this.url,
    this.controlKey,
  );
  final Process process;
  final StreamIterator<String> lines;
  final Future<String> errors;
  final Uri url;
  final String controlKey;
  bool _closed = false;
  static Future<RemoteTestService> start(
    Directory directory,
    String key, {
    int port = 0,
    RemoteRevokeFault revocationFault = RemoteRevokeFault.none,
    Duration? leaseDuration = const Duration(seconds: 10),
    bool holdReplacementActivation = false,
    bool requireOnlineAuthorization = false,
    bool holdAdmittedSave = false,
    bool holdCommittedResponse = false,
  }) async {
    final worker = File.fromUri(
      Directory.current.uri.resolve(
        'test/fixtures/fenced_resource_service.dart',
      ),
    );
    final process = await Process.start('dart', [
      'run',
      worker.path,
      directory.path,
      '$port',
    ], runInShell: Platform.isWindows);
    final errors = utf8.decoder.bind(process.stderr).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stdin.writeln(
      jsonEncode({
        'controlKey': key,
        'revocationFault': revocationFault.name,
        'leaseDurationMs': leaseDuration?.inMilliseconds,
        'holdReplacementActivation': holdReplacementActivation,
        'requireOnlineAuthorization': requireOnlineAuthorization,
        'holdAdmittedSave': holdAdmittedSave,
        'holdCommittedResponse': holdCommittedResponse,
      }),
    );
    await process.stdin.flush();
    try {
      if (!await lines.moveNext().timeout(const Duration(seconds: 30))) {
        throw StateError('Resource service failed: ${await errors}');
      }
      final ready = jsonDecode(lines.current) as Map;
      return RemoteTestService._(
        process,
        lines,
        errors,
        Uri.parse(ready['url'] as String),
        key,
      );
    } catch (_) {
      process.kill();
      await process.exitCode;
      await lines.cancel();
      rethrow;
    }
  }

  Future<Map<String, Object?>> control(String path) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url.resolve('test/$path'));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $controlKey',
      );
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('Fixture control failed');
      }
      return (jsonDecode(await utf8.decoder.bind(response).join()) as Map)
          .cast<String, Object?>();
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    process.stdin.writeln('close');
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      if (code != 0) {
        throw StateError('Resource service exited $code: ${await errors}');
      }
    } finally {
      process.kill();
      await process.exitCode;
      await lines.cancel();
    }
  }

  /// Abruptly kills this owned service without releasing any test save gate.
  Future<int> crash() async {
    if (_closed) throw StateError('Resource service already closed');
    if (!process.kill(ProcessSignal.sigkill)) {
      throw StateError('Could not kill resource service');
    }
    _closed = true;
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    await process.stdin.close();
    await lines.cancel();
    await errors;
    return code;
  }
}

/// Owns a worker that keeps its original portable permit across cancellation.
class RemoteTestSubmitter {
  RemoteTestSubmitter._(this.process, this.lines, this.result, this.waitForGo);
  final Process process;
  final StreamIterator<String> lines;
  final Future<Map<String, Object?>> result;
  final bool waitForGo;
  bool _goSent = false;
  static Future<RemoteTestSubmitter> start(
    Uri url,
    RemoteWritePermit permit,
    String operationId, {
    required bool waitForGo,
  }) async {
    final path = File.fromUri(
      Directory.current.uri.resolve(
        'test/fixtures/remote_resource_submitter.dart',
      ),
    );
    final process = await Process.start('dart', [
      'run',
      path.path,
    ], runInShell: Platform.isWindows);
    final errors = utf8.decoder.bind(process.stderr).join();
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    process.stdin.writeln(
      jsonEncode({
        'url': url.toString(),
        'permit': permit.toJson(),
        'operationId': operationId,
        'waitForGo': waitForGo,
      }),
    );
    await process.stdin.flush();
    try {
      if (!await lines.moveNext().timeout(const Duration(seconds: 30))) {
        throw StateError('Submission worker failed: ${await errors}');
      }
      final ready = jsonDecode(lines.current) as Map;
      if (ready['ready'] != true || ready['pid'] != process.pid) {
        throw StateError('Worker identity mismatch');
      }
      final result = () async {
        if (!await lines.moveNext()) {
          throw StateError('Worker returned no result: ${await errors}');
        }
        final response = (jsonDecode(lines.current) as Map)
            .cast<String, Object?>();
        final code = await process.exitCode;
        if (code != 0) throw StateError('Worker exited $code: ${await errors}');
        await lines.cancel();
        return response;
      }();
      // Cleanup may interrupt a worker; attach a handler immediately.
      unawaited(
        result.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      if (!waitForGo) await process.stdin.close();
      return RemoteTestSubmitter._(process, lines, result, waitForGo);
    } catch (_) {
      process.kill();
      await process.exitCode;
      await lines.cancel();
      rethrow;
    }
  }

  Future<void> go(Uri url) async {
    if (waitForGo && !_goSent) {
      _goSent = true;
      process.stdin.writeln(jsonEncode({'url': url.toString()}));
      await process.stdin.close();
    }
  }

  Future<void> close() async {
    process.kill();
    await process.exitCode;
    try {
      await result;
    } catch (_) {}
  }
}
