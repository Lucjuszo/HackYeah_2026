import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

import 'oauth_launcher_base.dart';

/// Desktop: OAuth login in the system browser, which the backend sends back to a one-off page
/// served by the app on 127.0.0.1 (the token travels in the URL fragment, so that page reads it
/// with JavaScript and passes it to the app as a query string).
class _LoopbackLauncher implements OAuthLauncher {
  @override
  Future<LoginResult> login(Uri loginUrl) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final returnTo = 'http://127.0.0.1:${server.port}/callback';
    final completer = Completer<LoginResult>();

    server.listen((HttpRequest request) async {
      final response = request.response..headers.contentType = ContentType.html;
      if (request.uri.path == '/callback') {
        response.write(
          _page(
            'Logowanie…',
            '<script>location.replace("/done?" + location.hash.slice(1));</script>',
          ),
        );
      } else if (request.uri.path == '/done') {
        try {
          final result = parseLoginParams(request.uri.queryParameters);
          response.write(
            _page(
              'Zalogowano',
              '<p>Zalogowano. Możesz wrócić do aplikacji Focus Map.</p>',
            ),
          );
          if (!completer.isCompleted) completer.complete(result);
        } on LoginException catch (e) {
          response.write(_page('Błąd logowania', '<p>${e.message}</p>'));
          if (!completer.isCompleted) completer.completeError(e);
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });

    final url = loginUrl.replace(
      queryParameters: <String, String>{
        ...loginUrl.queryParameters,
        'return_to': returnTo,
      },
    );
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const LoginException(
          'Nie udało się otworzyć przeglądarki do logowania.',
        );
      }
      return await completer.future.timeout(
        loginTimeout,
        onTimeout: () => throw const LoginException(
          'Logowanie przerwane. Spróbuj ponownie.',
        ),
      );
    } finally {
      await server.close(force: true);
    }
  }

  static String _page(String title, String body) =>
      '<!DOCTYPE html><html lang="pl"><head><meta charset="utf-8"><title>$title</title></head>'
      '<body style="font-family:sans-serif;padding:32px">$body</body></html>';
}

OAuthLauncher createOAuthLauncher() => _LoopbackLauncher();
