import 'dart:io';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

import '../../tool/remote_resource_test_processes.dart';

Future<T> retryLease<T>(Future<T> Function() action) async {
  for (var i = 0; i < 20; i++) {
    try {
      return await action();
    } on HttpException {
      if (i == 19) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }
  throw StateError('Unreachable retry');
}

void main() {
  test(
    'two resource server processes share durable fences and operation receipts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'cutdex-two-resource-servers-',
      );
      RemoteTestService? first;
      RemoteTestService? second;
      try {
        first = await RemoteTestService.start(directory, 'test-control');
        second = await RemoteTestService.start(directory, 'test-control');
        expect(first.process.pid, isNot(second.process.pid));
        final a = FencedResourceClient(
          baseUrl: first.url,
          resourceId: 'shared',
          controlKey: 'test-control',
        );
        final b = FencedResourceClient(
          baseUrl: second.url,
          resourceId: 'shared',
          controlKey: 'test-control',
        );
        final root = await a.activate(
          activationId: 'root',
          sessionId: 'root',
          runId: 'old',
          expectedGeneration: 0,
        );
        final child = await b.activate(
          activationId: 'child',
          sessionId: 'child',
          runId: 'child',
          expectedGeneration: 1,
          parent: root,
        );
        final fresh = await b.activate(
          activationId: 'new',
          sessionId: 'root',
          runId: 'new',
          expectedGeneration: 1,
        );
        final writes = await Future.wait([
          retryLease(
            () => a.commit(
              fresh,
              operationId: 'same-operation',
              patch: {'a': 15},
            ),
          ),
          retryLease(
            () => b.commit(
              fresh,
              operationId: 'same-operation',
              patch: {'a': 15},
            ),
          ),
        ]);
        expect(writes.every((r) => !r.isError), isTrue);
        expect(
          (await a.commit(
            child,
            operationId: 'old-late',
            patch: {'a': 10},
          )).data['code'],
          'stale_task_generation',
        );
        await a.revoke(root);
        final actual = (await b.inspect()).data;
        expect((actual['data'] as Map)['a'], 15);
        expect(actual['generation'], 2);
        expect(actual['resourceRevision'], 2);
        expect(
          (actual['audit'] as List).where(
            (a) => (a as Map)['kind'] == 'committed',
          ),
          hasLength(1),
        );
      } finally {
        await first?.close();
        await second?.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
