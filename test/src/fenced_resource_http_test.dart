import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late FencedResourceStore resources;
  late FencedResourceClient control;
  late FencedResourceClient worker;
  var dropCommitResponse = false;
  setUp(() async {
    dropCommitResponse = false;
    resources = FencedResourceStore(
      InMemorySessionStore(),
      initialData: {'a': 99},
    );
    final handler = FencedResourceHttpHandler(
      resources,
      controlKey: 'control-only',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (dropCommitResponse && request.uri.path == '/commit') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        await resources.commit(
          RemoteWritePermit.fromJson(
            (body['permit'] as Map).cast<String, Object?>(),
          ),
          operationId: body['operationId'] as String,
          patch: (body['patch'] as Map).cast<String, Object?>(),
        );
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      } else {
        await handler.handle(request);
      }
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}/');
    control = FencedResourceClient(
      baseUrl: url,
      resourceId: 'shared',
      controlKey: 'control-only',
    );
    worker = FencedResourceClient(baseUrl: url, resourceId: 'shared');
  });
  tearDown(() async {
    await server.close(force: true);
  });
  Future<RemoteWritePermit> permit() => control.activate(
    activationId: 'root',
    sessionId: 'root',
    runId: 'root-run',
    expectedGeneration: 0,
  );

  test(
    'worker credential can submit but cannot rotate, revoke or inspect authority',
    () async {
      final credential = await permit();
      expect(
        (await worker.commit(
          credential,
          operationId: 'write',
          patch: {'a': 15},
        )).isError,
        isFalse,
      );
      await expectLater(
        worker.activate(
          activationId: 'forged-control',
          sessionId: 'old',
          runId: 'old',
          expectedGeneration: 1,
        ),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        worker.revoke(credential),
        throwsA(isA<HttpException>()),
      );
      await expectLater(worker.inspect(), throwsA(isA<HttpException>()));
      await expectLater(
        worker.renew(credential, 'forged', credential.initialExpiryMs!),
        throwsA(isA<HttpException>()),
      );
      expect((await control.inspect()).data['generation'], 1);
    },
  );
  test(
    'server-side fence rejects a captured credential after root rotation',
    () async {
      final old = await permit();
      final fresh = await control.activate(
        activationId: 'fresh',
        sessionId: 'root',
        runId: 'new',
        expectedGeneration: 1,
      );
      await worker.commit(fresh, operationId: 'fresh-write', patch: {'a': 15});
      final stale = await worker.commit(
        old,
        operationId: 'old-write',
        patch: {'a': 10},
      );
      expect(stale.data['code'], 'stale_task_generation');
      expect(stale.data['executed'], isFalse);
      expect((await control.inspect()).data['resourceRevision'], 2);
    },
  );
  test(
    'lost response recovers a persisted receipt without replaying business write',
    () async {
      final credential = await permit();
      dropCommitResponse = true;
      await expectLater(
        worker.commit(
          credential,
          operationId: 'lost-response',
          patch: {'a': 15},
        ),
        throwsA(anything),
      );
      dropCommitResponse = false;
      final recovered = await worker.recover(credential, 'lost-response');
      expect(recovered.status, RecoveryStatus.completed);
      expect((recovered.result!.data['data'] as Map)['a'], 15);
      expect((await control.inspect()).data['resourceRevision'], 2);
      expect(
        (await worker.recover(credential, 'possibly-in-flight')).status,
        RecoveryStatus.unknown,
      );
    },
  );
}
