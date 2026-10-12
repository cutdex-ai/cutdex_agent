import 'dart:convert';
import 'package:test/test.dart';
import '../../tool/live_remote_admitted_write_validate.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final depth in [1, 2]) {
    test(
      'cancel waits for admitted depth=$depth write before replacement',
      () async {
        final report = await validateAdmittedWriteCancellation(
          uncooperativeModel(oldDirectChild: depth == 1),
          oldWriterDepth: depth,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
  test(
    'validation rejects wrong new goal despite correct cancellation',
    () async {
      final report = await validateAdmittedWriteCancellation(
        uncooperativeModel(oldDirectChild: true),
        oldWriterDepth: 1,
        wrongNewGoal: true,
      );
      expect(report['passed'], isFalse);
      expect((report['checks'] as Map)['newChildActuallyWrote15'], isFalse);
      expect(
        (report['checks'] as Map)['cancelAndDoneStillPendingBeyondLease'],
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
