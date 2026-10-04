import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../auth/auth.dart';
import 'theme.dart';

/// Opens the GitHub login page when an action needs an authenticated user.
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
  bool _busy = false;
  String? _error;

  void _login() {
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = widget.auth;
    // Keep login directly inside the button callback so browser OAuth popups are allowed.
    auth
        .login('github')
        .then(
          (String token) {
            if (mounted) Navigator.of(context).pop(token);
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _busy = false;
              _error = error is LoginException
                  ? error.message
                  : 'Logowanie nie powiodło się. Spróbuj ponownie.';
            });
          },
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
                OutlinedButton.icon(
                  key: const ValueKey<String>('login-github'),
                  onPressed: _busy ? null : _login,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.ink,
                          ),
                        )
                      : SvgPicture.asset(
                        'assets/logo_github.svg',
                        width: 17,
                        height: 17,
                        colorFilter: ColorFilter.mode(AppColors.ink, BlendMode.srcIn),
                      ),
                  label: const Text('Połącz z GitHub'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.ink,
                    side: BorderSide(
                      color: AppColors.ink.withValues(alpha: 0.45),
                    ),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
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
