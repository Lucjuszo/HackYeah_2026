import 'oauth_launcher_base.dart';

class _UnsupportedLauncher implements OAuthLauncher {
  @override
  Future<LoginResult> login(Uri loginUrl) => Future<LoginResult>.error(
    const LoginException('Logowanie nie jest dostępne na tej platformie.'),
  );
}

OAuthLauncher createOAuthLauncher() => _UnsupportedLauncher();
