# 模型自主多代理协作

`SessionManager.multiAgent` 将子代理协作接入模型工具循环。参考 [OpenAI 多代理协作文档](https://developers.openai.com/api/docs/guides/responses-multi-agent) 的创建、消息、追加任务、等待、列表和中断语义，调度由本库在 Dart 进程内执行，适用于支持工具调用的现有模型适配器。无需启用模型服务端的托管多代理功能。

## 接入

```dart
final manager = SessionManager(
  model: model,
  store: store,
  tools: tools,
  multiAgent: MultiAgentConfig(
    maxConcurrent: 3,
    maxDepth: 3,
    maxChildren: 16,
    maxDelegatedTurns: 80,
    childMaxTurns: 10,
  ),
);
final session = await manager.create(system: '分配独立任务并核对结果。');
final run = await manager.prompt(
  session.id,
  '开启两个子代理，一个分析素材，一个制定剪辑计划，最后汇总。',
);
final result = await run.done;
```

`multiAgent` 默认为 `null`，不会提供协作工具。启用后，当前深度可用的协作工具始终出现在默认上下文构建器的模型请求里，不需要先调用 `tool_search`。达到 `maxDepth` 时不再向模型提供 `spawn_agent`，其余协作工具仍可用。自定义上下文构建器应保留 `AgentTool.alwaysAvailable` 为 `true` 的工具。

离线示例：

```sh
dart run example/multi_agent.dart
```

示例用确定性模型演示完整调用流程。真实模型是否选择委派、如何拆分任务取决于提示和模型能力；宿主仍负责提供完成任务所需的业务工具。

## 协作工具

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `spawn_agent` | `task_name`、`message`；可选 `fork_turns`、`max_turns` | 创建独立子会话，启动后立即返回 `agent_id` 和状态 |
| `send_message` | `target`、`message` | 将消息放入持久化邮箱，在下一次模型请求前读取；不启动空闲代理 |
| `followup_task` | `target`、`message`；可选 `max_turns` | 给活动子任务追加指令；给空闲子任务开启新 Run，或继续暂停/等待的 Run |
| `wait_agent` | 可选 `targets`、`timeout_ms` | 等待任一目标结束或超时，返回各目标状态、输出和错误；省略目标表示所有直接子任务 |
| `list_agents` | 无 | 返回直接子任务的身份和状态 |
| `interrupt_agent` | `target` | 协作取消子任务当前 Run 并等待结束；之后仍可追加任务 |
| `request_user_input` | `question`、`options: [{id, label}]`；可选 `reason` | 仅主代理可用；保存问题、停止活动子任务并等待宿主提交答案 |

`target` 支持返回的 `agent_id`、完整名称（例如 `/root/analyze`）或直接子任务的短名称（例如 `analyze`）。控制范围为当前父 Run 的直接子任务；`send_message` 还支持 `target: "parent"`。不能控制其他会话、兄弟代理或上一父 Run 的子任务。

`task_name` 必须以小写字母开头，其余为小写字母、数字或下划线，最多 64 个字符。同一父 Run 不能重复创建同名任务；使用 `followup_task` 复用现有子代理。

`fork_turns` 默认为 `none`，子代理仅得到指定任务，以及继承的 system、技能 ID 和记忆范围。`all` 复制父会话中完整的消息历史，排除尚未完成的当前工具调用批次。新历史与父历史分别持久化，模型请求仍受上下文预算约束。

运行指令明确区分主代理与子代理：子代理只执行本轮分配的任务及后续父消息，复制的父消息、计划和工具调用作为背景，不能重新执行或接管整个根任务。对于独立、范围明确的任务，优先使用 `fork_turns: "none"`。

## 并发、预算和结果

所有子代理使用该管理器的模型、业务工具和上下文构建器。子代理可以继续创建子任务。并发额度在管理器内共享，孙级任务也占用额度；根任务不占子代理额度。达到并发限制时，创建返回模型可见错误，模型可以先等待已有子任务完成。

`maxChildren` 和 `maxDelegatedTurns` 按父 Run 限制。创建任务和为空闲子代理追加任务时预留模型轮次，而非按实际消耗扣费。`followup_task.max_turns` 对空闲任务生效：新 Run 使用该额度，暂停/等待的 Run 在已用轮次基础上增加额度；活动任务继续使用原额度。新父 Run 重置自己的数量、预算和操作记录。

根会话开始新任务时，上一个 Run 尚未读取的子代理邮箱消息会原子归入此前的历史，位于新 `runStart` 之前，并清空当前邮箱。消息仍可作为背景查阅，但不会被重新投递为新任务的运行通知。子代理接受同一父 Run 的追加任务时，仍保留其父代理此前排队的消息。

创建成功只表示已启动。`wait_agent` 默认等待 10 秒，允许 0–60000 毫秒，0 表示立即读取。输出中 `active` 表示仍有运行实例，`status` 可能为 `completed`、`failed`、`paused`、`waiting` 或 `cancelled`；调用方应同时检查错误和输出，不能把暂停当成完成。

状态结果包含 `turns_used` 和 `max_turns`，用于判断是否需要延长预算。每次模型响应都计一轮，包括返回工具调用的响应和最终答复；为子任务及追加任务分配预算时，需要为执行、核验和最终答复留出轮次。

等待结果通过正常工具结果写入父历史。如果主模型先返回最终答案，运行层会等待活动子任务，并把未读取的结果作为 `runtimeNotice` 交回主模型。暂停后恢复产生的新结果也会再次交付。主模型汇总仍受父任务轮次上限约束，预算不足时父任务暂停，可提高 `maxTurns` 后恢复。

子代理因轮次预算耗尽而暂停时，运行层会阻止父任务直接完成，并提醒主模型追加足够预算。如果修改已提交，可让子代理仅完成核验或最终报告，避免重复写入。主代理不处理该暂停状态时，最终会耗尽自己的预算并暂停，而不是报告整个任务完成。

业务工具可能被多个代理同时调用。宿主应协调共享资源写入、提供可重入实现，并继续通过 `completionCheck` 核验业务完成情况。

## 互斥目标与用户选择

运行指令要求主模型在目标互斥且用户未指定优先级时，调用 `request_user_input` 明确说明矛盾并给出选项。子代理向主代理报告矛盾。不能以首轮写入顺序作为优先级，也不能声称两个互斥目标都完成。目标是否互斥由模型识别；宿主需要对业务结果作严格保证时，仍应提供业务校验。

提问工具要求 2–8 个 ID 不重复的选项，运行层保存 `SessionSnapshot.pendingUserInput`，进入 `RunStatus.waitingUser`，并发出 `AgentEventKind.userInputRequested`，事件文本为问题的 JSON。`await run.done` 此时表示本轮执行已停止，需要用户回答，任务尚未完成。提问后停止所有活动子任务并等待其结束；已经提交的资源修改保留。工具和模型必须响应取消信号。

宿主展示保存的问题，收到实际用户输入后恢复同一个 Run：

```dart
final snapshot = await run.done;
if (snapshot.status == RunStatus.waitingUser) {
  final question = snapshot.pendingUserInput!;
  // 展示 question.question、reason 和 options，并等待 UI 提交真实选择。
  final optionId = await showChoiceToUser(question);
  final continued = await manager.answerUserInput(
    snapshot.id,
    requestId: question.id,
    optionId: optionId,
  );
  final result = await continued.done;
  // result 也可能等待下一个问题，或因轮次不足而暂停。
}
```

`optionId` 必须是当前问题中的 ID；也可以改用 `text` 提交用户自由输入，两者只能提供一个。旧问题、重复答案、未知选项和空输入会被拒绝，快照保持不变。可传入 `maxTurns` 调整同一 Run 的总轮次上限。

自由输入可以替换所有选项，例如用户回答“取消10秒和20秒目标，改成15秒”。主代理按最新用户决定更新计划，放弃被替代的旧目标；最终汇总明确说明旧目标取消或被替代，并报告已核验的新目标。

问题与未完成工具批次同时持久化。断电恢复后直接 `resume()` 仍返回 `waitingUser`，不会调用模型或执行业务写入；普通 `prompt()` 不能绕过问题。回答时原子保存工具结果和用户决定，清除待回答问题，并将提问之后尚未执行的同批调用标记为 `superseded_by_user_input`，保证工具消息配对，同时让模型按新决定重新规划。任务 ID、父子关系、历史及已用预算保留。主代理随后只推进选定目标，重读资源版本，并可通过 `followup_task` 给停止的子代理分配更新后的任务。

## 持久化与恢复

`SessionSnapshot.agentState` 保存代理名称、邮箱、已接受输入、预算预留以及协作操作回执。旧快照缺少该字段时按空状态读取。

创建操作先保存子会话 ID 和预算，再创建并启动子会话；重试复用同一 ID，避免重复预留。消息和追加任务通过稳定的 `ToolContext.operationId` 去重。协作工具提供 `recover`，已经保存的结果直接回读。

用相同模型、工具和多代理配置调用 `manager.resume(parentId)`，运行层会接回持久化为 `running` 的子任务，再恢复父工具循环。`paused`、`waiting` 的子任务保留其状态，主模型可通过追加任务继续。父任务已有停止请求时，恢复会将停止请求传播到未完成子任务，核对工具结果后结束。

模型、业务工具和存储实现必须响应取消信号并遵守租约规则。磁盘存储由宿主负责确认旧进程已退出后恢复；本库不会接管仍在其他进程运行的会话。

活动父子任务的取消令牌同步关联。取消根任务时，受管子代理及孙代理的令牌在 `cancel()` 返回 Future 前已标记取消；运行层随后等待工具收尾、保存状态并释放租约。等待该 Future 完成后再核对实际资源。已经提交的修改不会被撤销，忽略取消信号的工具也不会被运行层强制终止。

需要拒绝旧后台提交时，管理器和本地资源工具可共享 `ResourceCommitGuard`。子孙代理继承根任务的激活代次，凭证还绑定完整父子运行链；取消或运行收尾撤销权限，根任务新激活使旧代次过期。提交检查与实际同步写入必须都通过 `guard.commit`，不能绕过该入口直接写资源。数据库或远端写入需要在其提交事务中实现等价保护，详见 [运行控制](runtime.md)。

已有 `AgentCoordinator.delegate()` 保持原来的宿主显式委派接口。该接口的结果汇总、跨进程依赖恢复和并发额度由其调用方管理。

跨进程作业可保留资源端签发的 `RemoteWritePermit`。`RemoteResourceTaskAuthority` 自动激活根代次与子孙 scope，取消和收尾等待远端撤销确认；旧凭证在新代次下提交由资源事务拒绝。`FencedResourceStore` 提供持久化 JSON 资源实现，服务重启仍保留代次与撤销记录，详见 [资源提交保护](resource-fencing.md)。
