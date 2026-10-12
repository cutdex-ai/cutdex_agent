import 'dart:convert';
import 'package:test/test.dart';
import '../../tool/live_remote_admitted_write_validate.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final cancelAfterCrash in [false, true]) {
    for (final depth in [1, 2]) {
      test(
        'admitted depth=$depth service crash (cancel after=$cancelAfterCrash)',
        () async {
          final report = await validateAdmittedWriteCancellation(
            uncooperativeModel(oldDirectChild: depth == 1),
            oldWriterDepth: depth,
            crashServiceBeforeSave: true,
            cancelAfterServiceCrash: cancelAfterCrash,
          );
          expect(
            report['passed'],
            isTrue,
            reason: jsonEncode(report['checks']),
          );
          expect(report['newTaskPolluted'], isFalse);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
