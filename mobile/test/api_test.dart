import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pair_mobile/api.dart';

class MemoryStore implements SessionStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  group('API origin', () {
    test('permits debug emulator and HTTPS origins', () {
      expect(
        validateApiBase('http://10.0.2.2:5000', allowDebugHttp: true).host,
        '10.0.2.2',
      );
      expect(
        validateApiBase(
          'https://api.example.test',
          allowDebugHttp: false,
        ).scheme,
        'https',
      );
    });
    test('rejects insecure, malformed and non-origin URLs', () {
      for (final url in [
        'http://10.0.2.2:5000',
        'http://example.test',
        'https://u:p@example.test',
        'https://example.test/path',
        'https://example.test?x=1',
        'not-a-url',
      ]) {
        expect(
          () => validateApiBase(url, allowDebugHttp: false),
          throwsFormatException,
          reason: url,
        );
      }
      expect(
        () => validateApiBase('http://example.test', allowDebugHttp: true),
        throwsFormatException,
      );
    });
  });

  test(
    'stores session per origin and sends it with verified requests',
    () async {
      final store = MemoryStore();
      final requests = <http.Request>[];
      final api = PairApi(
        baseUrl: 'http://127.0.0.1:5000',
        allowDebugHttp: true,
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/login')) {
            return http.Response(
              '{"message":"ok"}',
              200,
              headers: {'set-cookie': 'session=abc.def; HttpOnly; Path=/'},
            );
          }
          return http.Response('{"ok":true}', 200);
        }),
      );
      await api.request(
        'POST',
        '/api/v1/auth/login',
        body: {'email': 'a', 'password': 'b'},
      );
      expect(store.values['pair.session.http://127.0.0.1:5000'], 'abc.def');
      await api.request('PUT', '/api/v1/answers/1', body: {'value': 5});
      expect(requests.last.headers['cookie'], 'session=abc.def');
      expect(requests.last.headers['x-pair-request'], '1');
      expect(jsonDecode(requests.last.body), {'value': 5});
      final second = PairApi(
        baseUrl: 'http://127.0.0.1:5001',
        allowDebugHttp: true,
        sessionStore: store,
        client: MockClient((request) async => http.Response('{}', 200)),
      );
      await second.restore();
      expect(second.hasSession, isFalse);
      api.close();
      second.close();
    },
  );

  test('unauthorized response clears persisted session and notifies', () async {
    final store = MemoryStore();
    store.values['pair.session.http://localhost:5000'] = 'abc';
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: store,
      client: MockClient(
        (request) async => http.Response('{"error":"Sign in"}', 401),
      ),
    );
    var notified = false;
    api.onUnauthorized = () => notified = true;
    await api.restore();
    await expectLater(
      api.request('GET', '/api/v1/me'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
    );
    expect(notified, isTrue);
    expect(api.hasSession, isFalse);
    expect(store.values, isEmpty);
    api.close();
  });

  test(
    'rate limit response preserves session and surfaces retry message',
    () async {
      final store = MemoryStore();
      store.values['pair.session.http://localhost:5000'] = 'abc';
      final api = PairApi(
        baseUrl: 'http://localhost:5000',
        allowDebugHttp: true,
        sessionStore: store,
        client: MockClient(
          (request) async => http.Response(
            '{"error":"Too many attempts. Please try again in 30 seconds."}',
            429,
            headers: {'retry-after': '30'},
          ),
        ),
      );
      await api.restore();
      await expectLater(
        api.request('POST', '/api/v1/auth/verify', body: {'code': 'bad'}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.status, 'status', 429)
              .having((e) => e.message, 'message', contains('30 seconds')),
        ),
      );
      expect(api.hasSession, isTrue);
      expect(store.values['pair.session.http://localhost:5000'], 'abc');
      api.close();
    },
  );

  test('handles secure expiring sessions and logout cookie removal', () async {
    final store = MemoryStore();
    final api = PairApi(
      baseUrl: 'https://api.example.test',
      allowDebugHttp: false,
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            '{}',
            200,
            headers: {
              'set-cookie':
                  'session=abc.def; Expires=Wed, 09 Jun 2038 10:18:14 GMT; Secure; HttpOnly; Path=/; SameSite=Strict',
            },
          );
        }
        expect(request.headers['cookie'], 'session=abc.def');
        return http.Response(
          '{}',
          200,
          headers: {
            'set-cookie':
                'session=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly; Path=/; SameSite=Strict',
          },
        );
      }),
    );
    await api.request('POST', '/api/v1/auth/login', body: {});
    expect(api.hasSession, isTrue);
    await api.request('POST', '/api/v1/auth/logout', body: {});
    expect(api.hasSession, isFalse);
    expect(store.values, isEmpty);
    api.close();
  });

  test('refuses redirects and insecure production cookies', () async {
    final redirect = PairApi(
      baseUrl: 'https://api.example.test',
      allowDebugHttp: false,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://elsewhere.test'},
        );
      }),
    );
    await expectLater(
      redirect.request('GET', '/api/v1/me'),
      throwsA(isA<ApiException>()),
    );
    redirect.close();
    final insecure = PairApi(
      baseUrl: 'https://api.example.test',
      allowDebugHttp: false,
      sessionStore: MemoryStore(),
      client: MockClient(
        (request) async => http.Response(
          '{}',
          200,
          headers: {'set-cookie': 'session=abc; HttpOnly; Path=/'},
        ),
      ),
    );
    await expectLater(
      insecure.request('POST', '/api/v1/auth/login', body: {}),
      throwsA(isA<ApiException>()),
    );
    expect(insecure.hasSession, isFalse);
    insecure.close();
  });

  test(
    'surfaces invalid responses, server errors and invalid photos',
    () async {
      var call = 0;
      final api = PairApi(
        baseUrl: 'http://localhost:5000',
        allowDebugHttp: true,
        sessionStore: MemoryStore(),
        client: MockClient((request) async {
          call++;
          if (call == 1) return http.Response('not json', 200);
          if (call == 2) return http.Response('{"error":"No access"}', 403);
          return http.Response(
            'not an image',
            200,
            headers: {'content-type': 'text/html'},
          );
        }),
      );
      await expectLater(
        api.request('GET', '/api/v1/me'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        api.request('GET', '/api/v1/me'),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', 'No access'),
        ),
      );
      await expectLater(api.photo(2), throwsA(isA<ApiException>()));
      await expectLater(
        api.uploadPhoto(Uint8List(0)),
        throwsA(isA<ApiException>()),
      );
      api.close();
    },
  );

  test('rejects a corrupt persisted session', () async {
    final store = MemoryStore();
    store.values['pair.session.http://localhost:5000'] = 'bad\r\ncookie';
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: store,
    );
    await expectLater(api.restore(), throwsA(isA<ApiException>()));
    expect(store.values, isEmpty);
    api.close();
  });
}
