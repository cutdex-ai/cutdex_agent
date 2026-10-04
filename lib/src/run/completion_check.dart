import '../session/snapshot.dart';
import '../tools/tool.dart';
import 'cancellation.dart';

/// Host-owned, read-only check of current artifacts before a run completes.
/// Return an error with actionable differences to continue within the same
/// turn budget. Unavailable evidence must not be reported as success.
typedef CompletionCheck =
    Future<ToolResult> Function(
      SessionSnapshot snapshot,
      CancellationToken cancellation,
    );
