import 'package:cutdex_agent/cutdex_agent.dart';
import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_remote_fenced_cancel_validate.dart';
import 'remote_resource_test_processes.dart';

/// Tests a stopped old tree while replacement activation remains unconfirmed.
Future<Map<String, Object?>> validateLeaseWindowModes(
  ModelAdapter model,
) async {
  final cases = <Map<String, Object?>>[];
  for (final fault in [
    RemoteRevokeFault.timeoutBeforeCommit,
    RemoteRevokeFault.lostAcknowledgement,
  ]) {
    for (final depth in [1, 2]) {
      cases.add(
        await validateRemoteFencedCancellation(
          model,
          oldWriterDepth: depth,
          revocationFault: fault,
          protectUnconfirmedWindow: true,
        ),
      );
    }
  }
  return {
    'passed': cases.every((c) => c['passed'] == true),
    'checks': {
      for (final c in cases)
        '${c['revocationFault']}_depth_${c['oldWriterDepth']}':
            c['passed'] == true,
    },
    'cases': cases,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateLeaseWindowModes,
  label: 'REMOTE_LEASE_WINDOW',
);
