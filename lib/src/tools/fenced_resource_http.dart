import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../session/snapshot.dart';
import 'fenced_resource_store.dart';
import 'resource_task_authority.dart';
import 'online_resource_authorization.dart';
import 'tool.dart';

/// Serves resource transactions with separate control and worker credentials.
///
/// Activation, revocation and inspection require [controlKey]. Workers receive
/// only a scoped write permit. Mount this handler behind TLS for remote access;
/// the included process tests bind only to loopback.
class FencedResourceHttpHandler {
  FencedResourceHttpHandler(
    this.resources, {
    required String controlKey,
    this.maxRequestBytes = 1024 * 1024,
  }) : _controlKey = controlKey {
    if (controlKey.isEmpty) throw ArgumentError('Control key is required');
  }
  final FencedResourceStore resources;
  final String _controlKey;
  final int maxRequestBytes;

  /// Handles one HTTP request and closes its response after transaction acknowledgement.
  Future<void> handle(HttpRequest request) async {
    try {
      final route = request.uri.path;
      if (request.method != 'POST' ||
          !const {
            '/activate',
            '/revoke',
            '/inspect',
            '/commit',
            '/receipt',
            '/renew',
            '/lease_status',
          }.contains(route)) {
        await _respond(
          request,
          404,
          ToolResult('Unknown resource endpoint', isError: true),
        );
        return;
      }
      if (!const {'/commit', '/receipt'}.contains(route) &&
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $_controlKey') {
        await _respond(
          request,
          401,
          ToolResult('Control authorization required', isError: true),
        );
        return;
      }
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > maxRequestBytes) {
          await _respond(
            request,
            413,
            ToolResult('Resource request too large', isError: true),
          );
          return;
        }
      }
      final body = (jsonDecode(utf8.decode(bytes)) as Map)
          .cast<String, Object?>();
      RemoteWritePermit permit() => RemoteWritePermit.fromJson(
        (body['permit'] as Map).cast<String, Object?>(),
      );
      final result = switch (route) {
        '/activate' => await resources.activate(
          resourceId: body['resourceId'] as String,
          activationId: body['activationId'] as String,
          sessionId: body['sessionId'] as String,
          runId: body['runId'] as String,
          expectedGeneration: body['expectedGeneration'] as int,
          parentScopeId: body['parentScopeId'] as String?,
          parentRunId: body['parentRunId'] as String?,
          active: body['active'] as bool? ?? true,
          ownerAuthorization: (body['ownerAuthorization'] as Map?)
              ?.cast<String, Object?>(),
        ),
        '/revoke' => await resources.revoke(permit()),
        '/inspect' => await resources.inspect(body['resourceId'] as String),
        '/commit' => await resources.commit(
          permit(),
          operationId: body['operationId'] as String,
          patch: (body['patch'] as Map).cast<String, Object?>(),
        ),
        '/receipt' => await resources.receipt(
          permit(),
          body['operationId'] as String,
        ),
        '/renew' => await resources.renew(
          permit(),
          renewalId: body['renewalId'] as String,
          expectedExpiryMs: body['expectedExpiryMs'] as int,
        ),
        '/lease_status' => await resources.leaseStatus(permit()),
        _ => throw StateError('Unreachable route'),
      };
      await _respond(request, result.isError ? 409 : 200, result);
    } on FormatException {
      await _respond(
        request,
        400,
        ToolResult('Invalid resource JSON', isError: true),
      );
    } on TypeError {
      await _respond(
        request,
        400,
        ToolResult('Invalid resource request fields', isError: true),
      );
    } on ArgumentError {
      await _respond(
        request,
        400,
        ToolResult('Invalid resource request', isError: true),
      );
    } catch (_) {
      // No success acknowledgement if the durable save or lease failed.
      await _respond(
        request,
        503,
        ToolResult('Resource transaction unavailable', isError: true),
      );
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    ToolResult result,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(result.toJson()));
    await request.response.close();
  }
}

/// Sends portable credentials to an independently hosted resource service.
class FencedResourceClient {
  FencedResourceClient({
    required this.baseUrl,
    required this.resourceId,
    String? controlKey,
    this.requestTimeout = const Duration(minutes: 2),
  }) : _controlKey = controlKey {
    if (!['http', 'https'].contains(baseUrl.scheme) ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        !baseUrl.path.endsWith('/') ||
        resourceId.isEmpty ||
        requestTimeout <= Duration.zero ||
        (controlKey != null && RegExp(r'[\r\n]').hasMatch(controlKey))) {
      throw ArgumentError('Invalid resource client configuration');
    }
  }
  final Uri baseUrl;
  final String resourceId;
  final String? _controlKey;
  final Duration requestTimeout;

  Future<ToolResult> _request(
    String route,
    Map<String, Object?> body, {
    Duration? timeout,
  }) async {
    final client = HttpClient();
    try {
      return await (() async {
        final url = baseUrl.resolve(route);
        final request = await client.postUrl(url);
        request.headers.contentType = ContentType.json;
        if (_controlKey != null) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer $_controlKey',
          );
        }
        request.write(jsonEncode(body));
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 4 * 1024 * 1024) {
            throw const FormatException('Resource response too large');
          }
        }
        if (response.statusCode != 200 && response.statusCode != 409) {
          throw HttpException('Resource service HTTP ${response.statusCode}');
        }
        return ToolResult.fromJson(
          (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>(),
        );
      })().timeout(timeout ?? requestTimeout);
    } finally {
      client.close(force: true);
    }
  }

  /// Activates resource-side authority using an idempotent control request.
  Future<RemoteWritePermit> activate({
    required String activationId,
    required String sessionId,
    required String runId,
    required int expectedGeneration,
    RemoteWritePermit? parent,
    bool active = true,
    Map<String, Object?>? ownerAuthorization,
  }) async {
    final result = await _request('activate', {
      'resourceId': resourceId,
      'activationId': activationId,
      'sessionId': sessionId,
      'runId': runId,
      'expectedGeneration': expectedGeneration,
      'parentScopeId': parent?.scopeId,
      'parentRunId': parent?.runId,
      'active': active,
      'ownerAuthorization': ownerAuthorization,
    });
    if (result.isError) {
      throw StateError('Resource activation rejected: ${result.data['code']}');
    }
    return RemoteWritePermit.fromJson(
      (result.data['permit'] as Map).cast<String, Object?>(),
    );
  }

  /// Waits for durable revocation acknowledgement at the write endpoint.
  Future<void> revoke(RemoteWritePermit permit) async {
    final result = await _request('revoke', {
      'permit': permit.toJson(),
    }, timeout: _leaseTimeout(permit));
    if (result.isError) {
      throw StateError('Resource revocation rejected: ${result.data['code']}');
    }
  }

  Duration _leaseTimeout(RemoteWritePermit permit) => permit.leaseTtlMs == null
      ? requestTimeout
      : Duration(
          milliseconds: min(
            requestTimeout.inMilliseconds,
            max(50, permit.leaseTtlMs! ~/ 3),
          ),
        );

  /// Renews one live scope without granting permission to an expired scope.
  Future<ToolResult> renew(
    RemoteWritePermit permit,
    String renewalId,
    int expectedExpiryMs,
  ) => _request('renew', {
    'permit': permit.toJson(),
    'renewalId': renewalId,
    'expectedExpiryMs': expectedExpiryMs,
  }, timeout: _leaseTimeout(permit));

  /// Obtains a durable resource-side stop or current lease status.
  Future<ToolResult> leaseStatus(RemoteWritePermit permit) => _request(
    'lease_status',
    {'permit': permit.toJson()},
    timeout: _leaseTimeout(permit),
  );

  /// Submits a patch that is checked within the server's resource transaction.
  Future<ToolResult> commit(
    RemoteWritePermit permit, {
    required String operationId,
    required Map<String, Object?> patch,
  }) => _request('commit', {
    'permit': permit.toJson(),
    'operationId': operationId,
    'patch': patch,
  });

  /// Recovers a known result without replaying an uncertain network write.
  Future<ToolRecovery> recover(
    RemoteWritePermit permit,
    String operationId,
  ) async {
    final result = await _request('receipt', {
      'permit': permit.toJson(),
      'operationId': operationId,
    });
    return result.isError
        ? const ToolRecovery.unknown()
        : ToolRecovery.completed(result);
  }

  /// Reads the authoritative resource and its sanitized audit history.
  Future<ToolResult> inspect() =>
      _request('inspect', {'resourceId': resourceId});
}

/// Automatically activates and revokes portable authority for a runtime tree.
///
/// Share this instance with managers and tools in one task tree. External
/// workers keep the original permit; they never receive the control key.
/// Configure [onlineAuthorization] and the resource service's online policy
/// to reject fresh admissions during cancellation, before remote lease expiry.
class RemoteResourceTaskAuthority implements ResourceTaskAuthority {
  RemoteResourceTaskAuthority(this.client, {this.onlineAuthorization});
  final FencedResourceClient client;

  /// The live owner admission closed before cancellation starts waiting.
  final OnlineResourceAuthorization? onlineAuthorization;
  final Map<String, RemoteWritePermit> _permits = {};
  final List<Map<String, Object?>> _stopProofs = [];

  /// The sanitized, acknowledged stop evidence for retired activations.
  List<Map<String, Object?>> get stopProofs => List.unmodifiable(_stopProofs);

  /// Returns a credential captured before delayed work is launched.
  RemoteWritePermit permitFor(ToolContext context) {
    final permit = _permits[context.sessionId];
    if (permit == null ||
        permit.runId != context.runId ||
        context.cancellation.isCancelled) {
      throw StateError(
        'No active remote resource authority for this execution',
      );
    }
    return permit;
  }

  @override
  Future<ResourceTaskLease> activate(SessionSnapshot snapshot) async {
    final parent = snapshot.parentSessionId == null
        ? null
        : _permits[snapshot.parentSessionId];
    if (snapshot.parentSessionId != null &&
        (parent == null || parent.runId != snapshot.parentRunId)) {
      throw StateError('Remote resource parent authority is missing');
    }
    final expected =
        parent?.generation ??
        (await client.inspect()).data['generation'] as int;
    final permit = await client.activate(
      activationId: jsonEncode([
        snapshot.id,
        snapshot.runId,
        snapshot.revision,
      ]),
      sessionId: snapshot.id,
      runId: snapshot.runId!,
      expectedGeneration: expected,
      parent: parent,
      active: !snapshot.stopRequested,
      ownerAuthorization: parent == null
          ? onlineAuthorization?.registration
          : null,
    );
    _permits[snapshot.id] = permit;
    onlineAuthorization?.register(
      permit,
      parent: parent,
      active: !snapshot.stopRequested,
    );
    Future<void> close() async {
      if (identical(_permits[snapshot.id], permit)) {
        _permits.remove(snapshot.id);
      }
    }

    if (permit.leaseTtlMs != null) {
      final lease = _RenewingRemoteLease(
        client,
        permit,
        onClosed: close,
        onProof: (proof) => _stopProofs.add(Map.unmodifiable(proof)),
        active: !snapshot.stopRequested,
      );
      return _AdmissionLease(lease, () => onlineAuthorization?.stop(permit));
    }
    return _AdmissionLease(
      _RemoteLease(() async {
        await client.revoke(permit);
        await close();
      }),
      () => onlineAuthorization?.stop(permit),
    );
  }
}

class _RenewingRemoteLease implements RenewableResourceTaskLease {
  _RenewingRemoteLease(
    this.client,
    this.permit, {
    required this.onClosed,
    required this.onProof,
    required bool active,
  }) : _expiry = permit.initialExpiryMs! {
    if (active) _schedule();
  }
  final FencedResourceClient client;
  final RemoteWritePermit permit;
  final Future<void> Function() onClosed;
  final void Function(Map<String, Object?>) onProof;
  Timer? _timer;
  Future<void>? _renewing;
  Future<void>? _closing;
  bool _stopped = false;
  int _expiry;
  int _renewal = 0;
  void _schedule() {
    if (_stopped) return;
    _timer = Timer(
      Duration(milliseconds: max(10, permit.leaseTtlMs! ~/ 3)),
      () {
        _renewing = _renew();
      },
    );
  }

  Future<void> _renew() async {
    try {
      final result = await client.renew(
        permit,
        '${permit.scopeId}:${++_renewal}',
        _expiry,
      );
      if (!result.isError) {
        _expiry = result.data['expiresAtMs'] as int;
      } else if (!_stopped) {
        final status = await client.leaseStatus(permit);
        if (status.isError || status.data['stopped'] == true) {
          stopRenewal();
          return;
        }
        _expiry = status.data['expiresAtMs'] as int;
      }
    } catch (_) {
      // Failed renewal never grants local authority. The resource will expire
      // it unless a subsequent conditional request is actually acknowledged.
    } finally {
      _schedule();
    }
  }

  @override
  void stopRenewal() {
    _stopped = true;
    _timer?.cancel();
  }

  @override
  Future<void> revoke() => _closing ??= _stop();
  Future<void> _stop() async {
    stopRenewal();
    await _renewing;
    Object? revokeError;
    try {
      await client.revoke(permit);
      onProof({
        'scopeId': permit.scopeId,
        'runId': permit.runId,
        'generation': permit.generation,
        'reason': 'revoke_acknowledged',
        'stopped': true,
      });
      await onClosed();
      return;
    } catch (error) {
      revokeError = error;
    }
    // Uncertainty keeps the runtime writer lease held. A local clock or elapsed
    // timeout is never treated as a stop acknowledgement.
    while (true) {
      try {
        final status = await client.leaseStatus(permit);
        if (!status.isError && status.data['stopped'] == true) {
          onProof({
            ...status.data,
            'reason': status.data['reason'],
            'revokeErrorType': revokeError.runtimeType.toString(),
          });
          await onClosed();
          return;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class _RemoteLease implements ResourceTaskLease {
  _RemoteLease(this._revoke);
  final Future<void> Function() _revoke;
  @override
  Future<void> revoke() => _revoke();
}

class _AdmissionLease
    implements RenewableResourceTaskLease, ResourceTaskAdmissionLease {
  _AdmissionLease(this.lease, this._closeAdmission);
  final ResourceTaskLease lease;
  final void Function() _closeAdmission;
  @override
  void stopAdmission() => _closeAdmission();
  @override
  void stopRenewal() {
    stopAdmission();
    if (lease case RenewableResourceTaskLease renewable) {
      renewable.stopRenewal();
    }
  }

  @override
  Future<void> revoke() {
    stopRenewal();
    return lease.revoke();
  }
}
