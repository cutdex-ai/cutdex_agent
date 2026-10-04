# 长任务与上下文

默认 `SessionManager` 使用 `HarnessContextBuilder` 选择每次请求的内容，并用 `ModelContextSummarizer` 摘要较早的历史。会话保存完整记录，模型只接收当前任务需要且预算允许的部分。

## 按需加载工具

模型通过 `tool_search` 搜索已授权工具的名称和说明。搜索到的工具会在下一次请求中带上完整参数定义。

- 默认保留最多 12 个近期业务工具。
- 运行库工具和 `directTools` 指定的工具始终可用。
- 已选技能的 `requiredTools` 自动加载，并检查是否属于宿主授权集合。

搜索采用关键词子串匹配。要支持中文查询，在工具名称或说明中加入对应中文词。搜索结果和近期工具使用记录从会话历史恢复。

## 分页读取大结果

工具结果超过默认 12000 UTF-8 字节时，模型先收到预览、`resultId` 和读取入口。完整结果保存在会话日志中，模型可通过 `read_tool_result` 继续读取：

| 用法 | 返回内容 |
| --- | --- |
| 省略 `resultId` | 当前会话已保存结果的索引 |
| 指定 `resultId` | 对应结果，按体积限制返回 |
| 同时指定 JSON Pointer，如 `/data/items` | 结果中的指定字段 |

数组按项分页，字符串按 Unicode 码点分页；按返回的 `nextOffset` 继续读取。超大的数组项会提供进一步读取的路径。`resultId` 使用稳定的 `operationId`，可区分不同任务中的调用。

> ⚠️ 一个 emoji 可能由多个码点组成，因此可能跨页。历史工具结果反映读取时的状态；确认当前状态应调用业务查询工具。

## 保存计划并继续任务

模型通过 `update_plan` 保存步骤和 checkpoint，可记录资源、版本、读取位置和待办事项。保存成功后，最新计划会加入后续请求。摘要后，原始用户目标和追加指令仍以 user 消息保留。

模型准备结束时，运行层根据当前任务的计划决定下一步：

- 有 `pending` 或 `in_progress` 步骤：追加内部通知并继续运行。
- 有明确 `blocked` 步骤：允许报告阻塞。
- 轮次耗尽：暂停并保留状态，供后续恢复。

业务验收通过 `completionCheck` 完成，见 [运行控制](runtime.md)。

## 校验工具参数

模型可以用 `null` 省略可选、非空参数。运行层根据宿主原始 schema 移除这类省略值，再保存调用。必填参数中的 `null`、允许为空的值和未知字段会保留，交给 `validate` 校验。

可选 ID 省略时传 `null`；需要 ID 时，先通过查询工具获取真实值。

## 设置预算与摘要

分别设置 `maxInputTokens` 和 `maxOutputTokens`，使两者之和符合模型窗口。输入估算包含 system、messages 和工具参数定义。需要精确计数时，通过 `countTokens` 注入模型对应的 tokenizer。

默认估算按每 3 个 ASCII 字符约 1 token、每个非 ASCII 字符约 2–3 tokens 计算，并加上 25% 余量。

启用摘要后，每次请求前先选择要发送的历史。消息占用达到可用容量的 80% 时，保留近期完整消息组，摘要较早的已完成内容。近期消息目标约为 25% 预算；系统指令和工具定义先占用预算。工具调用及其结果作为一组处理，未完成调用保持完整。

摘要器将长历史分块处理，并累积上次摘要。摘要节省空间且满足预算后才保存；失败、取消或空摘要时保留原检查点。容量仍不足时，运行明确报错。空闲会话也可通过 `SessionManager.compact` 手动摘要。

> ⚠️ 自动摘要会增加模型请求和延迟。当前预算使用本地估算，尚未根据服务端用量自动校准。

## 读取服务端用量

Responses 适配器解析 `response.completed.response.usage`，包括输入、输出、总量，以及可选的缓存输入和推理输出。缓存输入和推理输出已包含在总量中。缺失或无效的计数按未知处理。

用量通过 `AgentMessage.usage` 保存到会话；普通请求和摘要请求的诊断记录分别保存各自用量。这些字段用于统计，模型上下文使用消息内容。

将历次 `totalTokens` 相加可以统计累计用量。评估当前上下文大小时，应按本次请求重新计数。

> ⚠️ 目前只有 Responses 协议解析 usage。

## 设计参考

以下链接用于了解设计思路，具体行为以本包源码和 [测试](testing.md) 为准。链接指向上游可变分支。

- [Codex tool_search](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/tool_search.rs)：按需加载工具。
- [Codex history](https://github.com/openai/codex/blob/main/codex-rs/core/src/context_manager/history.rs)、[compact](https://github.com/openai/codex/blob/main/codex-rs/core/src/compact.rs)：历史管理与摘要。
- [Codex plan](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/plan.rs)：计划工具。
- [Pi read](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/tools/read.ts)：限制输出大小并支持继续读取。
- [Maka checkpoint coordinator](https://github.com/apache/maka/blob/main/packages/runtime/src/history-compact-checkpoint-coordinator.ts)：先保存检查点，再发布。
