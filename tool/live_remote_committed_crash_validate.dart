import 'package:cutdex_agent/cutdex_agent.dart';
import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_remote_admitted_write_validate.dart';

/// Tests lost successful responses after the resource and receipt are flushed.
Future<Map<String, Object?>> validateCommittedCrashModes(
  ModelAdapter model,
) async {
  final cases = <Map<String, Object?>>[];
  for (final depth in [1, 2]) {
    cases.add(
      await validateAdmittedWriteCancellation(
        model,
        oldWriterDepth: depth,
        crashServiceAfterSave: true,
        cancelAfterServiceCrash: true,
      ),
    );
  }
  return {
    'passed': cases.every((c) => c['passed'] == true),
    'checks': {
      for (final c in cases)
        'committed_crash_depth_${c['oldWriterDepth']}': c['passed'] == true,
    },
    'cases': cases,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateCommittedCrashModes,
  label: 'REMOTE_COMMITTED_CRASH',
);
