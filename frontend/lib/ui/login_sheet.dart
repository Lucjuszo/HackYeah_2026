import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../auth/auth.dart';
import 'theme.dart';

/// Login buttons in display order: (provider, label, logo, tint the logo with the text colour).
const List<(String, String, String, bool)> _loginOptions = [
  ('github', 'Połącz z GitHub', 'assets/logo_github.svg', true),
  (
    'google',
    'Połącz z Google',
    'assets/images/google-icon-logo-svgrepo-com.svg',
    false,
  ),
];

/// Providers to show for what the backend reports: known ones in display order. GitHub alone
/// until the list arrives, or when it can't be loaded or holds nothing we know.
List<String> visibleProviders(List<String>? configured) {
  final known = [
    for (final (provider, _, _, _) in _loginOptions)
      if (configured?.contains(provider) ?? false) provider,
  ];
  return known.isEmpty ? const ['github'] : known;
}

/// Opens the login page (GitHub / Google) when an action needs an authenticated user.
///
/// A successful OAuth flow returns the access token through the page route. Closing the
/// page with the back arrow returns null and leaves the original action untouched.
Future<String?> requireLogin(
  BuildContext context,
  AuthController auth, {
  String? reason,
}) async {
  await auth.restore();
  final token = auth.token;
  if (token != null) return token;
  if (!context.mounted) return null;
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(builder: (_) => _LoginPage(auth: auth)),
  );
}

class _LoginPage extends StatefulWidget {
  const _LoginPage({required this.auth});

  final AuthController auth;

  @override
  State<_LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<_LoginPage> {
  List<String> _providers = visibleProviders(null);
  String? _pending;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.auth.providers().then(
      (List<String> configured) {
        if (mounted) setState(() => _providers = visibleProviders(configured));
      },
      onError: (Object _) {
        // Backend unreachable: keep the GitHub button, the login itself will report the error.
      },
    );
  }

  void _login(String provider) {
    setState(() {
      _pending = provider;
      _error = null;
    });
    final auth = widget.auth;
    // Keep login directly inside the button callback so browser OAuth popups are allowed.
    auth
        .login(provider)
        .then(
          (String token) {
            if (mounted) Navigator.of(context).pop(token);
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _pending = null;
              _error = error is LoginException
                  ? error.message
                  : 'Logowanie nie powiodło się. Spróbuj ponownie.';
            });
          },
        );
  }

  Widget _button(String provider, String label, String logo, bool tinted) {
    return SizedBox(
      width: 240,
      child: OutlinedButton.icon(
        key: ValueKey<String>('login-$provider'),
        onPressed: _pending == null ? () => _login(provider) : null,
        icon: _pending == provider
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.ink,
                ),
              )
            : SvgPicture.asset(
                logo,
                width: 17,
                height: 17,
                colorFilter: tinted
                    ? ColorFilter.mode(AppColors.ink, BlendMode.srcIn)
                    : null,
              ),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.ink,
          side: BorderSide(color: AppColors.ink.withValues(alpha: 0.45)),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          key: const ValueKey<String>('login-back'),
          tooltip: 'Wróć',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SvgPicture.asset(
                  'assets/focus_map_logo.svg',
                  width: 142,
                  height: 68,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 34),
                for (final (provider, label, logo, tinted) in _loginOptions)
                  if (_providers.contains(provider))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _button(provider, label, logo, tinted),
                    ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.closed,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
