# cutdex_agent

可嵌入 Dart 或 Flutter 应用的 Agent 运行库。应用提供模型、业务工具和存储，运行库负责调用模型、执行工具、保存会话和管理长任务。本文将使用本包的应用称为“宿主”。

要求 Dart `^3.12.0`。使用 `package:cutdex_agent/cutdex_agent.dart` 接入平台无关的核心；使用 `package:cutdex_agent/io.dart` 接入 HTTP 模型适配器和磁盘存储。

## 能力

- **会话与运行**：流式事件、追加指令、暂停、取消及中断恢复。
- **工具执行**：参数校验、串行调用、进度通知和中断后结果查询。
- **长任务**：按需加载工具、分页读取大结果、保存计划和自动摘要。
- **存储**：内存存储和磁盘日志，支持并发写入保护和中断恢复。
- **完成核验**：可注入只读检查器，核验失败后继续当前任务。
- **多代理**：可选的模型协作工具，支持并行子任务、消息、追加任务、等待、中断及结果汇总。
- **扩展**：技能、按范围检索的记忆，以及宿主显式委派的子任务。

## 快速开始

当前包设置了 `publish_to: none`。若宿主与本包位于同一父目录，可在宿主的 `pubspec.yaml` 中加入本地依赖：

```yaml
dependencies:
  cutdex_agent:
    path: ../cutdex_agent
```

在宿主目录运行 `dart pub get`；Flutter 宿主使用 `flutter pub get`。

用模型、工具和存储创建 `SessionManager`，再创建会话并发送任务：

```dart
import 'package:cutdex_agent/cutdex_agent.dart';

Future<SessionSnapshot> runTask({
  required ModelAdapter model,
  required List<AgentTool> tools,
  required String prompt,
  required void Function(AgentEvent) onEvent,
}) async {
  final manager = SessionManager(
    model: model,
    store: InMemorySessionStore(),
    tools: tools,
  );
  final session = await manager.create(
    system: '根据用户目标调用可用工具，核对结果后报告完成情况。',
  );
  final run = await manager.prompt(session.id, prompt);
  final subscription = run.events.listen(onEvent);
  try {
    return await run.done;
  } finally {
    await subscription.cancel();
  }
}
```

`InMemorySessionStore` 适合示例和进程内使用；跨进程恢复需使用 `FileSessionStore` 或实现 `SessionStore`。宿主应复用管理器及会话 ID，以便在同一会话中继续对话。

包内提供无需密钥的 [离线示例](example/main.dart)：

```sh
dart pub get
dart run example/main.dart
```

## 模型自主委派子代理

给 `SessionManager` 配置 `multiAgent`，模型即可根据用户请求调用协作工具，无需宿主自行包装委派工具：

```dart
final manager = SessionManager(
  model: model,
  store: store,
  tools: tools,
  multiAgent: MultiAgentConfig(maxConcurrent: 3),
);
final session = await manager.create(system: '根据用户目标分工并核对结果。');
final run = await manager.prompt(
  session.id,
  '开启两个子代理，一个分析素材，一个制定剪辑计划，最后汇总结果。',
);
final result = await run.done;
```

默认不启用。启用后提供 `spawn_agent`、`send_message`、`followup_task`、`wait_agent`、`list_agents` 和 `interrupt_agent`。子代理共享模型和工具，分别保存历史；创建工具立即返回 ID，结果由等待工具或完成前的运行通知交给主代理汇总。详见 [多代理协作](docs/multi-agent.md)。

共享资源写工具可接入 `ResourceCommitGuard`：向管理器传入 `resourceCommitGuard`，工具开始时签发凭证，在 `guard.commit` 的同步回调内实际写入。根任务取消或切换代次后，旧子代理和孙代理的后台提交被拒绝；使用边界及示例见 [运行控制](docs/runtime.md)。

跨进程和 HTTP 资源可使用 `RemoteResourceTaskAuthority` 与 `FencedResourceStore`，由资源端持久化校验代次及父子权限，并把校验、业务值与操作回执放在同一事务中。接入方式见 [资源提交保护](docs/resource-fencing.md)。

需要在取消等待期间也拒绝旧提交时，两端启用 `OnlineResourceAuthorization` 与 `requireOnlineAuthorization`。取消同步关闭整棵树的准入，资源端每次提交在线核对；即使旧租约尚未到期也会拒绝，查询失败同样拒绝。取消前已批准的在途事务需等待落盘及停止确认。

主代理还可通过 `request_user_input` 询问互斥目标的取舍。运行进入持久化的 `waitingUser` 状态并停止活动子任务；宿主展示 `pendingUserInput`，收到选择后调用 `answerUserInput()`，继续同一个任务。直接 `resume()` 会继续等待答案。

无需密钥的示例：`dart run example/multi_agent.dart`。

## 宿主接口

| 接口 | 宿主提供的内容 |
| --- | --- |
| `ModelAdapter` | 模型响应流；也可使用 IO 入口的 Chat Completions、Responses 或 Anthropic Messages 适配器 |
| `AgentTool` | 工具说明、参数 schema、`validate`、`execute` 和可选 `recover` |
| `SessionStore` | 会话读写和并发保护；可直接使用内置内存或磁盘存储 |
| `CompletionCheck` | 读取实际业务状态，返回验收证据或需要修复的问题 |
| `SkillProvider` | 技能目录与宿主选定技能的正文 |
| `MemoryProvider` | 按宿主指定范围检索、写入和删除记忆 |

在业务工具中实现授权、事务和重复操作保护。工具失败与恢复的处理方式见 [运行控制](docs/runtime.md)。

## 宿主配置

- 工具串行执行。提供参数 schema 帮助模型构造调用，并实现 `validate` 校验运行参数。
- 按模型窗口设置输入与输出预算；需要精确计数时，通过 `countTokens` 注入 tokenizer。
- 在模型与工具实现中响应取消信号，及时释放客户端资源。
- 选择技能 ID 并提供正文；按业务需求显式写入和删除记忆。
- 使用 `multiAgent` 启用模型自主协作；使用 `AgentCoordinator.delegate()` 显式委派时，子工具集合须属于父工具集合，并由宿主协调恢复和结果汇总。

> ⚠️ 默认 token 计数为估算，应按实际模型配置预算。

## 按任务查阅

| 你要做的事 | 文档 |
| --- | --- |
| 连接模型、选择 HTTP 协议 | [模型适配器](docs/model-adapters.md) |
| 追加指令、暂停、取消、恢复和核验完成 | [运行控制](docs/runtime.md) |
| 让模型创建、协调子代理并汇总结果 | [多代理协作](docs/multi-agent.md) |
| 调整工具发现、结果回读和上下文预算 | [长任务与上下文](docs/long-running-agent.md) |
| 保存会话、验证日志和迁移旧格式 | [会话存储](docs/session-storage.md) |
| 理解模块职责、恢复与完成核验 | [架构](docs/architecture.md) |
| 运行离线测试和真实模型检查 | [测试指南](docs/testing.md) |

## 开发验证

在包目录运行：

```sh
dart test
dart analyze
dart format --output=none --set-exit-if-changed lib test example tool
```

默认测试使用模拟模型、本地 HTTP 服务和临时存储，无需外部模型凭据。真实模型检查需要显式配置，范围见测试指南。
