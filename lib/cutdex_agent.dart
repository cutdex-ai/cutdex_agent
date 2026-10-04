/// Embeddable agent execution with injected models, tools and persistence.
library;

export 'src/context/context.dart';
export 'src/context/summary.dart';
export 'src/context/model_summarizer.dart';
export 'src/coordinator/coordinator.dart';
export 'src/events/events.dart';
export 'src/memory/memory.dart';
export 'src/model/adapter.dart';
export 'src/model/messages.dart' hide freezeJson;
export 'src/run/agent_run.dart';
export 'src/run/cancellation.dart';
export 'src/session/manager.dart';
export 'src/session/snapshot.dart';
export 'src/skills/skills.dart';
export 'src/storage/store.dart';
export 'src/tools/tool.dart';

export 'src/run/diagnostics.dart';

export 'src/context/harness_context.dart';

export 'src/run/completion_check.dart';
