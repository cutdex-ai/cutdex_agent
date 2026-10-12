import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../session/snapshot.dart';
import '../storage/store.dart';
import 'tool.dart';

/// A portable, secret write credential issued by the resource submission end.
///
/// Transport [toJson] only to trusted workers and the resource service. Never
/// include the capability in model context, public logs or audit reports.
class RemoteWritePermit {
  RemoteWritePermit._(this._json);
  final Map<String, Object?> _json;
  factory RemoteWritePermit.fromJson(Map<String, Object?> json) {
    for (final key in [
      'resourceId',
      'scopeId',
      'capability',
      'sessionId',
      'runId',
      'rootRunId',
    ]) {
      if (json[key] is! String || (json[key] as String).isEmpty) {
        throw FormatException('Invalid remote permit field: $key');
      }
    }
    if (json['generation'] is! int || (json['generation'] as int) < 1) {
      throw const FormatException('Invalid remote permit generation');
    }
    if (json['leaseTtlMs'] != null &&
        (json['leaseTtlMs'] is! int ||
            (json['leaseTtlMs'] as int) <= 0 ||
            json['initialExpiryMs'] is! int)) {
      throw const FormatException('Invalid remote lease metadata');
    }
    return RemoteWritePermit._(Map.unmodifiable(json));
  }

  /// The protected resource identity.
  String get resourceId => _json['resourceId'] as String;

  /// The resource-side activation identity.
  String get scopeId => _json['scopeId'] as String;

  /// The agent execution identity.
  String get runId => _json['runId'] as String;

  /// The root execution identity.
  String get rootRunId => _json['rootRunId'] as String;

  /// The durable resource-side generation.
  int get generation => _json['generation'] as int;

  /// The server-configured lease duration, or null for legacy unbounded authority.
  int? get leaseTtlMs => _json['leaseTtlMs'] as int?;

  /// The initial server deadline used for conditional renewal.
  int? get initialExpiryMs => _json['initialExpiryMs'] as int?;

  /// Serializes the secret credential for authenticated transport.
  Map<String, Object?> toJson() => Map.of(_json);
}

/// Persists fencing authority and JSON resource data in one leased checkpoint.
///
/// Every activation, revocation and submission acquires the same resource lease.
/// Generation checks, ancestor checks, operation receipts and resource changes
/// share one compare-and-set save. Use FileSessionStore for process-safe journal
/// persistence, or a store with equivalent atomicity for a remote backend.
class FencedResourceStore {
  FencedResourceStore(
    this.store, {
    Map<String, Object?> initialData = const {},
    this.leaseDuration = const Duration(seconds: 10),
    this.authorizeCommit,
    this.requireOnlineAuthorization = false,
    DateTime Function()? now,
  }) : initialData = Map.unmodifiable(initialData),
       _now = now ?? DateTime.now {
    if (leaseDuration != null && leaseDuration!.inMilliseconds <= 0) {
      throw ArgumentError('Lease duration must be positive');
    }
  }
  final SessionStore store;

  /// The trusted owner check performed while holding the resource write lock.
  ///
  /// Returns a rejection code; `null` admits this transaction.
  final Future<String?> Function(Map<String, Object?>, RemoteWritePermit)?
  authorizeCommit;

  /// Whether activations and writes require an online owner registration.
  final bool requireOnlineAuthorization;
  final Map<String, Object?> initialData;

  /// The finite write duration; null explicitly opts into legacy unbounded leases.
  ///
  /// Deadlines use the resource service clock and are checked in its write
  /// transaction. Confirmed expiration is persisted as a permanent tombstone.
  final Duration? leaseDuration;
  final DateTime Function() _now;
  final Map<String, Future<void>> _queues = {};
  static String _secret() {
    final random = Random.secure();
    return base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
  }

  static Map<String, Object?> _map(Object? value) =>
      (value as Map).cast<String, Object?>();

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  static String _owner(RemoteWritePermit permit) {
    final json = permit.toJson();
    return jsonEncode([json['sessionId'], permit.runId, permit.rootRunId]);
  }

  Future<T> _transaction<T>(
    String resourceId,
    FutureOr<T> Function(Map<String, Object?>) action,
  ) {
    if (resourceId.isEmpty) throw ArgumentError('Resource ID is required');
    final previous = _queues[resourceId] ?? Future<void>.value();
    final next = previous.then((_) async {
      final lease = await store.acquire(resourceId);
      try {
        final snapshot = await store.read(resourceId);
        final state = snapshot == null
            ? <String, Object?>{
                'data': Map.of(initialData),
                'resourceRevision': 1,
                'generation': 0,
                'scopes': <String, Object?>{},
                'activations': <String, Object?>{},
                'receipts': <String, Object?>{},
                'audit': <Object?>[],
              }
            : _map(jsonDecode(jsonEncode(snapshot.agentState)));
        final result = await action(state);
        final updated = snapshot == null
            ? SessionSnapshot(id: resourceId, agentState: state)
            : snapshot.update({
                'revision': snapshot.revision + 1,
                'agentState': state,
              });
        await store.save(updated, expectedRevision: snapshot?.revision);
        return result;
      } finally {
        await store.release(resourceId, lease);
      }
    });
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _queues[resourceId] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_queues[resourceId], settled)) _queues.remove(resourceId);
      }),
    );
    return next;
  }

  void _audit(
    Map<String, Object?> state,
    String kind,
    Map<String, Object?> details,
  ) {
    final audit = state['audit'] as List;
    audit.add({
      'sequence': audit.length + 1,
      'kind': kind,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    });
  }

  ToolResult _reject(
    Map<String, Object?> state,
    String code,
    Map<String, Object?> details,
  ) {
    _audit(state, 'rejected', {'code': code, ...details});
    return ToolResult(
      'Resource request rejected: $code',
      isError: true,
      data: {'code': code, 'executed': false, ...details},
    );
  }

  Map<String, Object?> _view(Map<String, Object?> state) => {
    'data': state['data'],
    'resourceRevision': state['resourceRevision'],
    'generation': state['generation'],
    'audit': state['audit'],
  };
  Map<String, Object?>? _scope(
    Map<String, Object?> state,
    RemoteWritePermit permit,
  ) {
    final raw = _map(state['scopes'])[permit.scopeId];
    if (raw == null) return null;
    final scope = _map(raw);
    final stored = _map(scope['permit']);
    final incoming = permit.toJson();
    return stored.keys.every((k) => stored[k] == incoming[k]) ? scope : null;
  }

  String? _fence(Map<String, Object?> state, Map<String, Object?> scope) {
    if (_map(scope['permit'])['generation'] != state['generation']) {
      return 'stale_task_generation';
    }
    final scopes = _map(state['scopes']);
    final seen = <String>{};
    Map<String, Object?>? current = scope;
    while (current != null) {
      final id = _map(current['permit'])['scopeId'] as String;
      if (current['expired'] == true) return 'task_write_lease_expired';
      if (!seen.add(id) || current['active'] != true) {
        return 'task_write_revoked';
      }
      if (leaseDuration != null && current['expiresAtMs'] == null) {
        current['active'] = false;
        current['expired'] = true;
        return 'task_write_lease_expired';
      }
      if (current['expiresAtMs'] case final int expiry) {
        if (expiry <= _clock(state)) {
          // Expiration is a durable tombstone, so a clock rollback or a late
          // renewal cannot resurrect a credential after stop confirmation.
          current['active'] = false;
          current['expired'] = true;
          return 'task_write_lease_expired';
        }
      }
      final parent = current['parentScopeId'] as String?;
      if (parent == null) break;
      if (scopes[parent] == null) return 'task_write_revoked';
      current = _map(scopes[parent]);
    }
    return null;
  }

  int _clock(Map<String, Object?> state) {
    final value = max(
      state['clockFloorMs'] as int? ?? 0,
      _now().millisecondsSinceEpoch,
    );
    state['clockFloorMs'] = value;
    return value;
  }

  /// Activates a root generation or a child bound to a live parent credential.
  ///
  /// This is a trusted control operation. Root activation compares the observed
  /// generation so delayed control requests cannot supersede a newer task.
  /// [activationId] makes network retries durable and never reactivates a tombstone.
  Future<ToolResult> activate({
    required String resourceId,
    required String activationId,
    required String sessionId,
    required String runId,
    required int expectedGeneration,
    String? parentScopeId,
    String? parentRunId,
    bool active = true,
    Map<String, Object?>? ownerAuthorization,
  }) {
    if ([activationId, sessionId, runId].any((s) => s.isEmpty) ||
        expectedGeneration < 0) {
      throw ArgumentError('Invalid activation');
    }
    final fingerprint = jsonEncode([
      sessionId,
      runId,
      expectedGeneration,
      parentScopeId,
      parentRunId,
      active,
      ownerAuthorization == null ? null : _canonical(ownerAuthorization),
    ]);
    return _transaction(resourceId, (state) {
      final activations = _map(state['activations']);
      final scopes = _map(state['scopes']);
      if (activations[activationId] case final previous?) {
        final record = _map(previous);
        if (record['fingerprint'] != fingerprint) {
          return _reject(state, 'activation_id_conflict', {});
        }
        final scope = _map(scopes[record['scopeId']]);
        final code = _fence(state, scope);
        return code == null
            ? ToolResult('Already activated', data: {'permit': scope['permit']})
            : _reject(state, code, {});
      }
      Map<String, Object?>? parent;
      if (parentScopeId != null) {
        if (scopes[parentScopeId] == null) {
          return _reject(state, 'invalid_parent', {});
        }
        parent = _map(scopes[parentScopeId]);
        if (_map(parent['permit'])['runId'] != parentRunId ||
            _fence(state, parent) != null) {
          return _reject(state, 'task_write_revoked', {});
        }
      } else if (state['generation'] != expectedGeneration) {
        return _reject(state, 'stale_task_generation', {
          'currentGeneration': state['generation'],
        });
      }
      if (parent == null) {
        if (requireOnlineAuthorization && ownerAuthorization == null) {
          return _reject(state, 'online_authorization_required', {});
        }
        state['generation'] = (state['generation'] as int) + 1;
      }
      final id = _secret();
      final ttl = leaseDuration?.inMilliseconds;
      final expiry = ttl == null ? null : _clock(state) + ttl;
      final permit = RemoteWritePermit.fromJson({
        'resourceId': resourceId,
        'scopeId': id,
        'capability': _secret(),
        'sessionId': sessionId,
        'runId': runId,
        'rootRunId': parent == null
            ? runId
            : _map(parent['permit'])['rootRunId'],
        'generation': state['generation'],
        'leaseTtlMs': ?ttl,
        'initialExpiryMs': ?expiry,
      });
      scopes[id] = {
        'permit': permit.toJson(),
        'parentScopeId': parentScopeId,
        'active': active,
        'expiresAtMs': ?expiry,
        'ownerAuthorization': parent == null
            ? ownerAuthorization
            : parent['ownerAuthorization'],
      };
      activations[activationId] = {'scopeId': id, 'fingerprint': fingerprint};
      _audit(state, 'activated', {
        'scopeId': id,
        'sessionId': sessionId,
        'runId': runId,
        'generation': permit.generation,
        'parentScopeId': parentScopeId,
      });
      return ToolResult('Activated', data: {'permit': permit.toJson()});
    });
  }

  /// Durably revokes one activation without changing a newer task's authority.
  Future<ToolResult> revoke(RemoteWritePermit permit) =>
      _transaction(permit.resourceId, (state) {
        final scope = _scope(state, permit);
        if (scope == null) return _reject(state, 'invalid_write_permit', {});
        scope['active'] = false;
        _audit(state, 'revoked', {
          'scopeId': permit.scopeId,
          'runId': permit.runId,
          'generation': permit.generation,
        });
        return ToolResult('Revoked', data: {'scopeId': permit.scopeId});
      });

  /// Extends a live lease using a control-only, conditional, idempotent request.
  ///
  /// Expired scopes and expired ancestors cannot be renewed. A delayed renewal
  /// cannot extend a different deadline or revive a confirmed stop.
  Future<ToolResult> renew(
    RemoteWritePermit permit, {
    required String renewalId,
    required int expectedExpiryMs,
  }) => _transaction(permit.resourceId, (state) {
    final scope = _scope(state, permit);
    if (scope == null) return _reject(state, 'invalid_write_permit', {});
    final code = _fence(state, scope);
    if (code != null) {
      return _reject(state, code, {
        'scopeId': permit.scopeId,
        'runId': permit.runId,
      });
    }
    final ttl = permit.leaseTtlMs;
    if (ttl == null) return _reject(state, 'lease_not_renewable', {});
    if (scope['lastRenewalId'] != renewalId) {
      if (scope['expiresAtMs'] != expectedExpiryMs) {
        return _reject(state, 'lease_renewal_conflict', {});
      }
      scope['expiresAtMs'] = _clock(state) + ttl;
      scope['lastRenewalId'] = renewalId;
    }
    return ToolResult(
      'Lease renewed',
      data: {'expiresAtMs': scope['expiresAtMs'], 'leaseTtlMs': ttl},
    );
  });

  /// Confirms and durably records whether this scope's writes are stopped.
  ///
  /// A successful stopped result seals expiration before replying. Clients must
  /// not substitute local elapsed time for this resource-side acknowledgement.
  Future<ToolResult> leaseStatus(RemoteWritePermit permit) =>
      _transaction(permit.resourceId, (state) {
        final scope = _scope(state, permit);
        if (scope == null) return _reject(state, 'invalid_write_permit', {});
        final reason = _fence(state, scope);
        return ToolResult(
          'Resource lease status',
          data: {
            'stopped': reason != null,
            'reason': reason,
            'scopeId': permit.scopeId,
            'runId': permit.runId,
            'generation': state['generation'],
            'expiresAtMs': scope['expiresAtMs'],
            'serverNowMs': _clock(state),
          },
        );
      });

  /// Checks authority and atomically patches the durable resource and receipt.
  ///
  /// A stale or revoked credential never changes business data or its revision.
  /// Reusing [operationId] with different data is rejected. Retrying an accepted
  /// operation with identical data returns its receipt without a second write.
  Future<ToolResult> commit(
    RemoteWritePermit permit, {
    required String operationId,
    required Map<String, Object?> patch,
  }) {
    if (operationId.isEmpty || patch.isEmpty) {
      throw ArgumentError('Operation ID and patch are required');
    }
    final canonical = _map(_canonical(jsonDecode(jsonEncode(patch))));
    return _transaction(permit.resourceId, (state) async {
      final details = {
        'scopeId': permit.scopeId,
        'runId': permit.runId,
        'rootRunId': permit.rootRunId,
        'generation': permit.generation,
        'currentGeneration': state['generation'],
        'operationId': operationId,
      };
      final scope = _scope(state, permit);
      if (scope == null) return _reject(state, 'invalid_write_permit', details);
      final code = _fence(state, scope);
      if (code != null) return _reject(state, code, details);
      final owner = scope['ownerAuthorization'];
      if (owner != null || requireOnlineAuthorization) {
        if (owner == null || authorizeCommit == null) {
          return _reject(state, 'online_authorization_unavailable', details);
        }
        String? denial;
        try {
          denial = await authorizeCommit!(_map(owner), permit);
        } catch (_) {
          denial = 'online_authorization_unavailable';
        }
        if (denial != null) return _reject(state, denial, details);
        // The network check can outlive the lease. Recheck under the same
        // process-safe lock, before changing data and saving the receipt.
        final afterCheck = _fence(state, scope);
        if (afterCheck != null) return _reject(state, afterCheck, details);
      }
      final receipts = _map(state['receipts']);
      final key = operationId;
      if (receipts[key] case final stored?) {
        final receipt = _map(stored);
        if (receipt['owner'] != _owner(permit) ||
            receipt['patch'] != jsonEncode(canonical)) {
          return _reject(state, 'operation_id_conflict', details);
        }
        return ToolResult.fromJson(_map(receipt['result']));
      }
      state['data'] = {..._map(state['data']), ...canonical};
      state['resourceRevision'] = (state['resourceRevision'] as int) + 1;
      _audit(state, 'committed', {
        ...details,
        'patch': canonical,
        'resourceRevision': state['resourceRevision'],
      });
      final result = ToolResult(
        'Committed at resource service',
        data: {
          'data': state['data'],
          'resourceRevision': state['resourceRevision'],
          'generation': state['generation'],
          'operationId': operationId,
        },
      );
      receipts[key] = {
        'owner': _owner(permit),
        'patch': jsonEncode(canonical),
        'result': result.toJson(),
      };
      return result;
    });
  }

  /// Reads a known outcome even after write permission was revoked.
  ///
  /// A missing receipt is unknown, because an in-flight request may still arrive.
  Future<ToolResult> receipt(RemoteWritePermit permit, String operationId) =>
      _transaction(permit.resourceId, (state) {
        if (_scope(state, permit) == null) {
          return _reject(state, 'invalid_write_permit', {});
        }
        final stored = _map(state['receipts'])[operationId];
        if (stored != null && _map(stored)['owner'] != _owner(permit)) {
          return _reject(state, 'receipt_owner_mismatch', {});
        }
        return stored == null
            ? ToolResult(
                'Outcome unknown',
                isError: true,
                data: {'code': 'outcome_unknown'},
              )
            : ToolResult.fromJson(_map(_map(stored)['result']));
      });

  /// Returns resource state and sanitized audit data without secret credentials.
  Future<ToolResult> inspect(String resourceId) => _transaction(
    resourceId,
    (state) => ToolResult('Resource state', data: _view(state)),
  );
}
