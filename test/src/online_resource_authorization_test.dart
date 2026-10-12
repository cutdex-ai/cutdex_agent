import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

void main() {
  late OnlineResourceAuthorization owner;
  late FencedResourceStore resources;
  late RemoteWritePermit root;
  late RemoteWritePermit child;
  late RemoteWritePermit leaf;

  Future<RemoteWritePermit> activate(
    String name, {
    RemoteWritePermit? parent,
  }) async {
    final result = await resources.activate(
      resourceId: 'shared',
      activationId: name,
      sessionId: name,
      runId: name,
      expectedGeneration: parent?.generation ?? 0,
      parentScopeId: parent?.scopeId,
      parentRunId: parent?.runId,
      ownerAuthorization: parent == null ? owner.registration : null,
    );
    expect(result.isError, isFalse);
    final permit = RemoteWritePermit.fromJson(
      (result.data['permit'] as Map).cast<String, Object?>(),
    );
    owner.register(permit, parent: parent);
    return permit;
  }

  setUp(() async {
    owner = await OnlineResourceAuthorization.start();
    resources = FencedResourceStore(
      InMemorySessionStore(),
      initialData: {'a': 99},
      requireOnlineAuthorization: true,
      authorizeCommit: HttpResourceCommitAuthorizer().authorize,
    );
    root = await activate('root');
    child = await activate('child', parent: root);
    leaf = await activate('leaf', parent: child);
  });
  tearDown(() => owner.close());

  test(
    'root gate rejects live child and grandchild with no remote revoke',
    () async {
      owner.stop(root);
      for (final permit in [child, leaf]) {
        expect((await resources.leaseStatus(permit)).data['stopped'], isFalse);
        final result = await resources.commit(
          permit,
          operationId: permit.runId,
          patch: {'a': 10},
        );
        expect(result.data['code'], 'task_commit_admission_closed');
        expect(result.data['executed'], isFalse);
      }
      final state = (await resources.inspect('shared')).data;
      expect(state['generation'], 1);
      expect(state['resourceRevision'], 1);
      expect((state['data'] as Map)['a'], 99);
    },
  );

  test(
    'no cached approval and cancelled ancestor cannot be re-registered',
    () async {
      expect(
        (await resources.commit(
          leaf,
          operationId: 'before',
          patch: {'a': 15},
        )).isError,
        isFalse,
      );
      owner.stop(child);
      owner.register(child, parent: root);
      expect(
        (await resources.commit(
          leaf,
          operationId: 'after',
          patch: {'a': 10},
        )).data['code'],
        'task_commit_admission_closed',
      );
      expect(
        (await resources.commit(
          root,
          operationId: 'root-still-live',
          patch: {'a': 20},
        )).isError,
        isFalse,
      );
    },
  );

  test(
    'owner loss fails closed while durable authorization remains active',
    () async {
      await owner.close();
      expect((await resources.leaseStatus(leaf)).data['stopped'], isFalse);
      expect(
        (await resources.commit(
          leaf,
          operationId: 'offline',
          patch: {'a': 10},
        )).data['code'],
        'online_authorization_unavailable',
      );
      expect((await resources.inspect('shared')).data['resourceRevision'], 1);
    },
  );

  test(
    'mandatory online policy rejects unregistered and historical permits',
    () async {
      final legacy = FencedResourceStore(InMemorySessionStore());
      final result = await legacy.activate(
        resourceId: 'r',
        activationId: 'old',
        sessionId: 's',
        runId: 'old',
        expectedGeneration: 0,
      );
      final permit = RemoteWritePermit.fromJson(
        (result.data['permit'] as Map).cast<String, Object?>(),
      );
      final strict = FencedResourceStore(
        legacy.store,
        requireOnlineAuthorization: true,
        authorizeCommit: HttpResourceCommitAuthorizer().authorize,
      );
      expect(
        (await strict.commit(
          permit,
          operationId: 'old-write',
          patch: {'a': 10},
        )).data['code'],
        'online_authorization_unavailable',
      );
      expect(
        (await strict.activate(
          resourceId: 'new',
          activationId: 'unsigned',
          sessionId: 's',
          runId: 'new',
          expectedGeneration: 0,
        )).data['code'],
        'online_authorization_required',
      );
    },
  );

  test('lease is rechecked after online check inside the write lock', () async {
    var clock = DateTime.utc(2026);
    final delayed = FencedResourceStore(
      InMemorySessionStore(),
      now: () => clock,
      leaseDuration: const Duration(seconds: 1),
      requireOnlineAuthorization: true,
      authorizeCommit: (_, _) async {
        clock = clock.add(const Duration(seconds: 2));
        return null;
      },
    );
    final activation = await delayed.activate(
      resourceId: 'r',
      activationId: 'a',
      sessionId: 's',
      runId: 'r',
      expectedGeneration: 0,
      ownerAuthorization: owner.registration,
    );
    final permit = RemoteWritePermit.fromJson(
      (activation.data['permit'] as Map).cast<String, Object?>(),
    );
    expect(
      (await delayed.commit(
        permit,
        operationId: 'slow',
        patch: {'a': 10},
      )).data['code'],
      'task_write_lease_expired',
    );
    expect((await delayed.inspect('r')).data['resourceRevision'], 1);
  });

  test(
    'revocation acknowledgement drains already admitted resource transaction',
    () async {
      final checking = Completer<void>();
      final release = Completer<void>();
      final gated = FencedResourceStore(
        resources.store,
        requireOnlineAuthorization: true,
        authorizeCommit: (_, _) async {
          checking.complete();
          await release.future;
          return null;
        },
      );
      final commit = gated.commit(
        leaf,
        operationId: 'already-admitted',
        patch: {'a': 15},
      );
      await checking.future;
      var revoked = false;
      final revocation = gated.revoke(root).then((result) {
        revoked = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(revoked, isFalse);
      release.complete();
      expect((await commit).isError, isFalse);
      expect((await revocation).isError, isFalse);
      expect(
        (await gated.commit(
          leaf,
          operationId: 'late',
          patch: {'a': 10},
        )).data['code'],
        'task_write_revoked',
      );
    },
  );

  for (final mode in ['timeout', 'wrongNonce', 'malformed', 'redirect']) {
    test(
      '$mode admission response fails closed without updating data',
      () async {
        final release = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          await request.drain<void>();
          if (mode == 'timeout') await release.future;
          if (mode == 'redirect') {
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              owner.registration['endpoint']!,
            );
          } else {
            request.response.write(
              mode == 'malformed'
                  ? 'invalid JSON'
                  : jsonEncode({'nonce': 'wrong', 'allowed': true}),
            );
          }
          await request.response.close();
        });
        try {
          final faulty = FencedResourceStore(
            InMemorySessionStore(),
            requireOnlineAuthorization: true,
            authorizeCommit: HttpResourceCommitAuthorizer(
              timeout: const Duration(milliseconds: 100),
            ).authorize,
          );
          final activation = await faulty.activate(
            resourceId: 'r',
            activationId: 'a',
            sessionId: 's',
            runId: 'r',
            expectedGeneration: 0,
            ownerAuthorization: {
              'endpoint': 'http://127.0.0.1:${server.port}/authorize',
              'key': 'key',
            },
          );
          final permit = RemoteWritePermit.fromJson(
            (activation.data['permit'] as Map).cast<String, Object?>(),
          );
          expect(
            (await faulty.commit(
              permit,
              operationId: 'bad',
              patch: {'a': 10},
            )).data['code'],
            'online_authorization_unavailable',
          );
          expect((await faulty.inspect('r')).data['resourceRevision'], 1);
        } finally {
          release.complete();
          await server.close(force: true);
        }
      },
    );
  }
}
