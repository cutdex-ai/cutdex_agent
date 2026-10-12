import 'package:cutdex_agent/cutdex_agent.dart';

import 'live_multi_agent_validate.dart' show runLiveValidation;
import 'live_remote_fenced_cancel_validate.dart';
import 'remote_resource_test_processes.dart';

/// Tests immediate task replacement after ambiguous remote revocation failure.
Future<Map<String, Object?>> validateRemoteRevokeFaultModes(
  ModelAdapter model,
) async {
  final reports = <Map<String, Object?>>[];
  for (final fault in [
    RemoteRevokeFault.timeoutBeforeCommit,
    RemoteRevokeFault.lostAcknowledgement,
  ]) {
    for (final depth in [1, 2]) {
      reports.add(
        await validateRemoteFencedCancellation(
          model,
          oldWriterDepth: depth,
          revocationFault: fault,
        ),
      );
    }
  }
  return {
    'passed': reports.every((r) => r['passed'] == true),
    'checks': {
      for (final r in reports)
        '${r['revocationFault']}_depth_${r['oldWriterDepth']}':
            r['passed'] == true,
    },
    'cases': reports,
  };
}

Future<void> main(List<String> args) => runLiveValidation(
  args,
  validateRemoteRevokeFaultModes,
  label: 'REMOTE_REVOKE_FAULT',
);
