import 'dart:async';
import 'dart:io';
import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

class BrokenClient implements HttpClient {
  BrokenClient(this.error);
  final Object error;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async => throw error;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  final errors = <Object, ModelConnectionKind>{
    const SocketException('secret host/key', osError: OSError('secret', 61)):
        ModelConnectionKind.socket,
    const HandshakeException('secret certificate/host'):
        ModelConnectionKind.tls,
    const HttpException('secret proxy response'): ModelConnectionKind.http,
    TimeoutException('secret url'): ModelConnectionKind.timeout,
  };
  for (final entry in errors.entries) {
    test(
      'classifies ${entry.value.name} without logging endpoint or secrets',
      () async {
        final model = OpenAiChatAdapter(
          baseUrl: Uri.parse('https://secret.invalid/private'),
          model: 'test',
          apiKey: 'secret-key',
          clientFactory: () => BrokenClient(entry.key),
        );
        final diagnostics = RunDiagnostics();
        final request = ModelRequest(
          system: 'private system',
          messages: [],
          tools: [],
          maxOutputTokens: 64,
        );
        await expectLater(
          diagnostics
              .modelEvents(model, request, CancellationToken(), summary: false)
              .toList(),
          throwsA(
            isA<ModelConnectionException>()
                .having((e) => e.kind, 'kind', entry.value)
                .having(
                  (e) => e.stage,
                  'stage',
                  ModelConnectionStage.connecting,
                ),
          ),
        );
        final report = diagnostics.toJson();
        expect(report.toString(), isNot(contains('secret')));
        expect(report.toString(), isNot(contains('private')));
        final span = (report['spans'] as List).single;
        expect(span['connectionKind'], entry.value.name);
        expect(span['connectionStage'], 'connecting');
        if (entry.value == ModelConnectionKind.socket) {
          expect(span['osErrorCode'], 61);
        }
      },
    );
  }
}
