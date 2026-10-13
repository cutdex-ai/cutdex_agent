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
dart run example/skill_discovery.dart
```

离线检查可直接运行。协议测试使用本机 HTTP 服务；存储测试创建临时目录与 Dart 子进程，并在结束后清理。

> ⚠️ SIGKILL 用例已在 macOS 验证。其他平台、网络文件系统和整机断电恢复应在目标环境单独验证。

## 回归分工

下列文件均位于 `test/src/`，按覆盖契约组织。

| 文件 | 主要覆盖 |
| --- | --- |
| `agent_test.dart`、`recovery_test.dart` | 基本执行、控制、工具错误与 pending 调用恢复 |
| `cancellation_test.dart` | 同步传播到整棵令牌树、单向传播、解绑、重复绑定及取消后绑定 |
| `resource_commit_guard_test.dart` | 根代次继承、旧凭证拒绝、父子链撤销、无取消令牌时的保护、恢复不复活旧凭证、收尾撤销及跨 guard 拒绝 |
| `resource_task_authority_test.dart` | 激活确认前禁止执行、撤销确认前禁止租约释放、撤销失败不返回成功且释放本地租约 |
| `fenced_resource_store_test.dart`、`fenced_resource_http_test.dart` | 持久化资源代次及父子权限、控制权限校验、激活去重、延迟控制请求拒绝、回执去重及响应丢失恢复 |
| `fenced_resource_process_test.dart` | 两个真实服务进程共享文件租约、代次和回执，重复操作只提交一次 |
| `live_remote_fenced_cancel_validation_test.dart` | 独立提交进程与独立 HTTP 服务、旧子孙延迟提交、服务重启后凭证仍过期 |
| `live_remote_revoke_fault_validation_test.dart` | 整树撤销 HTTP 超时或确认丢失、立即启动拒绝、取消异常处理、新代次确认后模型执行、旧提交及晚到撤销隔离 |
| `remote_revoke_boundary_test.dart` | 撤销超时且新代次未确认时旧权限仍可提交的反例，以及实际已撤销但响应丢失的区别 |
| `resource_lease_expiry_test.dart` | 到期及祖先失效、永久封存、时钟回退、续租去重、旧截止时间拒绝、存储重开及无期限凭证升级 |
| `remote_lease_lifecycle_test.dart` | 长运行超过初始截止时间仍能写入、缺少停止证明时继续持有写锁 |
| `remote_lease_window_test.dart` | 有限租约下撤销故障、替换代次未创建时旧子孙提交已被拒绝 |
| `review_regression_test.dart` | 检查点等待期间的暂停/取消/追加指令竞态、日志帧头损坏 |
| `context_boundaries_test.dart`、`extensions_test.dart` | 用户约束、消息配对、技能、记忆、事件与委派 |
| `skills/skill_markdown_test.dart`、`skills/directory_skill_provider_test.dart` | `SKILL.md` 解析、目录发现、文件更新、错误路径、取消、符号链接与宿主会话加载 |
| `skills/skill_discovery_test.dart` | 模型自主选择、目录预算与分页、按需加载、激活失败、磁盘恢复、摘要后正文恢复及会话隔离 |
| `coordinator_boundaries_test.dart` | 子任务权限、预算、并发、取消、父子身份恢复 |
| `multi_agent_test.dart` | 模型协作工具、并行运行、消息、追加任务、中断、结果汇总和故障恢复 |
| `user_input_test.dart` | 持久化等待、重启后禁止自动续跑、答案校验、旧批次写入丢弃和活动子代理停止 |
| `live_user_choice_validation_test.dart` | 互斥目标提问、选项及自由输入恢复；拒绝答复后仍尝试旧目标的情况 |
| `live_subagent_matrix_validation_test.dart` | 多级委派、结果交接、活动改向、中断重启、业务及连接故障恢复、并发与权限边界；结果正确但协调过程错误的反例 |
| `live_tree_cancel_validation_test.dart` | 整树取消、同时放行提交的竞态、未执行调用丢弃、重启后维持取消；不合作工具写入的反例 |
| `live_cancel_new_task_validation_test.dart` | 取消后立即开始新任务、提前启动拒绝、旧邮箱归档、旧代理权限隔离、复用名称及资源、旧取消信号不影响新任务 |
| `live_uncooperative_cancel_validation_test.dart` | 不合作工具延迟返回、取消后提交、后台写入覆盖新任务的反例、任务代次保护下拒绝旧子孙后台写入，以及拒绝被旧覆盖掩盖的错误新目标 |
| `harness_context_test.dart` | 工具发现、有界结果回读、Unicode、计划与续跑 |
| `auto_compaction_test.dart`、`compaction_restart_test.dart` | 自动摘要、失败边界、原始历史和重启后的请求上下文 |
| `completion_check_test.dart` | 完成核验、证据保存、失败续跑与取消 |
| `file_store_test.dart`、`incremental_store_test.dart` | 锁、修订、帧损坏、增量日志、旧格式迁移和进程强杀恢复 |
| `openai_chat_test.dart`、`protocol_adapters_test.dart` | 三种 HTTP/SSE 协议、工具参数、超时、取消、截断和上游错误 |
| `protocol_history_test.dart` | 协议历史版本、旧列表读取、损坏拒绝与不可变快照 |
| `token_usage_test.dart` | Responses 用量解析、持久化、诊断与模型输入隔离 |
| `diagnostics_test.dart`、`connection_diagnostics_test.dart` | 诊断范围、用量和连接错误 |
| `tool_schema_test.dart` | 模型参数 schema 与宿主参数归一化 |
| `live_validation_test.dart` | 取消后从磁盘核对原任务，再开始新任务的验证流程 |
| `live_conflict_validation_test.dart` | 冲突验证脚本的同步屏障、旧版本拒绝，以及主代理协调和子代理自行重试的区分 |
| `live_semantic_conflict_validation_test.dart` | 同字段互斥目标的观察脚本、最终值与目标满足情况，以及覆盖和错误成功声明的记录 |

存储测试会启动 `test/fixtures/crash_worker.dart` 和 `migration_worker.dart`，验证进程在工具执行和日志迁移中退出后的恢复行为。宿主应补充真实业务集成测试。

## 显式真实模型检查

### 技能发现与按需加载示例

在 `.env` 或进程环境中配置 `CUTDEX_LIVE_BASE_URL`、`CUTDEX_LIVE_API_KEY`、`CUTDEX_LIVE_MODEL`，执行：

```sh
dart run example/skill_discovery.dart --live --report .dart_tool/skill-discovery/live-report.json
```

支持 `--env-file` 指定配置文件，环境变量优先。验证根据实际请求和工具日志检查目录摘要、模型选择、正文按需加载、业务操作及回读；初始摘要足够时允许模型直接调用 `load_skill`。报告不保存 API 地址或密钥，验证失败返回非零退出码。默认离线模式及配置格式见 [README](../README.md#从目录加载技能)。

`test/example/skill_discovery_test.dart` 使用临时配置文件、本地 HTTP/SSE 服务和模拟模型，覆盖环境变量优先级、配置错误、凭据隐藏、正常流程及错误成功声明，不使用真实 `.env`。

### 剪辑与调色的技能选择

使用相同 `.env` 或环境变量配置运行：

```sh
dart run tool/live_skill_selection_validate.dart
```

两个任务使用独立会话和同一个技能目录，模型仅收到业务目标，自主选择并加载正文。报告要求剪辑只加载 `video-editing`、调色只加载 `color-grading`，并核对正文送达、业务调用顺序、回读结果和无关状态保持不变。加载错误技能或额外技能，即使业务结果正确也会失败。默认报告为 `.dart_tool/skill-discovery/selection-report.json`。

`test/example/skill_discovery_test.dart` 的离线回归覆盖两项任务的正常选择、选错技能、加载额外技能及执行无关操作。

### 子代理与 Skill 的真实媒体制作

安装 FFmpeg、ffprobe 并填写 `.env` 后运行：

```sh
dart run tool/live_subagent_skill_validate.dart
```

主模型自行创建两个子代理，子代理各自发现并按需加载 `example/media_skills` 中的对应技能，将剪辑与调色计划提交到磁盘项目，再回读自己的字段。主代理等待完成并实际渲染 MP4。宿主不预先创建子代理、不预选 Skill ID。

报告记录各代理请求、技能加载回执、共享项目提交与输出媒体指标。检查音频解码哈希、视频时长、首帧曝光及色温变化、两个子代理各自仅加载相关技能、字段修改归属，以及导出发生在子任务完成之后。合成测试源和实际导出文件保留在每次生成的独立目录，最新报告为 `.dart_tool/subagent-skills/latest-report.json`。

`test/tool/subagent_skill_validation_test.dart` 使用模拟模型与实际 FFmpeg 文件处理，覆盖正常协作、额外加载无关技能和错误声称完成。没有 FFmpeg 或 ffprobe 的环境跳过这组媒体回归，其他测试仍可离线运行。

### 多层子代理与 Skill 的真实媒体制作

沿用同一 `.env`、媒体工具与技能目录：

```sh
dart run tool/live_subagent_skill_validate.dart --multi-level
```

宿主设置 `maxDepth: 2`、`maxConcurrent: 3`。主模型创建一位协调子代理，协调子代理再创建剪辑、调色两位孙代理。任务只指定业务目标，不提供技能 ID；孙代理从目录摘要自主选择正文，修改并回读自己的字段。协调子代理收到两位孙代理的最终报告后回读项目并返回 JSON，主代理收到协调报告后实际渲染视频并汇总导出指标。

报告检查四个会话的真实父子关系、孙代理仅加载相关技能且初次请求没有正文、主代理与协调层全程不加载执行技能、字段只由对应孙代理提交，以及导出时所有子孙任务已完成。逐层交接必须在实际模型输入中出现：协调层回读前收到两位孙代理报告，根层导出前收到协调报告。两层汇总分别与合并项目和实际视频匹配；最终媒体仍核验时长、音频哈希、曝光和色温变化。

默认报告 `.dart_tool/multilevel-subagent-skills/latest-report.json` 包含 `sessionTree`、`coordinators`、孙代理 `children`、逐次请求中的 `deliveredOutputs`、业务提交与媒体证据。源视频、输出 MP4、项目和会话日志保存在独立 `run-*` 目录；可以使用 `--output-root`、`--report` 指定路径。

`test/tool/subagent_skill_validation_test.dart` 另外覆盖多层正常汇总，以及视频正确但协调层汇总错误、协调层加载技能并通过 `fork_turns: all` 传给孙代理、扁平委派冒充多层等反例。这些回归用模拟模型和实际 FFmpeg，真实模型验证由上述命令显式触发。

### 通用真实模型检查

`tool/live_validate.dart` 使用 Chat Completions 协议。网关地址和模型 ID 分别通过 `CUTDEX_LIVE_BASE_URL`、`CUTDEX_LIVE_MODEL` 配置，两者均为必填；在包根目录设置并运行：

```sh
export CUTDEX_LIVE_BASE_URL='https://your-gateway.example/v1'
export CUTDEX_LIVE_MODEL='your-model-id'
dart run tool/live_validate.dart /absolute/path/to/result.json
```

脚本启动后，从标准输入输入一行 API key；交互式终端会关闭回显。将报告路径设在仓库外，分享前检查其中的模型 ID 和模型输出。报告省略网关地址，错误信息中的配置地址和 API key 会被替换。

> ⚠️ 该命令调用真实模型并消耗额度，需要单独运行。取消后的服务端执行与计费行为由供应商决定。

脚本检查四项：流式对话、内存数据读写与核验、取消后从磁盘核对原任务并开始新任务、摘要后回忆用户约束。

真实业务操作、长任务质量和子任务并发应通过宿主集成测试验收。Responses 与 Anthropic 的远端连接应在目标部署中单独验证。

### 单句话多代理验证

使用相同的网关和模型配置运行独立检查：

```sh
dart run tool/live_multi_agent_validate.dart /absolute/path/to/multi-agent-result.json
```

API key 从 `CUTDEX_LIVE_API_KEY` 或标准输入读取。验证只发送一次用户任务，让模型创建两个子代理，分别读取固定的销售和延迟测试数据、计算并保存分析结果，再由主代理汇总。脚本不在宿主代码中调用 `delegate()` 或预先创建子代理。

报告记录实际模型调用、子会话历史、业务工具调用及主代理答案。通过条件包括两个子会话完成、不同子代理实际读取并保存各自结果、主代理 JSON 与工具保存结果一致。测试数据为进程内数据，不涉及真实剪辑项目；调用真实模型会消耗额度。

### 同一资源的并发冲突验证

```sh
dart run tool/live_conflict_validate.dart /absolute/path/to/conflict-result.json
```

使用相同的模型配置和密钥输入方式。脚本创建临时 `shared-plan.json`，让两个模型子代理分别追加 `color` 和 `audio`。首次读取使用同步屏障，保证两者都读到版本 1；写工具在事务队列中比较版本，再保存文档，因此第二个旧版本提交会返回 `resource_conflict`，不修改文件。

任务要求失败子代理报告冲突并结束本轮，由主代理安排重读、保留已有修改后重试。脚本不会替模型发送协调消息或执行重试。报告核对实际顺序：冲突 → 主代理成功发送消息或追加任务 → 同一子代理读取版本 2 → 提交版本 3；并检查两个修改、原始内容、主代理最终读取和汇总都正确。子代理自行重试即使内容正确，也不算主代理协调通过。

此检查验证配合版本保护工具时的模型协调行为。资源版本检查和提交队列属于测试业务工具，不是运行库自动提供的文件锁或通用合并功能。报告保留完整调用及文件状态证据，临时文件和会话在检查结束后删除。

### 同字段互斥目标观察

```sh
dart run tool/live_semantic_conflict_validate.dart /absolute/path/to/semantic-conflict-result.json
```

让两个子代理分别要求同一个 `target_duration_seconds` 字段最终严格等于 10 和 20。首次读取同步到版本 1，写工具仅检查数值和版本，不定义目标优先级，不自动选择结果或阻止合法的新版本覆盖。首轮尝试结束后，由主模型自行处理并解释矛盾目标。

报告保留全部提交、覆盖、主代理后续动作和自然语言答复，并按最终文件计算分别满足了哪些目标。`passed` 仅表示真实实验执行检查通过，不能解释为语义裁决正确；答复中的冲突识别和请求选择信号仅供辅助阅读。需要结合资源状态检查模型是否请求澄清、无依据地选择一方，或错误宣称两个互斥目标同时完成。脚本不会提供后续人类选择，也不修改真实项目。模型调用提问工具时会停在 `waitingUser`；测试完整的选择与恢复流程应使用下面的脚本。

### 互斥目标的提问、等待与恢复

```sh
dart run tool/live_user_choice_validate.dart /absolute/path/to/user-choice-result.json
```

使用相同网关、模型配置及密钥输入方式。真实模型自行创建两个子代理，分别完成 10 秒和 20 秒的首轮尝试；主模型解释目标互斥，并调用 `request_user_input`。

脚本核对运行已进入 `waitingUser`，重新打开磁盘会话并调用 `resume()`，检查问题和原 Run 保留、模型调用及资源状态均不变化。随后测试宿主提交与首轮成功值相反的选项作为**模拟用户选择**，检验真实模型在同一 Run 内继续执行，只提交所选目标并核对最终值。选择由测试宿主提供，不是实时人工点击；完整问题、答案来源、模型历史和资源提交记录都会保留在报告中。可通过 `validateUserChoiceConflict(..., choose: ...)` 接入其他测试选择。

此脚本的 `passed` 包含等待和选择后业务结果的验证。业务版本检查依然由测试工具提供，临时项目在测试结束后删除。

### 自由输入替换互斥目标

```sh
dart run tool/live_free_text_validate.dart /absolute/path/to/free-text-result.json
```

沿用上述真实模型、冲突复现和磁盘恢复流程。主代理停在 `waitingUser` 后，测试宿主提交自由文本“取消原来的10秒和20秒目标，改成15秒。请仅执行15秒的新目标，核验后汇总。”，通过 `answerUserInput(text: ...)` 输入，不传选项 ID。初始任务和模型 system 不提前提供15秒目标。

报告核对自由文本作为原样答案交给模型、仍使用原 Run、等待期间没有工作、回答后实际提交15秒并由主代理复读核验。回答后任何10秒或20秒的写入尝试都会判为失败，包括因版本过期而拒绝的尝试；还检查最终汇总提及15秒及原目标取消。答案来源明确记为测试宿主模拟自由输入，模型调用、消息和资源状态完整保留。

### 子代理场景批量验证

```sh
dart run tool/live_subagent_matrix_validate.dart /absolute/path/to/subagent-matrix-result.json
```

使用相同网关、模型及密钥输入方式。各场景创建独立临时项目，只由模型发起协作调用；业务工具保存实际结果，主代理必须读取核验，最终 JSON 必须与文件一致。场景失败也会保存报告并继续下一项。

| 场景参数 | 主要核验 |
| --- | --- |
| `nested` | 主代理→leader→两个孙代理；不同孙代理写分项，leader 写合计 |
| `handoff` | producer→主代理→等待中的 consumer；主代理实际转发，消费者随后写入 |
| `activeFollowup` | 子代理在检查点工具内等待时追加指令；同一 Run 改向，旧目标从未尝试保存 |
| `interrupt` | 中断实际活动工具；同一子会话开启新 Run，只保存新目标 |
| `recovery` | 子代理报告数据源不可用；主代理给同一子代理新任务并恢复正确结果 |
| `limits` | 活动额度用尽时创建拒绝、无权限目标拒绝；中断后释放额度并成功创建 |
| `transportFault` | 子代理收到一次真实模型响应后注入连接错误；主代理观察 `failed` 后重新分配 |

检查点工具只等待实际的持久化邮箱输入或取消信号，不代替主代理发送消息。连接故障是测试适配器注入的故障，并非网关自然故障；响应后、检查点前的错误位置会写入报告。所有场景均记录调用历史、协作工具结果、父子身份、文件结果与工具执行顺序。

“主代理不得写结果”的限制由测试业务工具根据代理身份检查；这不是运行库自动限制所有业务写入。模型误尝试时工具返回错误，可由模型重新委派；失败尝试也保留在资源动作与历史中。

可只运行指定场景，省略其余项：

```sh
dart run tool/live_subagent_matrix_validate.dart /absolute/path/to/retest.json activeFollowup interrupt
```

### 主代理取消与整棵任务树停止

```sh
dart run tool/live_tree_cancel_validate.dart /absolute/path/to/tree-cancel-result.json
```

真实模型自行创建根代理→leader子代理→两个孙代理。两个孙代理分别进入尚未提交的真实写工具后，测试宿主仅取消根 Run，不直接调用子代理取消。分别测试正常取消及“取消根 Run 的同一轮放行提交”。写工具在最终提交边界只检查自身的取消令牌，不增加全局禁写开关。

报告核对取消前四个代理均活动、两个孙代理的写调用均为 `started`；取消后整树 `cancelled`、pending 调用核对完成、无新增模型请求、取消请求之后无资源提交、原资源保留。每轮观察3秒并抽样读取文件，再用重新打开的磁盘管理器 `resume()`，确认仍取消且没有写入。离线测试另有不合作工具的反例，即使最终状态都为 `cancelled`，发生写入仍判失败；因此工具取消与资源状态必须一起检查。

### 取消后立即启动新任务

```sh
dart run tool/live_cancel_new_task_validate.dart /absolute/path/to/cancel-new-task-result.json
```

旧任务由真实模型创建 leader 和两个孙代理。两个写工具均活动时，leader 向父邮箱留下未读取消息；根代理保持在受控等待工具中。测试宿主取消根 Run，同一轮放行旧写工具并尝试提前启动新任务，确认会话租约拒绝该启动且没有模型请求；等待取消结束后立即在同一会话、同一资源启动新任务。

分别测试复用原管理器和重新打开磁盘管理器。新任务先列出代理并验证旧 ID 不可控制，然后复用旧 leader 的实际 `task_name` 创建一个新子代理，写入 a=15、由主代理复读并汇总。测试宿主还重复调用旧 Run 的取消，验证新 Run 不受影响。

报告核对旧子孙代理均取消且之后快照不变、无旧代理提交或模型请求、新旧代理同名但 ID 与父 Run 不同、旧邮箱消息只出现在旧任务背景历史、新子代理只写入15、原数据保留、汇总与文件一致。完成后继续抽样观察3秒。工具只检查自己的取消令牌，没有额外全局禁写或按旧 Run ID 拦截提交的开关。

### 不合作工具的延迟返回与后台写入

```sh
dart run tool/live_uncooperative_cancel_validate.dart /absolute/path/to/uncooperative-cancel-result.json
```

真实模型创建根代理→leader→writer孙代理。测试宿主在旧工具实际启动、根代理保持等待后，仅取消根 Run，立即尝试启动同会话新任务；等待取消完成后，新代理实际写入共享标量 a=15，主代理读取文件并按真实值汇总。测试不安装任务代次写入保护，也不在旧提交前检查取消令牌。

| 模式 | 故障注入与预期观察 |
| --- | --- |
| `pendingResult` | 旧工具忽略取消，延迟返回旧结果；取消等待工具返回，新任务未收到旧结果 |
| `pendingWrite` | 旧工具忽略取消，在返回前写入10；写入发生在取消请求之后、取消完成之前，新任务随后写入15 |
| `detachedWrite` | 旧工具返回后遗留后台 Future；新任务写入15并进入主代理核验工具时，释放旧后台提交，实际覆盖为10 |

第三项是展示当前边界的反例，`passed` 仅表示实验复现正确、报告和模型汇总与实际文件一致，不能解释为未发生污染。报告另有 `newTaskPolluted`、`oldWritesAfterCancelRequest` 和 `oldWritesDuringNewTask`，并保留文件变化、取消令牌、Run身份及模型请求。后台释放由明确检查点控制，不依赖模型恰好在某秒完成；这属于工具故障注入，并非模型自然生成了不合作的业务实现。清理时等待测试启动的所有后台工作结束。

### 任务代次保护下拒绝旧后台写入

```sh
dart run tool/live_guarded_cancel_validate.dart /absolute/path/to/guarded-cancel-result.json
```

使用上述同一个不合作工具和真实文件，接入库提供的 `ResourceCommitGuard`。三项分别测试旧子代理后台提交、旧孙代理后台提交、旧孙代理取消后且工具返回前提交。每个工具在开始时获取凭证，延迟操作保留原凭证；不会在新任务开始后换发旧操作的凭证。所有资源提交通过 `guard.commit` 执行同步文件写入，测试工具没有自行检查取消或按旧 Run ID 禁写的分支。

新任务实际写入15、主代理进入读取工具时放行旧后台提交。报告要求旧提交确实尝试、根代次过期时返回 `stale_task_generation` 且 `executed: false`、拒绝时新任务仍运行、没有旧提交、资源修订只增加一次、最终仍为15且主代理汇总 `polluted: false`。取消完成之前的旧工具提交应返回 `task_write_revoked`。与无保护反例分开保留，避免把没有执行故障注入误判为修复成功。

### 跨进程与 HTTP 资源的延迟提交

```sh
dart run tool/live_remote_fenced_cancel_validate.dart /absolute/path/to/remote-fenced-cancel-result.json
```

使用真实模型分别创建旧子代理和旧孙代理，各跑普通模式及资源服务重启模式，共四项。资源由独立 Dart 进程监听 `127.0.0.1` HTTP 端口，使用库的 `FencedResourceHttpHandler` 和 `FencedResourceStore(FileSessionStore(...))` 提交。旧工具另启动独立提交进程，经 stdin 接收原始凭证，该进程没有控制密钥或取消令牌。

普通模式让旧 HTTP 请求先实际到达服务，在事务开始前等待放行。宿主取消根 Run 并等待整树撤销确认，新任务写入15；主代理读取时放行旧请求，由事务读取最新代次后拒绝。重启模式保持旧提交进程存活、保留原凭证，在资源服务结束并由新 PID 读取同一磁盘状态后，新任务写入15，再让旧进程发送请求。延迟门位于测试夹具，不属于生产 HTTP 接口，不在客户端过滤旧请求。

报告核对三类 PID 不同、旧操作 ID 未更换、服务端 HTTP 409 和 `stale_task_generation`、审计记录旧代次1及当前代次2、没有旧业务提交、业务修订只增加一次、实际值保持15且模型汇总 `polluted:false`；重启前后持久化状态相同。测试使用真实本机跨进程 TCP/HTTP，没有部署外部云服务；模型调用仍经过用户配置的网关。

### 远端撤销超时与确认响应丢失

```sh
dart run tool/live_remote_revoke_fault_validate.dart /absolute/path/to/remote-revoke-fault-result.json
```

沿用独立 HTTP 资源服务及独立提交进程，真实模型创建旧子代理或旧孙代理，分别注入两种故障，共四项。故障施加到旧代次全部节点的真实 `/revoke` 请求；新代次撤销保持正常。此组显式设置 `leaseDuration: null` 保留旧协议反例，客户端使用1秒请求超时。默认有限租约保护验证见下一节。

| 故障 | 实际资源端行为 |
| --- | --- |
| `timeoutBeforeCommit` | 旧撤销请求已到达，在持久化事务前等待；客户端超时，本地旧运行结束时旧权限仍活动 |
| `lostAcknowledgement` | 服务端先持久化撤销，再断开连接且不发送确认；客户端报告连接异常，服务端旧权限已失效 |

宿主取消根 Run 后同一轮尝试新 `prompt`，核对写锁拒绝且无模型调用；处理取消异常后立即再试，若旧本地树还未收尾则仍被拒绝。宿主观察旧 `done` 的异常，完成本地收尾后继续新任务，模型每次新任务调用前读取资源端代次，要求已确认代次2。新子代理先写15，主代理实际读取时才放行旧进程提交；超时旧撤销也在新任务活动期间放行，检查它只撤销旧 scope，新 root scope 仍有效。

报告核对取消及 `done` 都暴露异常、整棵旧树的故障请求真实到达、超时模式旧权限活动而丢响应模式已撤销、新模型只在代次2调用、旧提交 HTTP 409、没有旧业务写入、资源值15及模型汇总 `polluted:false`。宿主短暂等待旧状态取证完成后才允许新子代理写值，该检查点只用于稳定取证，不在客户端过滤旧提交。故障由夹具在真实 HTTP 边界注入，并非网关自然故障。

另有直接网络回归：撤销超时且尚未确认新代次时，旧孙代理凭证的提交确实成功；新代次确认后相同旧凭证被拒绝。该反例不调用模型，明确区分“取消异常”与“资源端已停止”，避免将四项新任务安全结果解释为取消超时后绝对没有旧写入。

### 有限租约封闭新代次未确认的窗口

```sh
dart run tool/live_remote_lease_window_validate.dart /absolute/path/to/remote-lease-window-result.json
```

真实模型创建旧子代理或旧孙代理，分别测试撤销事务前超时及持久化撤销后确认丢失，共四项。资源端使用2秒有限租约，运行期间由 authority 自动续租；取消同步停止续租。响应未知时查询资源端状态，等待已撤销或到期封存的停止证明。本地收尾在证明返回前保持会话写锁，立即启动被拒绝。

取消完成后，夹具扣住新根任务的 `/activate` 请求，让资源仍为旧代次1、没有任何新模型调用。此时放行旧提交进程的原始 HTTP 请求，要求返回 `task_write_lease_expired` 或 `task_write_revoked`，且 `currentGeneration` 仍为1、业务值99和修订1均保持。随后放行新激活，确认代次2后才调用模型，实际写入15并核验 `polluted:false`。因此拒绝旧提交的原因是旧权限已停止，并不依赖替换任务推进代次。

报告保留整树停止证明、原撤销异常类型、未确认新激活时的资源、独立提交进程结果、最终值及模型汇总。晚到旧撤销也会在新任务活动期间放行，验证不关闭新 scope。普通生产默认租约为10秒，测试缩短时长以稳定复现。额外回归确认长任务续租、无法确认停止时保留写锁、时钟回退和延迟续租不复活权限。旧反例测试显式禁用有限租约，与默认安全路径分开保留。

### 取消等待期间拒绝仍有效的旧凭证

```sh
dart run tool/live_remote_cancel_wait_validate.dart /absolute/path/to/remote-cancel-wait-result.json
```

真实模型分别创建子代理和孙代理，让旧工具启动独立 Dart 提交进程。资源端使用10秒有限租约，并在撤销实际执行前扣住旧 `/revoke` 请求。宿主调用根 `cancel()`，立即探测新任务写锁，再在取消仍未完成、资源端确认旧租约仍有效且代次仍为1时放行旧进程的原始提交。没有客户端过滤旧请求；业务资源服务在持有资源锁时向主代理在线查询。

要求提交返回 HTTP 409、`task_commit_admission_closed`、`executed:false`，资源保持99和业务修订1。随后取消等待资源端到期停止证明，新任务激活仍暂扣取证，最终确认代次2，真实子代理写15，主代理读取资源并汇总 `polluted:false`。报告记录提交前的资源端租约状态、取消等待证据、独立进程结果、整树停止证明和模型轨迹。

离线网络回归另覆盖主代理断连、查询超时、nonce 不符、无效 JSON、重定向拒绝、禁止重新注册已关闭 scope、历史凭证无登记拒绝、查询期间租约到期，以及已获批准的事务完成前撤销不能确认。开启保护需要两端配置，具体见 [资源提交保护](resource-fencing.md#取消等待期间的在线提交检查)。

### 在线授权已通过但尚未落盘时取消

```sh
dart run tool/live_remote_admitted_write_validate.dart /absolute/path/to/remote-admitted-write-result.json
```

真实模型分别创建旧子代理和旧孙代理，让其工具启动独立 Dart 提交进程。资源服务使用生产在线授权检查和 `FencedResourceStore`，只在测试存储适配器的实际 `save` 调用前暂停已经获准的代次1写入，持续持有资源锁。取证包括真实回调批准记录、待落盘事务以及另一个进程直接读取的磁盘日志；暂停期间磁盘仍为99、业务修订1，不是仅扣住 HTTP 响应。

主代理此时取消，立即尝试新任务，再保持暂停3秒（超过2秒测试租约及撤销 RPC 超时）后重复尝试。要求 `cancel()` 和 `done` 都未完成，两次新任务被会话写锁拒绝且无新模型调用，磁盘与代次保持不变。放行后旧请求真实落盘10、业务修订2，整树停止证明返回，取消才成功完成。随后启动新任务，确认代次2后真实子代理写15；主代理实际读取时还让独立进程用原始旧凭证重试，要求 HTTP 409、`stale_task_generation`、`executed:false`，资源保持15和业务修订3，主代理汇总 `polluted:false`。

报告保留授权及落盘前证据、取消等待状态、两次新任务拒绝、原始请求结果、停止证明、磁盘读数、旧重试及资源端事务审计。旧提交序列必须早于新代次激活，避免只验证最终值而漏掉期间污染。回归还故意把新任务写值改成12，要求验证失败，防止错误的新目标被当成取消测试成功。

### 已授权但未落盘时资源服务崩溃重启

```sh
dart run tool/live_remote_admitted_crash_validate.dart /absolute/path/to/remote-admitted-crash-result.json
```

真实模型分别创建旧子代理或旧孙代理，覆盖先取消再崩溃、先崩溃再取消两种顺序，共四项。沿用实际在线授权和落盘前暂停点，宿主使用 `SIGKILL` 终止自己启动的独立资源服务，跳过服务的 `finally` 和保存门禁释放。重启服务使用原端口、原资源目录、相同控制密钥及在线校验策略，并核对新进程 PID 不同。

取消后保持服务离线至少3秒，超过测试租约及控制 RPC 超时；`cancel()`、`done` 必须仍等待，立即和稍后的新任务探测均被写锁拒绝，没有新模型调用。宿主从另一进程直接读取磁盘日志，要求崩溃前、崩溃后、重启后仍为99、业务修订1、代次1，没有已批准但未实际保存的旧写入和回执。连接中断的原始请求按未知处理；查询缺失回执也返回 `unknown`，不自动重放。

重启后的资源端确认整树停止，取消才能成功。随后使用原始凭证和操作 ID，由独立提交进程在新代次建立前重试，要求 HTTP 409、已过期或已撤销、`executed:false`、当前代次仍为1。新任务确认代次2后真实子代理写15，主代理核验时再由旧凭证进程重试，要求 HTTP 409、`stale_task_generation`、`executed:false`。最终只有新任务产生业务修订2，磁盘和接口均为15，主代理汇总 `polluted:false`。

报告保留授权记录、实际保存暂停点、服务退出码及前后 PID、离线取消等待、磁盘恢复读数、停止证明、未知原请求结果、两次旧凭证重试、业务审计和真实模型轨迹。此测试故障点位于调用底层保存前；它验证服务进程死亡及未提交事务恢复，不代替磁盘写入中途断电测试。

### 已落盘但成功响应未返回时资源服务崩溃重启

```sh
dart run tool/live_remote_committed_crash_validate.dart /absolute/path/to/remote-committed-crash-result.json
```

真实模型分别创建旧子代理和旧孙代理，提交进程使用原始凭证及稳定操作 ID 写10。夹具等待实际 `FencedResourceStore.commit` 完成（已保存业务值与回执、释放资源锁），在发送任何 HTTP 成功响应前暂停。宿主从另一进程直接读取磁盘日志，要求业务值10、业务修订2和原操作成功回执均已持久化，并核对原客户端仍未取得响应，再 `SIGKILL` 服务进程。

此时取消主代理，保持资源服务离线，要求 `cancel()` 和 `done` 仍等待，新任务探测被写锁拒绝。原请求因断连只能得到未知传输结果。服务以原端口和目录重启，业务值和回执保持；取消取得整树停止确认后才完成。`recover` 查询原操作返回 `completed`，结果与崩溃前磁盘成功回执完全一致，且不重放写入。独立进程在新任务建立前重新提交原凭证和操作 ID，必须因已过期或已撤销而拒绝，业务修订保持2。

新任务确认代次2后由真实子代理写15。主代理核验时，独立旧凭证进程再次提交同一操作，要求 HTTP 409、`stale_task_generation`、`executed:false`。主代理仍能查询到旧操作的历史成功回执（值10、修订2），但查询不能把当前值改回10。资源审计只有一次旧写入和一次新写入，最终磁盘及接口均为15、业务修订3，模型汇总 `polluted:false`。报告保留落盘与响应暂停证据、原请求未知结果、重启前后回执、停止证明、两次旧提交和实际业务审计。

## 存储维护

`tool/migrate_sessions.dart` 用于磁盘会话验证及迁移。省略 `--apply` 只验证；格式及安全边界见 [存储说明](session-storage.md)。

## GitHub Actions

PR 指向 `main`、推送到 `main` 和推送 `v*` 标签时，自动运行格式检查、静态分析、测试和离线示例。测试覆盖 Linux 的 Dart 3.12.0 与稳定版，以及 macOS 稳定版。格式检查固定使用 3.12.0，保持输出一致。

在仓库规则中，将 `CI passed` 设置为 `main` 合并前的必过检查。限制 `v*` 标签的创建权限，并保护标签免于更新或删除。

### 发布 GitHub Release

先更新 `pubspec.yaml` 的版本和 `CHANGELOG.md`，通过 PR 合并到 `main`，再从对应提交创建和推送同名标签。例如发布 0.2.0：

```sh
git tag -a v0.2.0 -m 'Release cutdex_agent v0.2.0'
git push origin v0.2.0
```

标签触发完整检查。通过后，工作流核对版本号和提交是否属于 `main`，再创建带自动说明的 GitHub Release。包含预发布后缀的版本标为 prerelease。包保留 `publish_to: none`，发布目标为 GitHub Release。

### 手动验证真实模型

在仓库 Settings → Secrets and variables → Actions 中配置：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `CUTDEX_LIVE_API_KEY` | 模型服务密钥 |
| Secret | `CUTDEX_LIVE_BASE_URL` | API 根地址 |
| Variable | `CUTDEX_LIVE_MODEL` | 模型 ID |

在 Actions 中选择 `Live model validation`，从 `main` 手动运行。结果显示在任务日志中。该流程使用前文的四项真实模型检查，并消耗模型额度。
