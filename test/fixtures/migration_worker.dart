import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/io.dart';
import 'package:cutdex_agent/src/storage/journal_codec.dart';

Future<void> main(List<String> args) async {
  final root = Directory(args[0]);
  final boundary = args[1];
  final store = FileSessionStore(root);
  final lease = await store.acquire('session');
  final name = base64Url.encode(utf8.encode('session')).replaceAll('=', '');
  try {
    migrateJournal(
      '${root.path}/$name.journal',
      'session',
      onBoundary: (stage) {
        if (stage != boundary) return;
        File('${root.path}/ready').writeAsStringSync(stage, flush: true);
        stdin.readByteSync(); // Parent kills us while the writer lease is held.
        throw StateError('Expected process termination');
      },
    );
  } finally {
    await store.release('session', lease);
  }
}
