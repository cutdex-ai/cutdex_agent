import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../run/cancellation.dart';
import 'adapter.dart';

export 'adapter.dart'
    show ModelHttpException, ModelProtocolException, ModelConnectionException;

/// Shared bounded SSE transport; protocol adapters own request and event formats.
Stream<ModelEvent> streamModelSse({
  required Uri endpoint,
  required Map<String, Object?> body,
  required Map<String, String> headers,
  required CancellationToken cancellation,
  required String Function(String) decode,
  required ModelResponse Function() finish,
  required Duration requestTimeout,
  required int maxResponseBytes,
  required HttpClient Function() clientFactory,
}) async* {
  cancellation.throwIfCancelled();
  final client = clientFactory();
  final aborted = Completer<Object>();
  final settled = Completer<void>();
  void abort(Object reason) {
    if (!aborted.isCompleted) aborted.complete(reason);
    client.close(force: true);
  }

  Future<T> wait<T>(Future<T> work) =>
      Future.any([work, aborted.future.then<T>((error) => throw error)]);
  final timer = Timer(
    requestTimeout,
    () => abort(TimeoutException('Model request timed out', requestTimeout)),
  );
  final watcher = () async {
    final cancelled = await Future.any([
      cancellation.whenCancelled.then((_) => true),
      settled.future.then((_) => false),
    ]);
    if (cancelled) abort(const AgentCancelled());
  }();
  var stage = ModelConnectionStage.connecting;
  StreamIterator<String>? lines;
  try {
    final outgoing = await wait(client.postUrl(endpoint));
    cancellation.throwIfCancelled();
    outgoing.followRedirects = false;
    outgoing.headers.contentType = ContentType.json;
    outgoing.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    headers.forEach(outgoing.headers.set);
    outgoing.add(utf8.encode(jsonEncode(body)));
    stage = ModelConnectionStage.sending;
    final response = await wait(outgoing.close());
    stage = ModelConnectionStage.receiving;
    if (response.statusCode != HttpStatus.ok) {
      throw ModelHttpException(response.statusCode);
    }
    if (response.headers.contentType?.mimeType != 'text/event-stream') {
      throw const ModelProtocolException('Expected text/event-stream');
    }
    var bytes = 0;
    final bounded = response.map((chunk) {
      bytes += chunk.length;
      if (bytes > maxResponseBytes) {
        throw const ModelProtocolException('Response limit exceeded');
      }
      return chunk;
    });
    lines = StreamIterator(
      bounded.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final data = <String>[];
    var eventType = '';
    while (await wait(lines.moveNext())) {
      cancellation.throwIfCancelled();
      final line = lines.current;
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          if (eventType == 'error') {
            throw const ModelProtocolException(
              'Gateway reported a streaming error',
            );
          }
          final payload = data.join('\n');
          data.clear();
          if (payload == '[DONE]') break;
          final delta = decode(payload);
          if (delta.isNotEmpty) yield TextDelta(delta);
        }
        eventType = '';
      } else if (line.startsWith('data:')) {
        final value = line.substring(5);
        data.add(value.startsWith(' ') ? value.substring(1) : value);
      } else if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      }
    }
    cancellation.throwIfCancelled();
    if (data.isNotEmpty) {
      throw const ModelProtocolException('Stream ended inside an SSE event');
    }
    // Each protocol requires its own terminal event and complete tool arguments.
    // A clean TCP close alone must never authorize a partial tool call.
    yield finish();
  } catch (error) {
    if (cancellation.isCancelled) throw const AgentCancelled();
    final reason = aborted.isCompleted ? await aborted.future : error;
    if (reason is SocketException ||
        reason is HttpException ||
        reason is HandshakeException ||
        reason is TimeoutException) {
      throw ModelConnectionException(
        kind: switch (reason) {
          HandshakeException() => ModelConnectionKind.tls,
          SocketException() => ModelConnectionKind.socket,
          HttpException() => ModelConnectionKind.http,
          TimeoutException() => ModelConnectionKind.timeout,
          _ => ModelConnectionKind.unknown,
        },
        stage: stage,
        osErrorCode: reason is SocketException
            ? reason.osError?.errorCode
            : null,
      );
    }
    rethrow;
  } finally {
    timer.cancel();
    client.close(force: true);
    await lines?.cancel();
    settled.complete();
    await watcher;
  }
}
