import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/io.dart';

/// Explicit, content-free maintenance command. Default is read-only verification.
Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final paths = args.where((arg) => arg != '--apply').toList();
  if (paths.length != 1 || !await Directory(paths.single).exists()) {
    stderr.writeln(
      'Usage: dart run tool/migrate_sessions.dart <conversation-root> [--apply]',
    );
    exitCode = 64;
    return;
  }
  var count = 0;
  var before = 0;
  var after = 0;
  await for (final entry in Directory(
    paths.single,
  ).list(recursive: true, followLinks: false)) {
    if (entry is! File || !entry.path.endsWith('.journal')) continue;
    final name = entry.uri.pathSegments.last;
    final encoded = name.substring(0, name.length - '.journal'.length);
    final id = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    final store = FileSessionStore(entry.parent);
    final size = await entry.length();
    final original = await store.read(id);
    if (apply) await store.migrate(id);
    await store.verify(id);
    final restored = await store.read(id);
    if (jsonEncode(original?.toJson()) != jsonEncode(restored?.toJson())) {
      throw StateError('Migration verification failed for session $id');
    }
    final checkpoint = File('${entry.path}.checkpoint');
    final current =
        await entry.length() +
        (await checkpoint.exists() ? await checkpoint.length() : 0);
    count++;
    before += size;
    after += current;
    stdout.writeln(
      jsonEncode({
        'sessionId': id,
        'revision': restored?.revision,
        'beforeJournalBytes': size,
        'afterJournalAndCheckpointBytes': current,
        'applied': apply,
      }),
    );
  }
  stdout.writeln(
    jsonEncode({
      'sessions': count,
      'beforeJournalBytes': before,
      'afterJournalAndCheckpointBytes': after,
      'applied': apply,
    }),
  );
}
