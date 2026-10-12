# 运行控制与完成核验

会话保存对话历史和执行状态，Run 表示一次任务。复用会话 ID 可以继续对话：任务结束后用 `prompt` 开始新任务，中断后用 `resume` 继续原任务。初次接入见 [README](../README.md)。

## 运行控制

- `run.steer(text)`：持久化追加指令，在后续模型请求前应用。
- `run.pause()`：当前工具完成后暂停，保留后续待执行调用。
- `run.cancel()`：同步触发模型、工具及受管子孙任务的取消令牌，再等待整棵受管任务树结束并保存状态。
- `manager.resume(id)`：先核对未完成的工具调用，再继续原任务。轮次耗尽时，可提高 `maxTurns` 总额后恢复。
- `manager.prompt(id, text)`：上一任务完成后，在同一会话创建新 Run。
- `manager.answerUserInput(id, requestId: ..., optionId: ...)`：回答主代理的待处理问题，并继续同一个 Run；也可用 `text` 提交自由输入。

使用 `run.events` 和 `run.phase` 观察进度，等待 `run.done` 获取最终会话状态。存储失败时，`run.done` 抛出异常，运行层停止后续工具操作。

启用多代理后，主模型可通过 `request_user_input` 询问互斥目标的取舍。`run.done` 返回 `waitingUser` 时，宿主应展示 `snapshot.pendingUserInput` 并等待用户回答；直接 `resume()` 仍然等待，普通 `prompt()` 不能跳过问题。答案需匹配当前问题 ID，未知选项、旧问题和重复答案均被拒绝。详见 [多代理协作](multi-agent.md#互斥目标与用户选择)。

> ⚠️ 取消会保留已提交的业务操作。需要撤销时，由宿主执行相应的补偿操作。

受管父子令牌同步联动，避免取消根任务后、逐级异步通知之前子孙任务继续提交的窗口。模型委派与宿主 `AgentCoordinator.delegate()` 都使用该机制。任务结束时解绑令牌，子任务取消不会反向取消父任务。实际 I/O 仍是协作取消：业务工具必须响应 `ToolContext.cancellation`，在提交边界再次检查；不能仅凭会话最终为 `cancelled` 判断外部资源没有变化。

取消后的 `resume` 用于核对待恢复调用，核对结束后仍保持取消状态。等待 `resume.done` 后，通过 `manager.prompt` 在同一会话开始新任务。

取消后立即换任务时，先 `await run.cancel()`，再 `manager.prompt(id, newTask)`。取消尚未结束时，会话写入租约会拒绝并行启动。新 Run 重置取消标记、子任务列表、预算与操作回执；旧未读子消息归入新任务边界之前的历史。旧子代理 ID 不属于新父 Run，即使名称相同，也不能通过新任务的协作工具控制它。

忽略取消信号且尚未返回的工具仍被等待：它可以在取消请求后提交外部资源，但同一会话的新任务必须等该工具收尾后才能启动。工具始终不返回时，取消也无法结束。本库不会强制杀死任意业务代码。

工具如果先返回，再通过未等待的 Future、外部进程或远端作业继续写入，这些副作用不属于受管工具 Future；即使 `await run.cancel()` 已结束、旧代理快照全部为 `cancelled`，后台写入仍可能覆盖新任务的资源。会话租约保护会话存储，不自动保护任意业务文件。工具应等待它启动的工作结束，并在真实提交端检查取消令牌；无法取消的异步作业应由资源端验证任务代次或写入凭证，拒绝过期任务的提交。

本地资源工具可以使用 `ResourceCommitGuard`：将同一个实例传给 `SessionManager(resourceCommitGuard: guard)` 和业务写工具。管理器在根任务开始前建立新的代次，子代理及孙代理继承该代次；取消同步撤销写权限，完成、失败或暂停后的运行收尾也撤销权限。恢复同一个逻辑 Run 会建立新激活代次，旧凭证不会重新生效。重复取消旧 Run 不会撤销新 Run 的权限。

```dart
final guard = ResourceCommitGuard();
final saveTool = AgentTool(
  name: 'save_value',
  description: 'Save the current resource value',
  parameters: {
    'type': 'object',
    'properties': {'value': {'type': 'integer'}},
    'required': ['value'],
    'additionalProperties': false,
  },
  validate: (args) => args['value'] is int ? null : 'Supply integer value',
  execute: (call, context) async {
    final permit = guard.issue(context);
    // Keep this original permit if preparation starts delayed/background work.
    return guard.commit(permit, () {
      resourceFile.writeAsStringSync('${call.arguments['value']}', flush: true);
      return ToolResult('Saved');
    });
  },
);
final manager = SessionManager(
  model: model,
  store: store,
  tools: [saveTool],
  resourceCommitGuard: guard,
);
```

`commit` 在实际提交前同步校验根代次和完整父子链，不在校验与提交之间让出执行权。过期凭证返回 `stale_task_generation`，已撤销权限返回 `task_write_revoked`，均为 `isError: true`、`executed: false`，写回调不会被调用。此保护需业务资源提交入口接入，适用于同一 Dart isolate 的同步提交；不能先校验再异步写入，也不能在回调里启动未等待的写工作。数据库、跨进程或远端资源必须在真实提交事务中持久化并校验等价的代次凭证。多个管理器操作同一任务树时，应共享同一个 guard；缺失父权限的子运行不会获得写入凭证。

## 工具失败与恢复

跨进程或 HTTP 资源可接入 `RemoteResourceTaskAuthority`，通过 `SessionManager(resourceTaskAuthority: authority)` 在模型执行前确认服务端激活，在取消和收尾时等待持久化撤销确认。`FencedResourceStore` 在同一租约内原子保存根代次、父子权限链、回执和 JSON 业务值，服务重启后权限状态仍然保留。接口、恢复语义及实际存储边界见 [资源提交保护](resource-fencing.md)。

确定操作失败时，工具返回 `ToolResult(..., isError: true)`，让模型调整后续调用。抛出异常表示操作结果可能未知，运行会等待恢复。

为有外部副作用的工具实现 `recover`，使用 `ToolContext.operationId` 查询执行结果并去重。该 ID 在恢复和重试时保持一致。

| `recover` 返回值 | 运行行为 |
| --- | --- |
| `completed` | 保存已完成的结果 |
| `notStarted` | 使用原操作 ID 重试 |
| `running` / `unknown` | 等待后续恢复 |

> ⚠️ 工具抛出异常时，操作可能已经发生。恢复前应查询实际执行状态。

## 完成核验

存在未完成计划时，运行层会继续任务，仍受轮次限制。计划与上下文机制见 [长任务与上下文](long-running-agent.md)。

需要业务验收时，给 `SessionManager` 传入 `completionCheck`。检查器读取当前 `SessionSnapshot` 和实际业务状态：通过后将证据保存到 `completionEvidence`；发现问题则反馈模型继续修复；抛出异常则运行失败。新任务和恢复会清除旧证据并重新检查。

> ⚠️ 模型标记计划完成后，仍需通过业务核验确认实际结果。
