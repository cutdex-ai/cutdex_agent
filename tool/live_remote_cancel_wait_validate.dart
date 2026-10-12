import 'package:cutdex_agent/cutdex_agent.dart';
import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_remote_fenced_cancel_validate.dart';
import 'remote_resource_test_processes.dart';

/// Tests old writes while cancellation waits and portable leases remain valid.
Future<Map<String, Object?>> validateCancelWaitModes(ModelAdapter model) async {
  final cases = <Map<String, Object?>>[];
  for (final depth in [1, 2]) {
    cases.add(
      await validateRemoteFencedCancellation(
        model,
        oldWriterDepth: depth,
        revocationFault: RemoteRevokeFault.timeoutBeforeCommit,
        protectUnconfirmedWindow: true,
        protectCancellationWaiting: true,
      ),
    );
  }
  return {
    'passed': cases.every((c) => c['passed'] == true),
    'checks': {
      for (final c in cases)
        'cancel_wait_depth_${c['oldWriterDepth']}': c['passed'] == true,
    },
    'cases': cases,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateCancelWaitModes,
  label: 'REMOTE_CANCEL_WAIT',
);
