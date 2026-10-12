import 'package:cutdex_agent/cutdex_agent.dart';
import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_remote_admitted_write_validate.dart';

/// Tests an admitted, unflushed write across service death and cancellation.
Future<Map<String, Object?>> validateAdmittedCrashModes(
  ModelAdapter model,
) async {
  final cases = <Map<String, Object?>>[];
  for (final cancelAfterCrash in [false, true]) {
    for (final depth in [1, 2]) {
      cases.add(
        await validateAdmittedWriteCancellation(
          model,
          oldWriterDepth: depth,
          crashServiceBeforeSave: true,
          cancelAfterServiceCrash: cancelAfterCrash,
        ),
      );
    }
  }
  return {
    'passed': cases.every((c) => c['passed'] == true),
    'checks': {
      for (final c in cases)
        'depth_${c['oldWriterDepth']}_cancel_${c['cancelAfterServiceCrash'] == true ? 'after' : 'before'}_crash':
            c['passed'] == true,
    },
    'cases': cases,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateAdmittedCrashModes,
  label: 'REMOTE_ADMITTED_CRASH',
);
