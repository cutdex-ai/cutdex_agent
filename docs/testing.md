# Agent 测试指南

在当前源码上执行检查，以本次输出判断是否通过。

## 离线检查

在包根目录运行：

```sh
dart pub get
dart test --reporter expanded
dart analyze
dart format --output=none --set-exit-if-changed lib test example tool
dart run example/main.dart
```

离线检查可直接运行。协议测试使用本机 HTTP 服务；存储测试创建临时目录与 Dart 子进程，并在结束后清理。

> ⚠️ SIGKILL 用例已在 macOS 验证。其他平台、网络文件系统和整机断电恢复应在目标环境单独验证。

## 回归分工

下列文件均位于 `test/src/`，按覆盖契约组织。

| 文件 | 主要覆盖 |
| --- | --- |
| `agent_test.dart`、`recovery_test.dart` | 基本执行、控制、工具错误与 pending 调用恢复 |
| `review_regression_test.dart` | 检查点等待期间的暂停/取消/追加指令竞态、日志帧头损坏 |
| `context_boundaries_test.dart`、`extensions_test.dart` | 用户约束、消息配对、技能、记忆、事件与委派 |
| `coordinator_boundaries_test.dart` | 子任务权限、预算、并发、取消、父子身份恢复 |
| `harness_context_test.dart` | 工具发现、有界结果回读、Unicode、计划与续跑 |
| `auto_compaction_test.dart`、`compaction_restart_test.dart` | 自动摘要、失败边界、原始历史和重启后的请求上下文 |
| `completion_check_test.dart` | 完成核验、证据保存、失败续跑与取消 |
| `file_store_test.dart`、`incremental_store_test.dart` | 锁、修订、帧损坏、增量日志、旧格式迁移和进程强杀恢复 |
| `openai_chat_test.dart`、`protocol_adapters_test.dart` | 三种 HTTP/SSE 协议、工具参数、超时、取消、截断和上游错误 |
| `protocol_history_test.dart` | 协议历史版本、旧列表读取、损坏拒绝与不可变快照 |
| `token_usage_test.dart` | Responses 用量解析、持久化、诊断与模型输入隔离 |
| `diagnostics_test.dart`、`connection_diagnostics_test.dart` | 诊断范围、用量和连接错误 |
| `tool_schema_test.dart` | 模型参数 schema 与宿主参数归一化 |

存储测试会启动 `test/fixtures/crash_worker.dart` 和 `migration_worker.dart`，验证进程在工具执行和日志迁移中退出后的恢复行为。宿主应补充真实业务集成测试。

## 显式真实模型检查

`tool/live_validate.dart` 使用 Chat Completions 协议。网关地址和模型 ID 分别通过 `CUTDEX_LIVE_BASE_URL`、`CUTDEX_LIVE_MODEL` 配置，两者均为必填；在包根目录设置并运行：

```sh
export CUTDEX_LIVE_BASE_URL='https://your-gateway.example/v1'
export CUTDEX_LIVE_MODEL='your-model-id'
dart run tool/live_validate.dart /absolute/path/to/result.json
```

脚本启动后，从标准输入输入一行 API key；交互式终端会关闭回显。将报告路径设在仓库外，分享前检查其中的模型 ID 和模型输出。报告省略网关地址，错误信息中的配置地址和 API key 会被替换。

> ⚠️ 该命令调用真实模型并消耗额度，需要单独运行。取消后的服务端执行与计费行为由供应商决定。

脚本检查四项：流式对话、内存数据读写与核验、取消后从磁盘恢复、摘要后回忆用户约束。

真实业务操作、长任务质量和子任务并发应通过宿主集成测试验收。Responses 与 Anthropic 的远端连接应在目标部署中单独验证。

## 存储维护

`tool/migrate_sessions.dart` 用于磁盘会话验证及迁移。省略 `--apply` 只验证；格式及安全边界见 [存储说明](session-storage.md)。
