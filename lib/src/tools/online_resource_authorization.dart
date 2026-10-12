import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'fenced_resource_store.dart';

/// Hosts live admission checks for a task tree, independently of remote revoke.
///
/// Pass this to RemoteResourceTaskAuthority and close it after all runs settle.
/// Remote services need a reachable endpoint, normally behind TLS.
class OnlineResourceAuthorization {
  OnlineResourceAuthorization._(this._server, this._url, this._key) {
    _server.listen(_handle);
  }
  final HttpServer _server;
  final Uri _url;
  final String _key;
  bool _closed = false;
  final Map<String, ({RemoteWritePermit permit, String? parent, bool active})>
  _scopes = {};

  /// Starts an owner endpoint. Loopback is suitable for local process workers.
  static Future<OnlineResourceAuthorization> start({
    InternetAddress? address,
    int port = 0,
    Uri? advertisedUrl,
  }) async {
    if (advertisedUrl != null &&
        (!['http', 'https'].contains(advertisedUrl.scheme) ||
            advertisedUrl.host.isEmpty ||
            advertisedUrl.userInfo.isNotEmpty ||
            advertisedUrl.hasQuery ||
            advertisedUrl.hasFragment)) {
      throw ArgumentError('Invalid advertised authorization URL');
    }
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    final key = base64Url.encode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    return OnlineResourceAuthorization._(
      server,
      advertisedUrl ?? Uri.parse('http://127.0.0.1:${server.port}/authorize'),
      key,
    );
  }

  /// The secret control registration for the trusted resource service.
  ///
  /// Never send this to a worker or model.
  Map<String, Object?> get registration => {
    'endpoint': _url.toString(),
    'key': _key,
  };

  /// Registers an acknowledged resource activation and its ancestor.
  void register(
    RemoteWritePermit permit, {
    RemoteWritePermit? parent,
    bool active = true,
  }) {
    if (_closed) throw StateError('Authorization endpoint is closed');
    if (_scopes.containsKey(permit.scopeId)) return;
    _scopes[permit.scopeId] = (
      permit: permit,
      parent: parent?.scopeId,
      active: active,
    );
  }

  /// Synchronously closes new admissions, including all descendants.
  void stop(RemoteWritePermit permit) {
    final scope = _scopes[permit.scopeId];
    if (scope != null) {
      _scopes[permit.scopeId] = (
        permit: scope.permit,
        parent: scope.parent,
        active: false,
      );
    }
  }

  bool _allowed(RemoteWritePermit permit) {
    var scope = _scopes[permit.scopeId];
    if (scope == null ||
        !scope.permit.toJson().entries.every(
          (entry) => permit.toJson()[entry.key] == entry.value,
        )) {
      return false;
    }
    final seen = <String>{};
    while (scope != null) {
      if (!scope.active || !seen.add(scope.permit.scopeId)) return false;
      if (scope.parent == null) return true;
      scope = _scopes[scope.parent];
    }
    return false;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'POST' ||
          request.uri.path != _url.path ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $_key') {
        request.response.statusCode = 401;
      } else {
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
          if (bytes.length > 16384) throw const FormatException();
        }
        final body = (jsonDecode(utf8.decode(bytes)) as Map)
            .cast<String, Object?>();
        final permit = RemoteWritePermit.fromJson(
          (body['permit'] as Map).cast<String, Object?>(),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'nonce': body['nonce'], 'allowed': _allowed(permit)}),
        );
      }
    } catch (_) {
      request.response.statusCode = 400;
    } finally {
      await request.response.close();
    }
  }

  /// Stops the endpoint; unreachable admission checks fail closed remotely.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _scopes.clear();
    await _server.close(force: true);
  }
}

/// Queries the trusted owner inside the resource transaction, without caching.
class HttpResourceCommitAuthorizer {
  HttpResourceCommitAuthorizer({this.timeout = const Duration(seconds: 2)}) {
    if (timeout <= Duration.zero) throw ArgumentError('Invalid timeout');
  }
  final Duration timeout;

  /// Returns a denial code on a stopped owner, timeout or malformed response.
  Future<String?> authorize(
    Map<String, Object?> registration,
    RemoteWritePermit permit,
  ) async {
    final client = HttpClient();
    try {
      return await (() async {
        final url = Uri.parse(registration['endpoint'] as String);
        if (!['http', 'https'].contains(url.scheme) ||
            url.userInfo.isNotEmpty) {
          throw const FormatException();
        }
        final nonce = base64Url.encode(
          List.generate(32, (_) => Random.secure().nextInt(256)),
        );
        final request = await client.postUrl(url);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${registration['key'] as String}',
        );
        request.write(jsonEncode({'permit': permit.toJson(), 'nonce': nonce}));
        final response = await request.close();
        if (response.statusCode != 200) throw const FormatException();
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 16384) throw const FormatException();
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map;
        if (body['nonce'] != nonce || body['allowed'] is! bool) {
          throw const FormatException();
        }
        return body['allowed'] == true ? null : 'task_commit_admission_closed';
      })().timeout(timeout);
    } catch (_) {
      return 'online_authorization_unavailable';
    } finally {
      client.close(force: true);
    }
  }
}
