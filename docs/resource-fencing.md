# 跨进程与 HTTP 资源提交保护

`ResourceTaskAuthority` 将 Run 生命周期接到资源服务。管理器等待 `activate` 确认后才启动模型或工具。默认远端 authority 使用有限写租约，取消同步关闭续租入口，随后等待资源端确认已撤销或租约失效，再释放本地会话写锁并结束 `run.done`。停止无法确认时仍等待，不以本地超时声明成功。取消令牌仍立即传播，但资源端停止边界需要被确认。

库提供 `FencedResourceStore`、`FencedResourceHttpHandler`、`FencedResourceClient` 和 `RemoteResourceTaskAuthority`。JSON 业务资源、根代次、父子权限链及操作回执保存在同一 `SessionStore` 检查点中。使用 `FileSessionStore` 时，资源端在同一资源的操作系统租约内读取当前状态、检查权限、更新业务值与回执并落盘。两个服务进程共享该目录时也由操作系统锁互斥；无法取得租约的请求不会提交或返回成功。遵守 FileSessionStore 的单存储 isolate 使用要求，资源目录与代理会话目录分开。

## 服务端

```dart
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

final resources = FencedResourceStore(
  FileSessionStore(resourceDirectory),
  initialData: {'a': 99},
  requireOnlineAuthorization: true,
  authorizeCommit: HttpResourceCommitAuthorizer().authorize,
);
final handler = FencedResourceHttpHandler(
  resources,
  controlKey: serviceControlKey,
);
final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
server.listen(handler.handle);
```

`initialData` 仅用于资源首次创建，重启后读取持久化的代次、撤销记录、业务值和回执。HTTP 接口均为 POST，JSON 响应遵循 `ToolResult.toJson()`；已知拒绝返回 HTTP 409，未确认持久化的事务失败返回 HTTP 503。

| 接口 | 凭证与作用 |
| --- | --- |
| `/activate` | 控制密钥；根任务比较 `expectedGeneration` 后推进代次，子任务绑定活动父权限 |
| `/revoke` | 控制密钥；撤销指定 scope，子孙提交检查完整父链，旧撤销不关闭新 scope |
| `/inspect` | 控制密钥；读取业务值、业务修订、代次及脱敏审计 |
| `/commit` | 原始写凭证；事务内检查后合并 JSON patch，并保存回执 |
| `/receipt` | 写凭证；查询所属逻辑运行的操作结果，不重放写入 |
| `/renew` | 控制密钥；对当前截止时间条件续租，不复活过期权限 |
| `/lease_status` | 控制密钥；事务内查询并永久记录过期停止证明 |

控制请求使用 `Authorization: Bearer ...`，仅可信宿主持有控制密钥。执行进程只接收 `RemoteWritePermit.toJson()`，不能推进代次或撤销权限。凭证包含随机 capability，不应进入模型上下文、公共日志或报告；远端部署通过 TLS 传输并保护存储文件。验证服务仅监听本机回环地址。

## 代理端

```dart
final client = FencedResourceClient(
  baseUrl: resourceServiceUrl, // 必须以 / 结尾。
  resourceId: 'shared',
  controlKey: serviceControlKey,
);
final online = await OnlineResourceAuthorization.start();
final authority = RemoteResourceTaskAuthority(
  client,
  onlineAuthorization: online,
);
final save = AgentTool(
  name: 'save_value',
  description: 'Save value through the resource service',
  parameters: {
    'type': 'object',
    'properties': {'value': {'type': 'integer'}},
    'required': ['value'],
    'additionalProperties': false,
  },
  validate: (args) => args['value'] is int ? null : 'Supply integer value',
  execute: (call, context) => client.commit(
    authority.permitFor(context),
    operationId: context.operationId,
    patch: {'a': call.arguments['value']},
  ),
  recover: (_, context) => client.recover(
    authority.permitFor(context),
    context.operationId,
  ),
);
final manager = SessionManager(
  model: model,
  store: agentSessionStore,
  tools: [save],
  multiAgent: MultiAgentConfig(),
  resourceTaskAuthority: authority,
);
```

同一运行树的管理器共享 authority。子孙代理继承根代次，恢复同一逻辑 Run 也建立新激活权限，旧凭证不会复活。外部作业开始时捕获并传递原始 permit 和 `context.operationId`，不能在取消后为旧作业换发新任务凭证。提交进程可使用不含控制密钥的 `FencedResourceClient`，最终接受与否由资源服务决定。

整棵树结束后调用 `await online.close()`。跨主机部署时，通过 `address` / `port` 绑定宿主服务，并提供资源端可访问的 `advertisedUrl`（通常经过 HTTPS 反向代理）；本机默认回环地址不能用于跨主机连接。注册中的回调地址和独立随机密钥只经控制接口登记并持久化，子孙继承根登记，执行进程不能用提交请求修改它。密钥不能放入模型、日志或报告。

根代次过期返回 `stale_task_generation`，当前代次内撤销节点或祖先返回 `task_write_revoked`，篡改凭证返回 `invalid_write_permit`。拒绝为 `executed:false`，不改变业务值或业务修订。代次针对资源建立，确认新根代次会使此前代次过期；它不代替业务版本冲突处理及字段合并。

激活 ID 持久化去重，重复请求不推进代次，撤销的激活不能复活。根代次比较拒绝延迟的旧控制请求。回执绑定稳定操作 ID 和所属逻辑运行，同一操作的相同 JSON 数据只写一次；改变数据或盗用其他运行的操作 ID 被拒绝。恢复换发的新 scope 可读取同一逻辑运行的旧回执。写响应丢失时查询 `recover`；没有回执只能返回 `unknown`，不能据此假定请求未开始而直接重放。

本实现的权威业务资源是检查点内的 JSON `data`。接入已有数据库或其他资源服务时，需要在它的真实写事务中校验等价的代次、凭证及父链，并与业务修改和回执原子提交；不能先通过本服务检查，再无条件写另一个系统。可实现 `ResourceTaskAuthority` 对接该系统的激活与撤销协议。

## 撤销超时或确认丢失后的新任务

`FencedResourceStore` 默认写租约为10秒，可通过 `leaseDuration` 配置。`RemoteResourceTaskAuthority` 自动续租，健康运行不会因初始截止时间过去而失去写权限。取消时 `RenewableResourceTaskLease.stopRenewal()` 同步关闭续租；一次在途续租也不能在截止时间过期或永久停止后复活权限。续租有稳定 ID 和原截止时间条件，重复或晚到请求不能无限延长同一权限。执行进程没有控制密钥，无法自行续租。

撤销响应丢失后，客户端查询实际状态；已经持久化撤销则确认后完成取消。撤销尚未执行时，等待资源端租约到期。写事务检查当前节点及所有祖先的截止时间，到期返回 `task_write_lease_expired`，不改变业务值或修订。状态查询也永久封存过期权限，时钟回退、服务重启或晚到续租不会复活它。`authority.stopProofs` 提供不含 capability 的停止证明及原撤销错误类型。

停止证明返回之前，`cancel()` 和 `done` 保持等待，同会话的新 `prompt` 被写锁拒绝。资源端持续不可达时，不提前释放锁或启动新任务。停止确认后，即使新代次尚未创建或激活响应被扣住，旧凭证也不能写入。新任务仍须确认新代次后调用模型；晚到旧撤销只关闭原 scope。

## 取消等待期间的在线提交检查

上面的接入示例启用在线授权。`AgentRun.cancel()` 在第一次异步等待前调用 `ResourceTaskAdmissionLease.stopAdmission()`，同步关闭本节点和所有后代的提交准入；不等待远端撤销 RPC。资源端在真实资源写锁内校验凭证与父链，再通过已登记的回调查询主代理，每次请求使用新的随机 nonce，不缓存批准结果，不跟随重定向。主代理沿完整祖先链判定，取消后返回拒绝，即使旧租约仍有效、远端撤销超时且资源仍在代次1，旧子代理和孙代理的后续提交也返回 `task_commit_admission_closed`、`executed:false`。查询超时、断连、未知 scope、响应格式或 nonce 不符均拒绝提交；无法查询的错误为 `online_authorization_unavailable`。

在线查询后，资源端再次校验租约，避免查询期间到期仍落盘。查询、校验、业务修改和回执持久化始终持有同一资源锁，撤销和停止确认也取得该锁。因此取消前已经被主代理批准的在途事务可能在取消等待期间完成，但成功取消会等待它落盘及远端停止证明；不能把批准检查移到事务外后无条件写入。取消不回滚已经提交的修改，也不宣称网络间瞬时中断已批准的事务。

授权通过但尚未落盘的事务暂停测试见 [测试指南](testing.md#在线授权已通过但尚未落盘时取消)：即使暂停超过租约期限，取消仍需等待资源锁内的事务完成和停止证明；新任务在此之前不能开始。新任务启动后，旧凭证重试由新代次拒绝。

资源服务进程在授权后、调用底层保存前崩溃时，内存中的批准和未提交业务修改不会作为成功回执恢复。取消在服务不可达期间仍等待；同目录重启后须取得持久化权限的实际停止确认，再释放会话写锁。连接失败和缺失回执仍是未知结果，不自动重放；原凭证的人工重试仍校验停止记录及代次。对应 [真实进程崩溃测试](testing.md#已授权但未落盘时资源服务崩溃重启) 覆盖两种取消顺序与两级后代。

业务写入及回执已经落盘、成功响应尚未发送时崩溃，重启后仍能通过原凭证和操作 ID 查询 `completed` 回执，恢复原来的成功结果。取消在服务不可达期间仍须等待停止确认；已停止的旧凭证再次提交会被权限校验拒绝，新代次建立后则被代次校验拒绝。读取历史成功回执不增加业务修订，也不会把新任务资源还原成旧值。对应 [成功响应丢失的崩溃测试](testing.md#已落盘但成功响应未返回时资源服务崩溃重启) 核对真实落盘、回执恢复与两次旧提交，业务审计只保留原写入和新任务写入各一次。

`requireOnlineAuthorization: true` 同时拒绝没有回调登记的历史凭证和新根激活，避免通过旧协议绕过准入。为了兼容既有纯租约部署，该选项默认关闭，authority 的 `onlineAuthorization` 默认未配置：**只有两端按示例启用在线检查，才具备取消等待期间的保护**。纯租约配置在实际撤销或过期之前仍允许写入。停止确认仍使用资源端证明，不以主代理门禁关闭或本地时钟代替。

`leaseDuration: null` 显式禁用有限租约，仅用于旧协议兼容和反例测试，不提供取消后空窗保证。有限租约策略启用时，历史无截止时间凭证也会被拒绝并封存。自定义非续租 authority 的异常行为仍由其实现负责。验证见 [租约窗口测试](testing.md#有限租约封闭新代次未确认的窗口)。

验证命令、实际进程隔离及故障注入方式见 [测试指南](testing.md)。
