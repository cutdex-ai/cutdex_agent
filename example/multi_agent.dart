import 'dart:convert';

import 'package:cutdex_agent/cutdex_agent.dart';

/// A deterministic offline model demonstrating collaboration tool calls.
class CollaborationExampleModel implements ModelAdapter {
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    cancellation.throwIfCancelled();
    if (request.system.contains('You are /root/analyze.')) {
      yield ModelResponse(text: '素材分析：示例素材共 10 秒，适合先展示主体再补充细节。');
    } else if (request.system.contains('You are /root/plan.')) {
      yield ModelResponse(text: '剪辑计划：开场 2 秒、主体 6 秒、收尾 2 秒。');
    } else if (request.messages.length == 1) {
      yield ModelResponse(
        calls: [
          ToolCall(
            id: 'analyze',
            name: 'spawn_agent',
            arguments: {'task_name': 'analyze', 'message': '分析示例素材，返回简短结论。'},
          ),
          ToolCall(
            id: 'plan',
            name: 'spawn_agent',
            arguments: {'task_name': 'plan', 'message': '为 10 秒的示例素材制定剪辑计划。'},
          ),
        ],
      );
    } else if (request.messages.expand((m) => m.calls).last.name ==
        'spawn_agent') {
      yield ModelResponse(
        calls: [
          ToolCall(
            id: 'wait',
            name: 'wait_agent',
            arguments: {'timeout_ms': 10000},
          ),
        ],
      );
    } else {
      final wait = request.messages
          .where((m) => m.role == MessageRole.tool)
          .last;
      final results = (jsonDecode(wait.text) as Map)['data']['agents'] as List;
      yield ModelResponse(
        text: '汇总：\n${results.map((r) => r['output']).join('\n')}',
      );
    }
  }
}

Future<void> main() async {
  final manager = SessionManager(
    model: CollaborationExampleModel(),
    store: InMemorySessionStore(),
    multiAgent: MultiAgentConfig(maxConcurrent: 3),
  );
  final session = await manager.create(system: '你是剪辑助手，根据子代理实际结果汇总。');
  final run = await manager.prompt(session.id, '开启两个子代理，一个分析素材，一个制定剪辑计划，最后汇总。');
  final subscription = run.events.listen((event) {
    if (event.kind == AgentEventKind.toolStarted) print('调用：${event.text}');
  });
  final result = await run.done;
  await subscription.cancel();
  print(result.history.last.text);
  print('状态：${result.status.name}，子代理数：${result.childSessionIds.length}');
}
