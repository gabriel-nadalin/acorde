import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';

/// Email/password sign-in against the PocketBase `users` collection.
class UserSelectPage extends StatefulWidget {
  const UserSelectPage({super.key});

  @override
  State<UserSelectPage> createState() => _UserSelectPageState();
}

class _UserSelectPageState extends State<UserSelectPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthController>();
    if (auth.isLoggedIn) {
      // Session restored from storage (offline relaunch): skip straight to
      // the user's calendar instead of asking to sign in again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go(auth.myPerformers.isEmpty && auth.myVenues.isEmpty ? '/venues' : '/calendar');
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context);
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      _showMessage(l10n.enterEmailAndPassword);
      return;
    }

    setState(() => _submitting = true);
    final auth = context.read<AuthController>();
    var ok = false;
    try {
      ok = await auth.login(email, password);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _submitting = false);

    if (!ok) {
      _showMessage(l10n.loginFailed);
      return;
    }
    context.go(auth.myPerformers.isEmpty && auth.myVenues.isEmpty ? '/dashboard' : '/calendar');
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signIn)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(labelText: l10n.email),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(labelText: l10n.password),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.signIn),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _submitting ? null : () => context.go('/signup'),
                  child: Text(l10n.signUpAction),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
