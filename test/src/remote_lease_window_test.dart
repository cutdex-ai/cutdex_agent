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
        'leased stop blocks old depth=$depth in unconfirmed replacement window (${fault.name})',
        () async {
          final report = await validateRemoteFencedCancellation(
            uncooperativeModel(oldDirectChild: depth == 1),
            oldWriterDepth: depth,
            revocationFault: fault,
            protectUnconfirmedWindow: true,
          );
          expect(
            report['passed'],
            isTrue,
            reason: jsonEncode(report['checks']),
          );
          expect(report['newTaskPolluted'], isFalse);
          expect((report['unconfirmedWindowResource'] as Map)['generation'], 1);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
