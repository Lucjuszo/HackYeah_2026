/// Runs the backend's OAuth login in a browser and returns our access token.
library;

export 'oauth_launcher_base.dart';
export 'oauth_launcher_stub.dart'
    if (dart.library.js_interop) 'oauth_launcher_web.dart'
    if (dart.library.io) 'oauth_launcher_io.dart';
