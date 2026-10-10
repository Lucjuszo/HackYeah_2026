import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import '../api/places_api.dart';
import 'oauth_launcher.dart';

export 'oauth_launcher.dart';

class StoredToken {
  const StoredToken(this.accessToken, this.expiresAt);

  final String accessToken;
  final DateTime expiresAt;

  /// A minute of margin: a token about to expire would fail mid-request.
  bool get isValid =>
      DateTime.now().isBefore(expiresAt.subtract(const Duration(minutes: 1)));
}

abstract class TokenStore {
  Future<StoredToken?> read();
  Future<void> write(StoredToken token);
  Future<void> clear();
}

/// localStorage on the web, a settings file on Windows.
class PrefsTokenStore implements TokenStore {
  static const _tokenKey = 'auth.access_token';
  static const _expiresKey = 'auth.expires_at';

  @override
  Future<StoredToken?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final expires = prefs.getInt(_expiresKey);
    if (token == null || expires == null) return null;
    return StoredToken(token, DateTime.fromMillisecondsSinceEpoch(expires));
  }

  @override
  Future<void> write(StoredToken token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token.accessToken);
    await prefs.setInt(_expiresKey, token.expiresAt.millisecondsSinceEpoch);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_expiresKey);
  }
}

class MemoryTokenStore implements TokenStore {
  StoredToken? token;

  @override
  Future<StoredToken?> read() async => token;

  @override
  Future<void> write(StoredToken token) async => this.token = token;

  @override
  Future<void> clear() async => token = null;
}

/// Login state: our access token from the backend (GitHub or Google login), kept between app starts,
/// and who is logged in.
class AuthController {
  AuthController({
    required this.api,
    TokenStore? store,
    OAuthLauncher? launcher,
  }) : _store = store ?? PrefsTokenStore(),
       _launcher = launcher ?? createOAuthLauncher();

  final PlacesApi api;
  final TokenStore _store;
  final OAuthLauncher _launcher;
  StoredToken? _token;
  CurrentUser? _user;
  Future<void>? _restoring;
  Future<List<String>>? _providers;

  /// Loads a token saved earlier; call once at startup.
  Future<void> restore() => _restoring ??= () async {
    try {
      final saved = await _store.read();
      if (saved != null && saved.isValid) {
        _token = saved;
      } else if (saved != null) {
        await _store.clear();
      }
    } on Object {
      // No storage (e.g. blocked site data): just log in again when needed.
    }
  }();

  bool get isLoggedIn => _token?.isValid ?? false;

  /// The current token, or null when a login is needed.
  String? get token => isLoggedIn ? _token!.accessToken : null;

  /// Login options configured on the backend (cached).
  Future<List<String>> providers() =>
      _providers ??= api.loginProviders().catchError((Object e) {
        _providers = null; // try again next time
        throw e;
      });

  /// Logs in with [provider] (`github`, `google`); throws [LoginException].
  ///
  /// Call it straight from a tap handler, before any other `await`: on the web the login opens a
  /// popup, which browsers allow only as a direct reaction to a click.
  Future<String> login(String provider) {
    return _launcher.login(api.loginUrl(provider)).then((
      LoginResult result,
    ) async {
      final stored = StoredToken(
        result.accessToken,
        DateTime.now().add(Duration(seconds: result.expiresIn)),
      );
      _token = stored;
      _user = null;
      try {
        await _store.write(stored);
      } on Object {
        // Still works for this session.
      }
      return stored.accessToken;
    });
  }

  /// Who is logged in (null when nobody); loaded once per login.
  Future<CurrentUser?> currentUser() async {
    await restore();
    final token = this.token;
    if (token == null) return null;
    if (_user != null) return _user;
    try {
      return _user = await api.me(token: token);
    } on ApiException catch (e) {
      if (e.statusCode == 401) await invalidate();
      return null;
    }
  }

  /// The backend rejected the token (expired, secret changed): forget it; the next action logs in again.
  Future<void> invalidate() async {
    _token = null;
    _user = null;
    try {
      await _store.clear();
    } on Object {
      // ignore
    }
  }
}
