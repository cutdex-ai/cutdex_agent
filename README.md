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
- **扩展**：技能目录发现与正文按需加载、按范围检索的记忆，以及宿主显式委派的子任务。

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
| `SkillProvider` | 技能目录摘要与按需加载的正文；磁盘目录可直接使用 `DirectorySkillProvider` |
| `MemoryProvider` | 按宿主指定范围检索、写入和删除记忆 |

在业务工具中实现授权、事务和重复操作保护。工具失败与恢复的处理方式见 [运行控制](docs/runtime.md)。

## 宿主配置

- 工具串行执行。提供参数 schema 帮助模型构造调用，并实现 `validate` 校验运行参数。
- 按模型窗口设置输入与输出预算；需要精确计数时，通过 `countTokens` 注入 tokenizer。
- 在模型与工具实现中响应取消信号，及时释放客户端资源。
- 配置技能提供方，让模型根据目录摘要按需加载正文；也可通过 `skillIds` 预选技能。按业务需求显式写入和删除记忆。
- 使用 `multiAgent` 启用模型自主协作；使用 `AgentCoordinator.delegate()` 显式委派时，子工具集合须属于父工具集合，并由宿主协调恢复和结果汇总。

> ⚠️ 默认 token 计数为估算，应按实际模型配置预算。

## 从目录加载技能

通过 IO 入口的 `DirectorySkillProvider` 指定技能目录，即可自动扫描 `SKILL.md`。例如：

```text
skills/
  video-editing/
    SKILL.md
    references/
      guide.md
  media-analysis/
    SKILL.md
```

每个 `SKILL.md` 包含 YAML 头部和 Markdown 正文：

```markdown
---
name: video-editing
description: 按用户目标制定视频剪辑方案并执行剪辑。
version: "1.0"
required-tools:
  - read_clip
  - edit_clip
---
# 视频剪辑

先检查素材，再执行剪辑，最后核对时间线和音频。
需要详细规范时，读取 references/guide.md。
```

`name` 和 `description` 是必填的非空字符串，`name` 用作技能 ID，不依赖文件夹名称。`version` 可省略，默认 `1`，也可放在 `metadata.version` 中；顶层值优先。`required-tools` 是可选的工具名称列表，其他 YAML 字段会被忽略。正文必须非空。

宿主只需配置目录，模型即可自主发现和选择技能：

```dart
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

final skills = DirectorySkillProvider('/path/to/skills');

final manager = SessionManager(
  model: model,
  store: store,
  tools: tools, // 注册技能所需的 read_clip、edit_clip 等业务工具。
  contextBuilder: HarnessContextBuilder(skills: skills),
);
final session = await manager.create();
final run = await manager.prompt(session.id, '剪辑这段视频');
await run.done;
```

配置 `skills` 后，`ContextBuilder` 和 `HarnessContextBuilder` 默认开启模型自主发现。首次请求仅提供技能 ID、版本和描述摘要，不注入正文。模型根据任务调用 `load_skill`（参数 `id`），加载的正文及所需工具定义会在下一次模型请求中生效。模型也可调用 `list_skills`，用 `query` 搜索 ID 与完整描述，用 `offset`、`limit` 分页查看摘要。

初始目录摘要条目受 `maxSkillCatalogTokens`（默认 2048）和剩余输入预算限制，发现指令和分页元数据另外计入总输入预算。摘要中的 `total`、`nextOffset` 表示总数及继续读取的位置；每条描述最多展示 512 个 Unicode 码点。`list_skills` 默认返回 20 条，单页最多 50 条，正文仍需通过 `load_skill` 获取。两项技能工具始终可用，其名称为运行库保留名称。

每次目录 `list` 或 `load` 都重新扫描 YAML 头部，文件新增、修改和删除会在下次发现或加载时生效。`list` 只读取头部；`load` 只读取被选技能的完整正文。默认递归扫描，包括根目录的 `SKILL.md`；传入 `recursive: false` 只扫描根目录。扫描只读取名称为 `SKILL.md` 的普通文件，跳过符号链接，结果按技能 ID 排序。相对目录路径在构造时转为绝对路径。

空目录返回空列表，未知 ID 返回 `null`。无效头部抛出带文件路径的 `FormatException`；重复 ID 抛出列明两个文件的 `StateError`；目录不存在等文件系统错误直接向上传递。正文为空、编码错误和无效工具依赖在加载该技能时检查，不影响其他正文的按需加载。模型调用技能工具时，未知技能、读取失败、工具依赖缺失或激活超预算会返回工具错误，让模型继续处理。

模型成功加载的技能正文完整保存在会话日志中。后续请求从日志恢复正文，不重复读取磁盘；暂停、重启及摘要压缩后继续生效。技能文件修改不会改变已加载版本，模型再次调用 `load_skill` 可重新加载。各会话的激活记录互相隔离；子会话可使用相同目录自行选择技能。正文只注入一次系统上下文，模型可见的加载结果保留简短回执，原始正文仍可从日志回读。

宿主仍可通过 `manager.create(skillIds: ['video-editing'])` 预选技能，或自行调用 `skills.list(CancellationToken())` 为界面提供目录。设置 `HarnessContextBuilder(skills: skills, enableSkillDiscovery: false)` 可关闭模型自主发现，仅加载宿主预选技能。

加载的指令包含技能源文件及所在目录的绝对路径，帮助模型定位正文中的相对引用。引用文件、脚本和其他资源不会自动读取或执行，需宿主提供相应工具。`required-tools` 仅声明依赖，不授予权限，`allowed-tools` 等其他字段也不会增加工具权限；全部已选技能仍需适配上下文预算。

只需要解析字符串时，可使用平台无关核心入口的 `const SkillMarkdownParser().parse(markdown)`，无需磁盘访问；`parseDescriptor(markdown)` 只解析目录元数据，也接受没有正文的完整 YAML 头部。

可运行的完整示例：[技能发现与按需加载](example/skill_discovery.dart)。在包目录执行：

```sh
dart run example/skill_discovery.dart
```

示例默认读取随项目提供的 `example/skills`，使用模拟模型，无需密钥、网络或真实媒体文件。宿主不预选 `skillIds`，模型先收到两个技能的目录摘要，通过 `list_skills` 按描述选择视频剪辑技能，再通过 `load_skill` 按需加载正文，调用素材读取与剪辑工具，最后回读验证 10 秒时长和原始音频。控制台展示各阶段、实际读取的正文，以及未选技能没有加载的验证结果。

可用 `dart run example/skill_discovery.dart /path/to/skills` 指定兼容目录；其中需有描述包含“剪辑”的技能，并声明示例的 `read_example_clip`、`trim_example_clip` 工具。离线模型用确定性规则模拟选择过程。

真实模型模式使用兼容 OpenAI Chat Completions 的服务。复制 `.env.example` 为 `.env` 并填写以下三项，也可直接设置同名环境变量；环境变量优先，`.env` 已被 Git 忽略：

```dotenv
CUTDEX_LIVE_BASE_URL=https://your-gateway.example/v1
CUTDEX_LIVE_API_KEY=your-api-key
CUTDEX_LIVE_MODEL=your-model-id
```

`CUTDEX_LIVE_BASE_URL` 是 API 根地址，适配器自动追加 `/chat/completions`。运行：

```sh
dart run example/skill_discovery.dart --live \
  --report .dart_tool/skill-discovery/live-report.json
```

可用 `--env-file /path/to/test.env` 指定配置文件，`--help` 查看所有选项。配置文件支持注释、`KEY=value`、`export KEY=value` 及成对引号，值按字面读取，不执行 Shell 或变量展开。未传 `--live` 时始终使用离线模型，不读取密钥或调用远端服务。

真实模型和离线模型使用同一套验证器。它记录实际请求、成功的工具调用及最终素材状态，检查首次只有目录摘要、模型选择相关技能并加载正文、业务调用前已收到正文及工具定义、先读取再剪辑、剪辑后回读验证，以及未选技能未加载。初始摘要已包含目标技能时，真实模型可以直接调用 `load_skill`；无需额外调用 `list_skills`。报告通过取决于实际证据，模型仅声称“完成”不会通过。

控制台和 JSON 报告隐藏密钥及 API 地址。每次 HTTP 请求最多等待 60 秒，整个验证最多 3 分钟、16 轮模型请求；验证失败返回非零退出码。真实模式只连接模型，素材仍是内存中的测试数据。

使用同一份 `.env`，可运行[剪辑与调色的真实技能选择测试](tool/live_skill_selection_validate.dart)：

```sh
dart run tool/live_skill_selection_validate.dart
```

测试分别创建两个独立会话，提供相同目录和全部业务工具，只向模型描述业务目标，不指定技能 ID：剪辑任务将素材从 12 秒缩短为 10 秒并保留音频；调色任务将曝光补偿设为 +0.5 EV、白平衡设为 5600 K，并保留原始时长和音频。调色技能提供 `read_example_color`、`grade_example_clip` 的依赖与回读步骤。

测试不仅核验业务结果，还要求剪辑只加载 `video-editing`、调色只加载 `color-grading`，每次业务调用前模型都已收到对应正文，并且没有加载无关技能或执行无关业务操作。期望技能 ID 仅在执行结束后用于验收，不传给模型。默认报告写入 `.dart_tool/skill-discovery/selection-report.json`，支持 `--env-file`、`--report` 和可选技能目录参数；该测试目录须包含上述两个技能。

进一步验证主代理、子代理和 Skill 的真实媒体制作流程，运行：

```sh
dart run tool/live_subagent_skill_validate.dart
```

该场景读取相同 `.env`，需要本机 `ffmpeg` 和 `ffprobe`。宿主生成一段 12 秒、带音频的真实 MP4 测试视频，并提供磁盘项目和 `example/media_skills` 中的技能目录；主模型自主调用 `spawn_agent` 创建两个子代理。子代理各自从摘要选择技能、加载正文、修改剪辑或调色计划并回读，主代理等待完成后通过 FFmpeg 导出合并结果。

共享项目按字段串行合并，剪辑不覆盖调色，调色不覆盖时长；JSON 修改与操作回执一起保存，发布通过 `ResourceCommitGuard` 校验。测试核对独立子会话、每个子代理的技能隔离与字段提交归属、正文在业务调用前送达、主代理在子任务完成后导出，以及主代理 JSON 答复与实际结果一致。主代理可以通过渲染工具读取最新项目并回读导出结果，或先单独查询项目。

媒体验收使用 ffprobe 实测 10 秒时长、解码后前 10 秒音频的 SHA-256 哈希一致，以及首帧亮度与红蓝比变化来验证实际曝光和色温处理。视频源是合成测试素材，文件读写、项目修改和渲染都实际执行。每次生成独立目录，保留源视频、输出 MP4、项目 JSON 和父子会话日志；最新报告位于 `.dart_tool/subagent-skills/latest-report.json`。支持 `--env-file`、`--skills-dir`、`--output-root`、`--report`、`--ffmpeg` 和 `--ffprobe`，报告隐藏密钥及 API 地址。

再验证主代理 → 协调子代理 → 剪辑与调色孙代理的完整流程，运行：

```sh
dart run tool/live_subagent_skill_validate.dart --multi-level
```

主模型只创建一位协调子代理，再由协调子代理自主调用 `spawn_agent` 创建两位孙代理。宿主只提供同一技能目录和媒体工具；孙代理从摘要选择并加载相关正文，各自修改与回读字段。协调子代理等待并审阅两位孙代理的报告、回读合并项目后返回 JSON，主代理收到该汇总后才导出并核对实际媒体结果。

多层模式设置 `maxDepth: 2`、`maxConcurrent: 3`，并发额度包含协调子代理和两位孙代理。验收同时检查实际会话树、每次请求中的技能正文隔离、字段写入归属、孙代理报告在协调层回读前送达、协调报告在主代理导出前送达，以及两层 JSON 汇总与磁盘项目及实际视频一致。主代理和协调子代理不加载执行技能、不修改业务字段。`fork_turns: all` 会复制父历史，包括其中按需加载的技能回执，因此独立工作优先使用 `none`。宿主显式配置的技能 ID 在两种模式下都会继承；这不是强制权限隔离，隔离是否成立由实际请求验证。

默认独立报告为 `.dart_tool/multilevel-subagent-skills/latest-report.json`，媒体和四个会话保存在同目录的 `run-*` 子目录。可用 `--output-root` 和 `--report` 覆盖保存位置。

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
