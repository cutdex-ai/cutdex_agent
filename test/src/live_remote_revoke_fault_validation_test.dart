import 'dart:convert';

import 'package:test/test.dart';

import '../../tool/live_remote_fenced_cancel_validate.dart';
import '../../tool/remote_resource_test_processes.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final fault in [
    RemoteRevokeFault.timeoutBeforeCommit,
    RemoteRevokeFault.lostAcknowledgement,
  ]) {
    for (final depth in [1, 2]) {
      test(
        'remote ${fault.name} with old depth $depth refuses stale submissions after immediate restart',
        () async {
          final report = await validateRemoteFencedCancellation(
            uncooperativeModel(oldDirectChild: depth == 1),
            oldWriterDepth: depth,
            revocationFault: fault,
          );
          expect(
            report['passed'],
            isTrue,
            reason: jsonEncode(report['checks']),
          );
          expect(report['newTaskPolluted'], isFalse);
          expect((report['cancellationOutcome'] as Map)['error'], isNotNull);
          expect(
            ((report['oldSubmissionResult'] as Map)['result']
                as Map)['isError'],
            isTrue,
          );
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
