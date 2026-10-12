import 'dart:convert';
import 'package:test/test.dart';
import '../../tool/live_remote_fenced_cancel_validate.dart';
import '../../tool/remote_resource_test_processes.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final depth in [1, 2]) {
    test(
      'valid old depth=$depth permit cannot write during cancel wait',
      () async {
        final report = await validateRemoteFencedCancellation(
          uncooperativeModel(oldDirectChild: depth == 1),
          oldWriterDepth: depth,
          revocationFault: RemoteRevokeFault.timeoutBeforeCommit,
          protectUnconfirmedWindow: true,
          protectCancellationWaiting: true,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
