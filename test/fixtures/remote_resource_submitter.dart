import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cutdex_agent/cutdex_agent.dart';

Future<void> main() async {
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final client = HttpClient();
  try {
    if (!await input.moveNext()) {
      throw StateError('Worker configuration missing');
    }
    final config = jsonDecode(input.current) as Map;
    var url = config['url'] as String;
    stdout.writeln(jsonEncode({'ready': true, 'pid': pid}));
    await stdout.flush();
    if (config['waitForGo'] == true) {
      if (!await input.moveNext()) throw StateError('Worker gate missing');
      url = (jsonDecode(input.current) as Map)['url'] as String;
    }
    final request = await client.postUrl(Uri.parse(url).resolve('commit'));
    request.headers.contentType = ContentType.json;
    if (config['waitForGo'] != true) request.headers.set('x-test-delay', '1');
    // This process has no cancellation token or control credential. The server
    // must reject the original permit at the actual delayed submission boundary.
    request.write(
      jsonEncode({
        'permit': config['permit'],
        'operationId': config['operationId'],
        'patch': {'a': 10},
      }),
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    final result = ToolResult.fromJson(
      (jsonDecode(body) as Map).cast<String, Object?>(),
    );
    stdout.writeln(
      jsonEncode({
        'pid': pid,
        'status': response.statusCode,
        'operationId': config['operationId'],
        'result': result.toJson(),
      }),
    );
    await stdout.flush();
  } finally {
    client.close(force: true);
    await input.cancel();
  }
}
