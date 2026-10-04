/// Model-facing optional arguments explicitly allow null as an omission marker.
/// Some constrained decoders emit every property even in non-strict mode.
/// The host schema and validator retain their original omission semantics.
Map<String, Object?> modelToolSchema(Map<String, Object?> schema) {
  final result = <String, Object?>{...schema};
  final properties = schema['properties'];
  if (properties is Map) {
    final required = (schema['required'] as List? ?? const []).toSet();
    result['properties'] = {
      for (final entry in properties.entries)
        entry.key as String: _modelProperty(
          (entry.value as Map).cast<String, Object?>(),
          optional: !required.contains(entry.key),
        ),
    };
  }
  if (schema['items'] case final Map items) {
    result['items'] = modelToolSchema(items.cast<String, Object?>());
  }
  for (final key in ['anyOf', 'oneOf', 'allOf']) {
    if (schema[key] case final List branches) {
      result[key] = [
        for (final branch in branches)
          modelToolSchema((branch as Map).cast<String, Object?>()),
      ];
    }
  }
  return result;
}

Map<String, Object?> _modelProperty(
  Map<String, Object?> schema, {
  required bool optional,
}) {
  final converted = modelToolSchema(schema);
  if (!optional || _allowsNull(schema)) return converted;
  return {
    'description':
        '${schema['description'] ?? ''} Optional: omit or use null for the default.',
    'anyOf': [
      converted,
      {'type': 'null'},
    ],
  };
}

bool _allowsNull(Map<String, Object?> schema) {
  if (schema.containsKey('const')) return schema['const'] == null;
  if (schema['allOf'] case final List branches) {
    return branches.every(
      (branch) => _allowsNull((branch as Map).cast<String, Object?>()),
    );
  }
  if (schema['enum'] case final List values) return values.contains(null);
  if (schema['type'] == 'null') return true;
  if (schema['type'] case final List types) return types.contains('null');
  for (final key in ['anyOf', 'oneOf']) {
    if (schema[key] case final List branches) {
      return branches.any(
        (branch) => _allowsNull((branch as Map).cast<String, Object?>()),
      );
    }
  }
  // An unconstrained schema already permits null.
  return !schema.containsKey('type') && !schema.containsKey('allOf');
}

/// Remove only null omission markers introduced for optional non-null fields.
/// Required nulls, explicit nullable fields and unknown keys reach validation.
Map<String, Object?> normalizeToolArguments(
  Map<String, Object?> arguments,
  Map<String, Object?> schema,
) {
  final properties = schema['properties'] as Map? ?? const {};
  final required = (schema['required'] as List? ?? const []).toSet();
  final result = <String, Object?>{};
  for (final entry in arguments.entries) {
    final property = (properties[entry.key] as Map?)?.cast<String, Object?>();
    if (property == null) {
      result[entry.key] = entry.value;
      continue;
    }
    if (entry.value == null &&
        !required.contains(entry.key) &&
        !_allowsNull(property)) {
      continue;
    }
    result[entry.key] = _normalizeValue(entry.value, property);
  }
  return result;
}

Object? _normalizeValue(Object? value, Map<String, Object?> schema) {
  if (value is Map<String, Object?>) {
    return normalizeToolArguments(value, schema);
  }
  if (value is List && schema['items'] is Map) {
    final items = (schema['items'] as Map).cast<String, Object?>();
    return [for (final item in value) _normalizeValue(item, items)];
  }
  return value;
}
