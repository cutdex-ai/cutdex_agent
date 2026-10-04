import 'messages.dart';

/// Persisted keys are stable even if adapter class names change.
enum ModelProtocol {
  openAiResponses('openAiResponses'),
  anthropicMessages('anthropicMessages');

  const ModelProtocol(this.storageKey);
  final String storageKey;
}

/// Immutable protocol output needed to continue a conversation.
///
/// Version 1 stores `{version: 1, items: [...]}` under the protocol's key.
/// Older sessions stored a bare list; those remain readable. Missing or other
/// protocol data is ignored, but malformed data and future versions are rejected
/// instead of silently dropping reasoning or tool context.
class ProtocolHistory {
  ProtocolHistory({
    required this.protocol,
    required Iterable<Map<String, Object?>> items,
  }) : items = List.unmodifiable(
         items.map((item) => freezeJson(item)! as Map<String, Object?>),
       );

  static const currentVersion = 1;
  final ModelProtocol protocol;
  final List<Map<String, Object?>> items;

  Map<String, Object?> toProviderData() => {
    protocol.storageKey: {'version': currentVersion, 'items': items},
  };

  static ProtocolHistory? forMessage(
    ModelProtocol protocol,
    AgentMessage message,
  ) => message.role == MessageRole.assistant
      ? fromProviderData(protocol, message.providerData)
      : null;

  static ProtocolHistory? fromProviderData(
    ModelProtocol protocol,
    Map<String, Object?> data,
  ) {
    if (!data.containsKey(protocol.storageKey)) return null;
    final entry = data[protocol.storageKey];
    final Object? rawItems;
    if (entry is List) {
      rawItems = entry;
    } else if (entry is Map<String, Object?>) {
      if (entry['version'] != currentVersion) {
        throw const FormatException('Unsupported protocol history version');
      }
      rawItems = entry['items'];
    } else {
      throw const FormatException('Invalid protocol history entry');
    }
    if (rawItems is! List ||
        rawItems.any((item) => item is! Map<String, Object?>)) {
      throw const FormatException('Protocol history items must be objects');
    }
    return ProtocolHistory(
      protocol: protocol,
      items: rawItems.cast<Map<String, Object?>>(),
    );
  }
}
