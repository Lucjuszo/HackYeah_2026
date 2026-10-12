import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:miejscowki_map/api/places_api.dart';
import 'package:miejscowki_map/auth/auth.dart';

class _Launcher implements OAuthLauncher {
  _Launcher(this.result);

  final Future<LoginResult> Function() result;
  final List<Uri> urls = <Uri>[];

  @override
  Future<LoginResult> login(Uri loginUrl) {
    urls.add(loginUrl);
    return result();
  }
}

/// Backend answering GET /auth/me: 200 for [validToken], 401 otherwise.
PlacesApi _api(String validToken, List<String?> seenAuth) => PlacesApi(
  baseUrl: 'http://api.test',
  client: MockClient((http.Request request) async {
    seenAuth.add(request.headers['Authorization']);
    if (request.url.path == '/auth/me' &&
        request.headers['Authorization'] == 'Bearer $validToken') {
      return http.Response(
        jsonEncode({'id': 'u1', 'name': 'Ala', 'role': 'user'}),
        200,
      );
    }
    return http.Response(
      jsonEncode({'detail': 'Invalid or expired token'}),
      401,
    );
  }),
);

void main() {
  group('parseLoginParams', () {
    test('token i czas ważności z fragmentu', () {
      final result = parseLoginParams({
        'access_token': 'abc',
        'expires_in': '120',
      });
      expect(result.accessToken, 'abc');
      expect(result.expiresIn, 120);
    });

    test('brak czasu ważności: godzina', () {
      expect(parseLoginParams({'access_token': 'abc'}).expiresIn, 3600);
      expect(
        parseLoginParams({'access_token': 'abc', 'expires_in': 'x'}).expiresIn,
        3600,
      );
    });

    test('brak tokenu to błąd, z czytelnym komunikatem', () {
      expect(
        () => parseLoginParams({'error': 'access_denied'}),
        throwsA(
          isA<LoginException>().having(
            (e) => e.message,
            'message',
            'Logowanie anulowane.',
          ),
        ),
      );
      expect(
        () => parseLoginParams({'access_token': ''}),
        throwsA(isA<LoginException>()),
      );
    });

    test('obcy kod błędu nie trafia do komunikatu', () {
      // `error` comes from the URL: never show it as is.
      expect(
        loginErrorMessage('<script>alert(1)</script>'),
        'Logowanie nie powiodło się. Spróbuj ponownie.',
      );
    });
  });

  group('StoredToken', () {
    test('wygasa minutę przed czasem', () {
      final now = DateTime.now();
      expect(
        StoredToken('t', now.add(const Duration(minutes: 5))).isValid,
        isTrue,
      );
      expect(
        StoredToken('t', now.add(const Duration(seconds: 30))).isValid,
        isFalse,
      );
      expect(
        StoredToken('t', now.subtract(const Duration(hours: 1))).isValid,
        isFalse,
      );
    });
  });

  group('AuthController', () {
    test('przeterminowany zapisany token jest usuwany przy starcie', () async {
      final store = MemoryTokenStore()
        ..token = StoredToken(
          'old',
          DateTime.now().subtract(const Duration(minutes: 1)),
        );
      final auth = AuthController(
        api: _api('old', []),
        store: store,
        launcher: _Launcher(() async => throw StateError('unused')),
      );
      await auth.restore();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.token, isNull);
      expect(store.token, isNull);
    });

    test('ważny zapisany token jest przywracany', () async {
      final store = MemoryTokenStore()
        ..token = StoredToken(
          'good',
          DateTime.now().add(const Duration(hours: 1)),
        );
      final seen = <String?>[];
      final auth = AuthController(
        api: _api('good', seen),
        store: store,
        launcher: _Launcher(() async => throw StateError('unused')),
      );
      final user = await auth.currentUser();
      expect(user?.name, 'Ala');
      expect(seen, ['Bearer good']);
    });

    test('logowanie zapisuje token i ładuje użytkownika', () async {
      final store = MemoryTokenStore();
      final launcher = _Launcher(() async => const LoginResult('fresh', 600));
      final auth = AuthController(
        api: _api('fresh', []),
        store: store,
        launcher: launcher,
      );
      expect(await auth.login('github'), 'fresh');
      expect(
        launcher.urls.single.toString(),
        'http://api.test/auth/github/login',
      );
      expect(store.token?.accessToken, 'fresh');
      expect(auth.isLoggedIn, isTrue);
      expect((await auth.currentUser())?.id, 'u1');
    });

    test('nazwa dostawcy jest kodowana w adresie', () {
      final api = _api('x', []);
      expect(
        api.loginUrl('../admin').toString(),
        'http://api.test/auth/..%2Fadmin/login',
      );
    });

    test('odrzucony token (401) jest zapominany', () async {
      final store = MemoryTokenStore()
        ..token = StoredToken(
          'revoked',
          DateTime.now().add(const Duration(hours: 1)),
        );
      final auth = AuthController(
        api: _api('other', []),
        store: store,
        launcher: _Launcher(() async => throw StateError('unused')),
      );
      expect(await auth.currentUser(), isNull);
      expect(auth.isLoggedIn, isFalse);
      expect(store.token, isNull);
    });

    test('nieudane logowanie nie zmienia stanu', () async {
      final store = MemoryTokenStore();
      final auth = AuthController(
        api: _api('x', []),
        store: store,
        launcher: _Launcher(
          () async => throw const LoginException('Logowanie anulowane.'),
        ),
      );
      await expectLater(auth.login('google'), throwsA(isA<LoginException>()));
      expect(auth.isLoggedIn, isFalse);
      expect(store.token, isNull);
    });
  });
}
