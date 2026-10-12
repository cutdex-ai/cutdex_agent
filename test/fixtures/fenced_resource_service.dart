import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

Future<void> main(List<String> args) async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await input.moveNext()) {
    throw StateError('Service configuration missing');
  }
  final config = jsonDecode(input.current) as Map;
  final key = config['controlKey'] as String;
  final revocationFault = config['revocationFault'] as String? ?? 'none';
  final ttl = config['leaseDurationMs'] as int?;
  final gatedStore = _PreSaveGate(
    FileSessionStore(Directory(args[0])),
    enabled: config['holdAdmittedSave'] == true,
  );
  final onlineChecks = <Map<String, Object?>>[];
  final authorizer = HttpResourceCommitAuthorizer();
  final resources = FencedResourceStore(
    gatedStore,
    initialData: {'a': 99},
    leaseDuration: ttl == null ? null : Duration(milliseconds: ttl),
    authorizeCommit: (registration, permit) async {
      final denial = await authorizer.authorize(registration, permit);
      onlineChecks.add({
        'scopeId': permit.scopeId,
        'runId': permit.runId,
        'generation': permit.generation,
        'allowed': denial == null,
        'code': denial,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      return denial;
    },
    requireOnlineAuthorization: config['requireOnlineAuthorization'] == true,
  );
  final handler = FencedResourceHttpHandler(resources, controlKey: key);
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    int.parse(args[1]),
  );
  final release = Completer<void>();
  final releaseRevokes = Completer<void>();
  final releaseActivation = Completer<void>();
  final releaseResponse = Completer<void>();
  Map<String, Object?>? pendingResponse;
  var activationsHeld = 0;
  final revokeFaults = <Map<String, Object?>>[];
  var held = 0;
  server.listen((request) async {
    try {
      if (request.uri.path.startsWith('/test/')) {
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            'Bearer $key') {
          request.response.statusCode = 401;
        } else {
          await request.drain<void>();
          if (request.uri.path == '/test/release' && !release.isCompleted) {
            release.complete();
          }
          if (request.uri.path == '/test/release_revokes' &&
              !releaseRevokes.isCompleted) {
            releaseRevokes.complete();
          }
          if (request.uri.path == '/test/release_save') gatedStore.resume();
          if (request.uri.path == '/test/release_response' &&
              !releaseResponse.isCompleted) {
            releaseResponse.complete();
          }
          final snapshot = await resources.store.read('shared');
          if (request.uri.path == '/test/release_activation' &&
              !releaseActivation.isCompleted) {
            releaseActivation.complete();
          }
          final scopes = (snapshot?.agentState['scopes'] as Map? ?? const {})
              .values
              .cast<Map>();
          final activeScopeCounts = <String, int>{};
          for (final scope in scopes) {
            if (scope['active'] == true) {
              final generation = '${(scope['permit'] as Map)['generation']}';
              activeScopeCounts.update(
                generation,
                (v) => v + 1,
                ifAbsent: () => 1,
              );
            }
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'held': held,
              'pid': pid,
              'revokeFaults': revokeFaults,
              'activeScopeCounts': activeScopeCounts,
              'replacementActivationsHeld': activationsHeld,
              'onlineChecks': onlineChecks,
              'pendingSave': gatedStore.pending,
              'saveCompleted': gatedStore.completed,
              'pendingResponse': pendingResponse,
              'durableResource': snapshot == null
                  ? null
                  : {
                      'data': snapshot.agentState['data'],
                      'generation': snapshot.agentState['generation'],
                      'resourceRevision':
                          snapshot.agentState['resourceRevision'],
                    },
            }),
          );
        }
        await request.response.close();
      } else {
        if (request.uri.path == '/activate' &&
            config['holdReplacementActivation'] == true &&
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer $key') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (body['parentScopeId'] == null &&
              (body['expectedGeneration'] as int) > 0) {
            activationsHeld++;
            await releaseActivation.future;
          }
          final result = await resources.activate(
            resourceId: body['resourceId'] as String,
            activationId: body['activationId'] as String,
            sessionId: body['sessionId'] as String,
            runId: body['runId'] as String,
            expectedGeneration: body['expectedGeneration'] as int,
            parentScopeId: body['parentScopeId'] as String?,
            parentRunId: body['parentRunId'] as String?,
            active: body['active'] as bool? ?? true,
            ownerAuthorization: (body['ownerAuthorization'] as Map?)
                ?.cast<String, Object?>(),
          );
          request.response.statusCode = result.isError ? 409 : 200;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result.toJson()));
          await request.response.close();
          return;
        }
        if (request.uri.path == '/revoke' &&
            revocationFault != 'none' &&
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer $key') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final permit = RemoteWritePermit.fromJson(
            (body['permit'] as Map).cast<String, Object?>(),
          );
          if (permit.generation == 1) {
            final event = <String, Object?>{
              'mode': revocationFault,
              'runId': permit.runId,
              'scopeId': permit.scopeId,
              'generation': permit.generation,
              'applied': false,
            };
            revokeFaults.add(event);
            if (revocationFault == 'timeoutBeforeCommit') {
              await releaseRevokes.future;
            }
            final result = await resources.revoke(permit);
            event['applied'] = !result.isError;
            event['currentGenerationAtApply'] = (await resources.inspect(
              permit.resourceId,
            )).data['generation'];
            if (revocationFault == 'lostAcknowledgement') {
              event['acknowledgementDropped'] = true;
              final socket = await request.response.detachSocket(
                writeHeaders: false,
              );
              socket.destroy();
            } else {
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode(result.toJson()));
              await request.response.close();
            }
            return;
          }
          // Generation two is healthy, so the new task can settle normally.
          final result = await resources.revoke(permit);
          request.response.statusCode = result.isError ? 409 : 200;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result.toJson()));
          await request.response.close();
          return;
        }
        if (request.uri.path == '/commit' &&
            request.headers.value('x-test-delay') == '1') {
          held++;
          await release.future;
        }
        if (request.uri.path == '/commit' &&
            config['holdCommittedResponse'] == true) {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          final permit = RemoteWritePermit.fromJson(
            (body['permit'] as Map).cast<String, Object?>(),
          );
          // The actual transaction has saved and released its resource lock
          // before this gate; no response headers or body have been sent.
          final result = await resources.commit(
            permit,
            operationId: body['operationId'] as String,
            patch: (body['patch'] as Map).cast<String, Object?>(),
          );
          if (permit.generation == 1 && !result.isError) {
            pendingResponse = {
              'operationId': body['operationId'],
              'runId': permit.runId,
              'generation': permit.generation,
              'responseSent': false,
              'result': result.toJson(),
              'enteredAt': DateTime.now().toUtc().toIso8601String(),
            };
            await releaseResponse.future;
          }
          request.response.statusCode = result.isError ? 409 : 200;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(result.toJson()));
          await request.response.close();
          return;
        }
        await handler.handle(request);
      }
    } catch (_) {
      stderr.writeln('Service request failed');
    }
  });
  stdout.writeln(
    jsonEncode({'url': 'http://127.0.0.1:${server.port}/', 'pid': pid}),
  );
  await stdout.flush();
  try {
    while (await input.moveNext()) {
      if (input.current == 'close') break;
    }
  } finally {
    gatedStore.resume();
    if (!release.isCompleted) release.complete();
    if (!releaseRevokes.isCompleted) releaseRevokes.complete();
    if (!releaseActivation.isCompleted) releaseActivation.complete();
    if (!releaseResponse.isCompleted) releaseResponse.complete();
    await server.close(force: true);
    await input.cancel();
  }
}

/// Pauses an admitted old write immediately before calling durable storage.
class _PreSaveGate implements SessionStore {
  _PreSaveGate(this.delegate, {required this.enabled});
  final FileSessionStore delegate;
  final bool enabled;
  final _release = Completer<void>();
  Map<String, Object?>? pending;
  bool completed = false;
  void resume() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<SessionSnapshot?> read(String id) => delegate.read(id);
  @override
  Future<Object> acquire(String id) => delegate.acquire(id);
  @override
  Future<void> release(String id, Object lease) => delegate.release(id, lease);
  @override
  Future<void> save(
    SessionSnapshot snapshot, {
    required int? expectedRevision,
  }) async {
    final last = (snapshot.agentState['audit'] as List?)?.lastOrNull as Map?;
    if (enabled &&
        pending == null &&
        last?['kind'] == 'committed' &&
        last?['generation'] == 1) {
      pending = {
        'operationId': last!['operationId'],
        'runId': last['runId'],
        'generation': last['generation'],
        'admittedData': snapshot.agentState['data'],
        'admittedBusinessRevision': snapshot.agentState['resourceRevision'],
        'enteredAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _release.future;
      await delegate.save(snapshot, expectedRevision: expectedRevision);
      completed = true;
      return;
    }
    await delegate.save(snapshot, expectedRevision: expectedRevision);
  }
}
