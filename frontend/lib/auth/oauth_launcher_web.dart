import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'oauth_launcher_base.dart';

/// Must match web/auth_callback.html.
const String _resultKey = 'miejscowki-auth-result';
const String _messageType = 'miejscowki-auth';

/// Google login in a popup. The backend sends the popup back to web/auth_callback.html with the token
/// in the fragment; that page hands it over by postMessage and, because Google's pages may cut the
/// popup's link to its opener (COOP), also through localStorage (a `storage` event here).
class _PopupLauncher implements OAuthLauncher {
  @override
  Future<LoginResult> login(Uri loginUrl) {
    final callback = Uri.base.removeFragment().replace(query: '').resolve('auth_callback.html');
    final url = loginUrl.replace(queryParameters: <String, String>{
      ...loginUrl.queryParameters,
      'return_to': callback.toString(),
    });

    web.window.localStorage.removeItem(_resultKey);
    // Synchronously, still inside the click: otherwise the browser blocks the popup.
    final popup = web.window.open(url.toString(), 'miejscowki-login', 'popup,width=520,height=680');
    if (popup == null) {
      return Future<LoginResult>.error(
        const LoginException('Przeglądarka zablokowała okno logowania. Zezwól na wyskakujące okna dla tej strony.'),
      );
    }

    final completer = Completer<LoginResult>();
    late final StreamSubscription<web.MessageEvent> messages;
    late final StreamSubscription<web.StorageEvent> storage;
    late final Timer timeout;

    void finish(Map<String, String> params) {
      if (completer.isCompleted) return;
      messages.cancel();
      storage.cancel();
      timeout.cancel();
      web.window.localStorage.removeItem(_resultKey);
      try {
        completer.complete(parseLoginParams(params));
      } on LoginException catch (e) {
        completer.completeError(e);
      }
    }

    Map<String, String> asParams(Object? data) => <String, String>{
      if (data is Map)
        for (final entry in data.entries)
          if (entry.value != null) '${entry.key}': '${entry.value}',
    };

    messages = web.EventStreamProviders.messageEvent.forTarget(web.window).listen((web.MessageEvent event) {
      if (event.origin != web.window.location.origin) return;
      final data = event.data.dartify();
      if (data is Map && data['type'] == _messageType) finish(asParams(data));
    });
    storage = web.EventStreamProviders.storageEvent.forTarget(web.window).listen((web.StorageEvent event) {
      final value = event.newValue;
      if (event.key != _resultKey || value == null) return;
      try {
        finish(asParams(jsonDecode(value)));
      } on FormatException {
        // not ours
      }
    });
    timeout = Timer(loginTimeout, () {
      if (completer.isCompleted) return;
      messages.cancel();
      storage.cancel();
      completer.completeError(const LoginException('Logowanie przerwane. Spróbuj ponownie.'));
    });
    return completer.future;
  }
}

OAuthLauncher createOAuthLauncher() => _PopupLauncher();
