import 'package:cutdex_agent/cutdex_agent.dart';

/// Offline example: no API keys, network, cutdex_tools or media dependencies.
class ExampleModel implements ModelAdapter {
  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    cancellation.throwIfCancelled();
    if (request.messages.last.role == MessageRole.tool) {
      yield ModelResponse(text: '素材信息已读取，可以继续规划剪辑。');
    } else {
      yield const TextDelta('正在读取示例素材信息……');
      yield ModelResponse(
        calls: [ToolCall(id: 'probe-1', name: 'inspect_example')],
      );
    }
  }
}

Future<void> main() async {
  final manager = SessionManager(
    model: ExampleModel(),
    store: InMemorySessionStore(),
    tools: [
      AgentTool(
        name: 'inspect_example',
        description: '读取内存中的示例素材信息',
        parameters: {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
        validate: (arguments) => arguments.isEmpty ? null : '不接受参数',
        execute: (_, context) async {
          context.cancellation.throwIfCancelled();
          return ToolResult('示例视频：10 秒', data: {'durationSeconds': 10});
        },
      ),
    ],
  );
  final session = await manager.create(system: '你是剪辑助手，只根据工具的实际结果回答。');
  final run = await manager.prompt(session.id, '看看素材信息');
  final subscription = run.events.listen((event) {
    print('${event.kind.name}: ${event.text}');
  });
  final result = await run.done;
  await subscription.cancel();
  print('结果：${result.status.name}');
}
