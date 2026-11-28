import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => message;
}

abstract interface class SessionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

Uri validateApiBase(String value, {required bool allowDebugHttp}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('Configure a valid API origin without a path.');
  }
  final local = {
    'localhost',
    '127.0.0.1',
    '::1',
    '10.0.2.2',
  }.contains(uri.host);
  if (uri.scheme != 'https' &&
      !(allowDebugHttp && uri.scheme == 'http' && local)) {
    throw const FormatException(
      'HTTPS is required, except for local development in debug builds.',
    );
  }
  return uri;
}

class PairApi {
  PairApi({
    required String baseUrl,
    required SessionStore sessionStore,
    http.Client? client,
    bool? allowDebugHttp,
  }) : _allowDebugHttp = allowDebugHttp ?? kDebugMode,
       base = validateApiBase(
         baseUrl,
         allowDebugHttp: allowDebugHttp ?? kDebugMode,
       ),
       _store = sessionStore,
       _client = client ?? http.Client();

  final Uri base;
  final SessionStore _store;
  final http.Client _client;
  final bool _allowDebugHttp;
  String? _session;
  String get _sessionKey => 'pair.session.${base.origin}';
  bool get hasSession => _session != null;
  VoidCallback? onUnauthorized;

  Future<void> restore() async {
    if (kIsWeb) {
      _session = 'web-session';
      return;
    }
    _session = await _store.read(_sessionKey);
    if (_session != null && !_validSession(_session!)) {
      await clearSession();
      throw const ApiException(
        'The saved session is invalid. Please sign in again.',
      );
    }
  }

  bool _validSession(String value) =>
      value.length <= 4096 && RegExp(r'^[A-Za-z0-9._~%-]+$').hasMatch(value);

  Future<void> clearSession() async {
    _session = null;
    await _store.delete(_sessionKey);
  }

  Future<void> _saveCookie(String? header) async {
    if (header == null) return;
    final Cookie cookie;
    try {
      cookie = Cookie.fromSetCookieValue(header);
    } on FormatException {
      throw const ApiException('The server returned an invalid session.');
    }
    if (cookie.name != 'session') return;
    if (cookie.value.isEmpty || cookie.maxAge == 0) {
      await clearSession();
      return;
    }
    if (!_validSession(cookie.value) || (!_allowDebugHttp && !cookie.secure)) {
      throw const ApiException('The server returned an insecure session.');
    }
    await _store.write(_sessionKey, cookie.value);
    _session = cookie.value;
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    request.followRedirects = false;
    request.headers['Accept'] = 'application/json';
    request.headers['X-Pair-Request'] = '1';
    if (_session != null && !kIsWeb) {
      request.headers['Cookie'] = 'session=$_session';
    }
    try {
      final stream = await _client
          .send(request)
          .timeout(const Duration(seconds: 20));
      final response = await http.Response.fromStream(
        stream,
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const ApiException(
          'The server redirected the request; it was not followed.',
        );
      }
      if (response.statusCode == 401) {
        await clearSession();
        onUnauthorized?.call();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        String message = 'Request failed (${response.statusCode}).';
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic> && decoded['error'] is String) {
            message = decoded['error'] as String;
          }
        } on FormatException {
          // Non-JSON error responses retain the HTTP status.
        }
        throw ApiException(message, status: response.statusCode);
      }
      if (kIsWeb) {
        if (request.url.path == '/api/v1/auth/login' ||
            request.url.path == '/api/v1/auth/activate') {
          _session = 'web-session';
        }
      } else {
        await _saveCookie(response.headers['set-cookie']);
      }
      return response;
    } on SocketException {
      throw const ApiException(
        'Cannot connect to the server. Check your connection.',
      );
    } on TimeoutException {
      throw const ApiException('The request timed out. Please try again.');
    } on http.ClientException {
      throw const ApiException(
        'Cannot connect to the server. Check your connection.',
      );
    }
  }

  Future<Object?> request(String method, String path, {Json? body}) async {
    if (!path.startsWith('/api/v1/') ||
        path.contains('..') ||
        path.contains('?')) {
      throw ArgumentError.value(path, 'path', 'Expected a local API path.');
    }
    final request = http.Request(method, base.resolve(path));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _send(request);
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const ApiException('The server returned an invalid response.');
    }
  }

  Future<Uint8List> photo(int id) async {
    final response = await _send(
      http.Request('GET', base.resolve('/api/v1/photo/$id')),
    );
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.toLowerCase().startsWith('image/jpeg')) {
      throw const ApiException('The server returned an invalid photo.');
    }
    return response.bodyBytes;
  }

  Future<void> uploadPhoto(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 3900000) {
      throw const ApiException('Choose an image smaller than 3.9 MB.');
    }
    final request = http.MultipartRequest(
      'POST',
      base.resolve('/api/v1/photo'),
    );
    request.files.add(
      http.MultipartFile.fromBytes('photo', bytes, filename: 'photo.jpg'),
    );
    await _send(request);
  }

  Future<Account> me() async =>
      Account.fromJson(await request('GET', '/api/v1/me'));
  Future<List<Question>> questions() async =>
      jsonList(await request('GET', '/api/v1/questions'), Question.fromJson);
  Future<WeeklyIntroductions> introductions() async =>
      WeeklyIntroductions.fromJson(await request('GET', '/api/v1/matches'));
  Future<List<Conversation>> conversations() async => jsonList(
    await request('GET', '/api/v1/conversations'),
    Conversation.fromJson,
  );
  Future<List<Message>> messages(int id) async => jsonList(
    await request('GET', '/api/v1/conversations/$id/messages'),
    Message.fromJson,
  );

  void close() => _client.close();
}
