# 运行控制与完成核验

会话保存对话历史和执行状态，Run 表示一次任务。复用会话 ID 可以继续对话：任务结束后用 `prompt` 开始新任务，中断后用 `resume` 继续原任务。初次接入见 [README](../README.md)。

## 运行控制

- `run.steer(text)`：持久化追加指令，在后续模型请求前应用。
- `run.pause()`：当前工具完成后暂停，保留后续待执行调用。
- `run.cancel()`：协作取消模型、工具及受管子任务。
- `manager.resume(id)`：先核对未完成的工具调用，再继续原任务。轮次耗尽时，可提高 `maxTurns` 总额后恢复。
- `manager.prompt(id, text)`：上一任务完成后，在同一会话创建新 Run。

使用 `run.events` 和 `run.phase` 观察进度，等待 `run.done` 获取最终会话状态。存储失败时，`run.done` 抛出异常，运行层停止后续工具操作。

> ⚠️ 取消会保留已提交的业务操作。需要撤销时，由宿主执行相应的补偿操作。

取消后的 `resume` 用于核对待恢复调用，核对结束后仍保持取消状态。等待 `resume.done` 后，通过 `manager.prompt` 在同一会话开始新任务。

## 工具失败与恢复

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
