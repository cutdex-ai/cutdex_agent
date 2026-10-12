/// A stable choice offered to the user by the primary agent.
class UserInputOption {
  const UserInputOption({required this.id, required this.label});
  final String id;
  final String label;
  Map<String, Object?> toJson() => {'id': id, 'label': label};
  factory UserInputOption.fromJson(Map<String, Object?> json) =>
      UserInputOption(
        id: json['id']! as String,
        label: json['label']! as String,
      );
}

/// A durable question that suspends execution until the host submits an answer.
class UserInputRequest {
  UserInputRequest({
    required this.id,
    required this.question,
    required Iterable<UserInputOption> options,
    this.reason,
  }) : options = List.unmodifiable(options);
  final String id;
  final String question;
  final String? reason;
  final List<UserInputOption> options;
  Map<String, Object?> toJson() => {
    'id': id,
    'question': question,
    'reason': reason,
    'options': options.map((o) => o.toJson()).toList(),
  };
  factory UserInputRequest.fromJson(Map<String, Object?> json) =>
      UserInputRequest(
        id: json['id']! as String,
        question: json['question']! as String,
        reason: json['reason'] as String?,
        options: (json['options']! as List).map(
          (o) => UserInputOption.fromJson((o as Map).cast<String, Object?>()),
        ),
      );
}

/// Internal control signal used by the input tool to suspend its pending call.
class UserInputPending implements Exception {
  const UserInputPending();
}
