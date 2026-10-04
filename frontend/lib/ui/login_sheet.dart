import 'package:flutter/material.dart';

import '../auth/auth.dart';
import 'theme.dart';

const Map<String, (String, IconData)> _providerLabels = {
  'google': ('Kontynuuj z Google', Icons.g_mobiledata_rounded),
  'github': ('Kontynuuj z GitHub', Icons.code_rounded),
};

/// A token for an action that needs an account: the current one, or after the user picks
/// GitHub / Google in a bottom sheet. Null when they close the sheet.
Future<String?> requireLogin(
  BuildContext context,
  AuthController auth, {
  String? reason,
}) async {
  await auth.restore();
  final token = auth.token;
  if (token != null) return token;
  if (!context.mounted) return null;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _LoginSheet(auth: auth, reason: reason),
  );
}

class _LoginSheet extends StatefulWidget {
  const _LoginSheet({required this.auth, this.reason});

  final AuthController auth;
  final String? reason;

  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  late final Future<List<String>> _providers = widget.auth.providers();
  String? _pending;
  String? _error;

  void _login(String provider) {
    setState(() {
      _pending = provider;
      _error = null;
    });
    // Called directly in the tap: the web login popup is only allowed as a reaction to a click.
    widget.auth
        .login(provider)
        .then(
          (String token) {
            if (mounted) Navigator.of(context).pop(token);
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _pending = null;
              _error = e is LoginException
                  ? e.message
                  : 'Logowanie nie powiodło się. Spróbuj ponownie.';
            });
          },
        );
  }

  Widget _button(String provider) {
    final (label, icon) =
        _providerLabels[provider] ??
        ('Kontynuuj z $provider', Icons.login_rounded);
    final busy = _pending == provider;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: ValueKey<String>('login-$provider'),
          onPressed: _pending == null ? () => _login(provider) : null,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.ink,
                  ),
                )
              : Icon(icon),
          label: Text(label),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.ink,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            padding: const EdgeInsets.symmetric(vertical: 15),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Zaloguj się',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.reason ??
                  'Żeby dodawać miejsca, oceny i opinie, potrzebne jest konto.',
              style: const TextStyle(fontSize: 13, color: AppColors.muted),
            ),
            const SizedBox(height: 18),
            FutureBuilder<List<String>>(
              future: _providers,
              builder:
                  (BuildContext context, AsyncSnapshot<List<String>> snapshot) {
                    if (snapshot.hasError) {
                      return const Text(
                        'Nie udało się połączyć z serwerem. Spróbuj ponownie.',
                        style: TextStyle(color: AppColors.closed),
                      );
                    }
                    final providers = snapshot.data;
                    if (providers == null) {
                      return const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (providers.isEmpty) {
                      return const Text(
                        'Logowanie nie jest skonfigurowane na serwerze.',
                        style: TextStyle(color: AppColors.muted),
                      );
                    }
                    return Column(
                      children: <Widget>[
                        for (final provider in providers) _button(provider),
                      ],
                    );
                  },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.closed, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
