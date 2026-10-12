import 'dart:convert';

import 'package:test/test.dart';

import '../../tool/live_remote_fenced_cancel_validate.dart';
import 'live_uncooperative_cancel_validation_test.dart' show uncooperativeModel;

void main() {
  for (final restart in [false, true]) {
    for (final depth in [1, 2]) {
      test(
        'real worker/server processes reject old depth=$depth restart=$restart',
        () async {
          final report = await validateRemoteFencedCancellation(
            uncooperativeModel(oldDirectChild: depth == 1),
            oldWriterDepth: depth,
            restartService: restart,
          );
          expect(
            report['passed'],
            isTrue,
            reason: jsonEncode(report['checks']),
          );
          expect(report['newTaskPolluted'], isFalse);
          expect(((report['finalResource'] as Map)['data'] as Map)['a'], 15);
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}
