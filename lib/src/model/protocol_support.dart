import 'dart:convert';
import 'dart:io';

import '../run/cancellation.dart';
import 'adapter.dart';
import 'messages.dart';
import 'sse_transport.dart';

/// Common transport configuration; wire formats remain protocol-specific.
abstract class SseProtocolAdapter implements ModelAdapter {
  SseProtocolAdapter({
    required Uri baseUrl,
    required String path,
    required this.model,
    required this.apiKey,
    this.requestTimeout = const Duration(minutes: 3),
    this.maxResponseBytes = 8 * 1024 * 1024,
    HttpClient Function()? clientFactory,
  }) : clientFactory = clientFactory ?? HttpClient.new,
       endpoint = baseUrl.replace(
         path: '${baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/$path',
       ) {
    if (!['http', 'https'].contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment) {
      throw ArgumentError(
        'Expected an HTTP base URL without credentials, query or fragment',
      );
    }
    if (model.trim().isEmpty ||
        apiKey.contains('\n') ||
        apiKey.contains('\r') ||
        requestTimeout <= Duration.zero ||
        maxResponseBytes <= 0) {
      throw ArgumentError('Invalid model transport configuration');
    }
  }
  final Uri endpoint;
  final String model;
  final String apiKey;
  final Duration requestTimeout;
  final int maxResponseBytes;
  final HttpClient Function() clientFactory;
  Map<String, String> get headers;
  Map<String, Object?> body(ModelRequest request);
  ModelSseDecoder createDecoder();

  @override
  Stream<ModelEvent> stream(
    ModelRequest request,
    CancellationToken cancellation,
  ) async* {
    final events = createDecoder();
    yield* streamModelSse(
      endpoint: endpoint,
      body: body(request),
      headers: headers,
      cancellation: cancellation,
      decode: events.add,
      finish: events.finish,
      requestTimeout: requestTimeout,
      maxResponseBytes: maxResponseBytes,
      clientFactory: clientFactory,
    );
  }
}

abstract class ModelSseDecoder {
  String add(String payload);
  ModelResponse finish();
}

Map<String, Object?> protocolObject(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const ModelProtocolException('Expected a protocol object');
  }
  return value;
}

String protocolString(Object? value) {
  if (value is! String) {
    throw const ModelProtocolException('Expected protocol text');
  }
  return value;
}

Map<String, Object?> protocolEvent(String payload) {
  try {
    final value = protocolObject(jsonDecode(payload));
    if (value['error'] != null || value['type'] == 'error') {
      throw const ModelProtocolException('Provider reported a streaming error');
    }
    return value;
  } on FormatException {
    throw const ModelProtocolException('Invalid streaming JSON');
  }
}

ToolCall protocolToolCall(Object? id, Object? name, Object? arguments) {
  if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
    throw const ModelProtocolException('Missing tool identity');
  }
  return ToolCall(id: id, name: name, arguments: protocolObject(arguments));
}
