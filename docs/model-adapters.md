# 模型适配器

从 `package:cutdex_agent/io.dart` 导入 HTTP 适配器。宿主读取自己的配置和凭据，再传入 API 根地址、模型 ID 和密钥：

```dart
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

final adapter = OpenAiChatAdapter(
  baseUrl: Uri.parse('https://api.example.com/v1'),
  model: modelId,
  apiKey: apiKey,
);
final manager = SessionManager(model: adapter, store: InMemorySessionStore());
```

## 选择协议

| 适配器 | 在 `baseUrl` 后追加的路径 | 认证方式 |
| --- | --- | --- |
| `OpenAiChatAdapter` | `/chat/completions` | Bearer |
| `OpenAiResponsesAdapter` | `/responses` | Bearer |
| `AnthropicMessagesAdapter` | `/messages` | `x-api-key` |

三个适配器都支持流式文本、应用工具调用、超时、取消和响应大小限制。每个请求独立使用 HTTP 客户端，取消作用于当前请求。工具参数收齐并通过协议校验后，才交给运行层执行。

将 `baseUrl` 设为最终 API 根地址，例如 `https://api.openai.com/v1`。地址应省略凭据、查询参数和 fragment。需要重试时，宿主应结合运行状态和工具恢复结果决定是否重试。

> ⚠️ 当前支持文本和应用 function tools；图片、供应商内置工具和其他专用参数需要扩展适配器。请求不自动重试或跟随重定向。取消后的服务端执行与计费行为由供应商决定。

## 各协议的处理方式

**Chat Completions** 使用 `max_completion_tokens`。收到 `[DONE]`，或收到明确的 `finish_reason` 后连接正常结束，均可完成响应。异常断流、缺少结束原因、输出截断和上游错误按失败处理。

**Responses** 使用 `instructions`、`max_output_tokens` 和 `store: false`，通过本地历史继续对话。适配器保留并回传加密 reasoning 项，以 `response.completed` 中的完整输出确认工具参数。用量字段见 [服务端用量](long-running-agent.md#读取服务端用量)。

**Anthropic Messages** 使用 `anthropic-version: 2023-06-01`。工具结果转为 user 消息中的 `tool_result`，同批结果合并发送，并保留 thinking 签名。

> ⚠️ Messages 当前可保留已有 thinking 历史；启用扩展思考需要增加配置支持。

## 历史与错误

`AgentMessage.providerData` 保存供应商协议所需的历史，随会话一起持久化。`ProtocolHistory` 使用版本 1 的 `{version, items}` 格式，也兼容旧列表和缺少该字段的记录。未知版本或损坏数据会报错。

HTTP 错误提供状态码，连接错误提供分类诊断；上游响应体和密钥从错误信息中省略。

## 验证与参考

本地 HTTP/SSE 测试验证协议和错误处理。真实模型检查及目标部署验证见 [测试指南](testing.md)。

协议参考：[OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)、[OpenAI conversation state](https://developers.openai.com/api/docs/guides/conversation-state)、[Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create)、[Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)。
