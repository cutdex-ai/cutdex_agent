import 'dart:async';
import 'dart:io';

import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import '../../tool/remote_resource_test_processes.dart';

void main() {
  for (final fault in [
    RemoteRevokeFault.timeoutBeforeCommit,
    RemoteRevokeFault.lostAcknowledgement,
  ]) {
    test(
      '${fault.name}: authoritative permission before and after replacement generation',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'cutdex-revoke-boundary-',
        );
        RemoteTestService? service;
        try {
          service = await RemoteTestService.start(
            directory,
            'test-control',
            revocationFault: fault,
            leaseDuration: null,
          );
          final control = FencedResourceClient(
            baseUrl: service.url,
            resourceId: 'shared',
            controlKey: 'test-control',
            requestTimeout: const Duration(seconds: 1),
          );
          final worker = FencedResourceClient(
            baseUrl: service.url,
            resourceId: 'shared',
          );
          final root = await control.activate(
            activationId: 'old',
            sessionId: 'root',
            runId: 'old',
            expectedGeneration: 0,
          );
          final child = await control.activate(
            activationId: 'child',
            sessionId: 'child',
            runId: 'child',
            expectedGeneration: 1,
            parent: root,
          );
          final leaf = await control.activate(
            activationId: 'leaf',
            sessionId: 'leaf',
            runId: 'leaf',
            expectedGeneration: 1,
            parent: child,
          );
          await expectLater(
            control.revoke(root),
            throwsA(
              fault == RemoteRevokeFault.timeoutBeforeCommit
                  ? isA<TimeoutException>()
                  : anyOf(isA<HttpException>(), isA<SocketException>()),
            ),
          );
          // No replacement root has been acknowledged yet. A network timeout is
          // not proof that the resource end revoked the old tree.
          final gapWrite = await worker.commit(
            leaf,
            operationId: 'before-new-generation',
            patch: {'a': 10},
          );
          if (fault == RemoteRevokeFault.timeoutBeforeCommit) {
            expect(gapWrite.isError, isFalse);
            expect((gapWrite.data['data'] as Map)['a'], 10);
          } else {
            expect(gapWrite.data['code'], 'task_write_revoked');
            expect(gapWrite.data['executed'], isFalse);
          }
          final fresh = await control.activate(
            activationId: 'new',
            sessionId: 'root',
            runId: 'new',
            expectedGeneration: 1,
          );
          await worker.commit(fresh, operationId: 'new-goal', patch: {'a': 15});
          await service.control('release_revokes');
          var applied = false;
          for (var i = 0; i < 100 && !applied; i++) {
            final state = await service.control('state');
            applied = (state['revokeFaults'] as List).cast<Map>().every(
              (f) =>
                  f['applied'] == true && f['currentGenerationAtApply'] != null,
            );
            if (!applied) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          expect(applied, isTrue);
          final stale = await worker.commit(
            leaf,
            operationId: 'after-new-generation',
            patch: {'a': 20},
          );
          expect(stale.data['code'], 'stale_task_generation');
          expect(stale.data['executed'], isFalse);
          final actual = (await control.inspect()).data;
          expect((actual['data'] as Map)['a'], 15);
          expect(actual['generation'], 2);
          expect(
            actual['resourceRevision'],
            fault == RemoteRevokeFault.timeoutBeforeCommit ? 3 : 2,
          );
        } finally {
          if (service != null) {
            await service.control('release_revokes');
            await service.close();
          }
          await directory.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }
}
