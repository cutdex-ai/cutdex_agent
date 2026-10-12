import 'dart:convert';
import 'package:test/test.dart';
import '../../tool/live_remote_admitted_write_validate.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final depth in [1, 2]) {
    test(
      'committed depth=$depth write survives crash without duplicate retry',
      () async {
        final report = await validateAdmittedWriteCancellation(
          uncooperativeModel(oldDirectChild: depth == 1),
          oldWriterDepth: depth,
          crashServiceAfterSave: true,
          cancelAfterServiceCrash: true,
        );
        expect(report['passed'], isTrue, reason: jsonEncode(report['checks']));
        expect((report['unknownRecovery'] as Map)['status'], 'completed');
        expect((report['recoveryDuringNewTask'] as Map)['status'], 'completed');
        expect((report['finalResource'] as Map)['resourceRevision'], 3);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
