import 'package:cutdex_agent/cutdex_agent.dart';

import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_uncooperative_cancel_validate.dart';

/// Tests guarded delayed submissions from both direct children and grandchildren.
Future<Map<String, Object?>> validateGuardedCancellation(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final depth in [1, 2]) {
    reports.add(
      await validateUncooperativeCancellation(
        model,
        mode: UncooperativeMode.detachedWrite,
        guarded: true,
        oldWriterDepth: depth,
      ),
    );
  }
  reports.add(
    await validateUncooperativeCancellation(
      model,
      mode: UncooperativeMode.pendingWrite,
      guarded: true,
    ),
  );
  return {
    'passed': reports.every(
      (r) => r['passed'] == true && r['newTaskPolluted'] == false,
    ),
    'checks': {
      for (final r in reports)
        '${r['mode']}_depth_${r['oldWriterDepth']}':
            r['passed'] == true && r['newTaskPolluted'] == false,
    },
    'cases': reports,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateGuardedCancellation,
  label: 'GUARDED_CANCEL',
);
