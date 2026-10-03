class LoginResult {
  const LoginResult(this.accessToken, this.expiresIn);

  final String accessToken;
  final int expiresIn;
}

class LoginException implements Exception {
  const LoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class OAuthLauncher {
  /// [loginUrl] is the backend's /auth/{provider}/login; the launcher adds `return_to`.
  Future<LoginResult> login(Uri loginUrl);
}

/// Message for the `error` the backend puts in the fragment.
String loginErrorMessage(String? error) => switch (error) {
  'access_denied' => 'Logowanie anulowane.',
  _ => 'Logowanie nie powiodło się. Spróbuj ponownie.',
};

/// Reads `access_token`, `expires_in`, `error` (from the fragment the backend redirects with).
LoginResult parseLoginParams(Map<String, String> params) {
  final token = params['access_token'];
  if (token == null || token.isEmpty) {
    throw LoginException(loginErrorMessage(params['error']));
  }
  return LoginResult(token, int.tryParse(params['expires_in'] ?? '') ?? 3600);
}

const Duration loginTimeout = Duration(minutes: 5);
