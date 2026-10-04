# 会话存储

通过 IO 入口接入磁盘存储，将宿主选择的目录传入 `FileSessionStore`：

```dart
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';

final store = FileSessionStore(Directory('/absolute/path/to/agent-sessions'));
final manager = SessionManager(model: myModelAdapter, store: store);
```

## 日志与读取

每个会话使用三个文件：

| 文件 | 用途 |
| --- | --- |
| `.journal` | 保存历史和执行状态 |
| `.lock` | 保护写入操作 |
| `.journal.checkpoint` | 加速读取的快照，可从日志重建 |

v2 日志先保存完整状态，之后追加变化字段和列表中变化的部分。每 128 个版本替换一次快照，因此日常状态更新只需写入差量。日志随历史增长，快照保留最新一份。

日常读取先校验快照与日志是否匹配，再读取快照之后的变化。快照丢失、损坏或过期时，从完整日志重建状态。审计全部历史时，调用 `verify()`；查看各历史版本时，调用 `revisions()`。两者都会检查整个日志。

每条日志记录带长度和 CRC32 校验，保存完成前刷新文件缓冲区。尾部未写完的记录会在读取时忽略，并在下一次持锁写入时修复。单条记录上限为 64 MiB，会话 ID 长度为 1–128 个 UTF-8 字节。

## 验证与迁移

v1 日志仍可读取，首次保存会在写锁内自动迁移。也可调用 `await store.migrate(sessionId)`，或使用维护命令：

```sh
dart run tool/migrate_sessions.dart /absolute/path/to/conversations --apply
```

先省略 `--apply` 验证日志，再添加 `--apply` 执行迁移。迁移先生成暂存文件，核对全部历史版本，刷新缓冲区后原子替换原日志。替换前失败保留原日志；替换后可从新日志恢复。

迁移保留消息、供应商协议历史、工具操作 ID、待恢复调用和全部历史版本。

> ⚠️ 迁移后的 v2 日志应使用支持 v2 的写入器维护。

## 写入租约与平台边界

写入租约使用操作系统文件锁，进程结束后由系统释放。同一进程应由一个 isolate 持有所有租约；将扫描和迁移计算交给工作 isolate，由持锁 isolate 完成写入。

> ⚠️ POSIX 文件锁无法独立隔离同一进程内的多个 isolate。

保存与迁移的进程强杀恢复已在 macOS 验证。部署到其他平台或网络文件系统时，在目标环境执行恢复测试。

> ⚠️ 现有验证覆盖进程强杀；整机断电的持久化行为需要单独验证。
