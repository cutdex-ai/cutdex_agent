import 'package:cutdex_agent/cutdex_agent.dart';
import 'package:cutdex_agent/io.dart';
import 'package:test/test.dart';

void main() {
  for (final protocol in ModelProtocol.values) {
    test('${protocol.name} reads legacy and versioned histories', () {
      final items = <Map<String, Object?>>[
        {'type': 'reasoning', 'encrypted_content': 'opaque'},
      ];
      final legacy = ProtocolHistory.fromProviderData(protocol, {
        protocol.storageKey: items,
      })!;
      final message = AgentMessage.fromJson(
        AgentMessage(
          role: MessageRole.assistant,
          providerData: legacy.toProviderData(),
        ).toJson(),
      );
      final restored = ProtocolHistory.forMessage(protocol, message)!;
      expect(restored.items, items);
      expect((message.providerData[protocol.storageKey] as Map)['version'], 1);
    });
  }
  test('absent history and other protocol history remain absent', () {
    expect(
      ProtocolHistory.fromProviderData(ModelProtocol.openAiResponses, {}),
      isNull,
    );
    expect(
      ProtocolHistory.fromProviderData(ModelProtocol.openAiResponses, {
        ModelProtocol.anthropicMessages.storageKey: [],
      }),
      isNull,
    );
    final oldMessage = AgentMessage.fromJson({
      'role': 'assistant',
      'text': 'old',
      'calls': [],
      'callId': null,
      'isError': false,
    });
    expect(oldMessage.providerData, isEmpty);
    expect(
      ProtocolHistory.forMessage(ModelProtocol.openAiResponses, oldMessage),
      isNull,
    );
  });
  test('future versions and malformed histories are rejected', () {
    for (final entry in [
      {'version': 2, 'items': []},
      {'version': 1, 'items': 'invalid'},
      {
        'version': 1,
        'items': [42],
      },
      null,
      [42],
    ]) {
      expect(
        () => ProtocolHistory.fromProviderData(ModelProtocol.openAiResponses, {
          ModelProtocol.openAiResponses.storageKey: entry,
        }),
        throwsFormatException,
      );
    }
  });
  test('history snapshots cannot be changed by mutating the source', () {
    final source = <Map<String, Object?>>[
      {
        'type': 'reasoning',
        'summary': <Object?>['original'],
      },
    ];
    final history = ProtocolHistory(
      protocol: ModelProtocol.openAiResponses,
      items: source,
    );
    (source.single['summary'] as List).add('changed');
    source.clear();
    expect(history.items.single['summary'], ['original']);
    expect(history.items.clear, throwsUnsupportedError);
    expect(
      () => history.items.single['type'] = 'changed',
      throwsUnsupportedError,
    );
  });
  test('protocol data only supplies assistant history', () {
    final message = AgentMessage(
      role: MessageRole.user,
      text: 'hello',
      providerData: {ModelProtocol.openAiResponses.storageKey: []},
    );
    expect(
      ProtocolHistory.forMessage(ModelProtocol.openAiResponses, message),
      isNull,
    );
  });
}
