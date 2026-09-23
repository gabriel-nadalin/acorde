import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../services/pocketbase_service.dart';

/// Public account creation against the PocketBase `users` collection.
///
/// Registration is open because the collection's `createRule` is "" (see
/// pb_hooks/events.guard.pb.js for why writes then need the ownership check).
/// PocketBase also signs the new user in, so a successful signup drops
/// straight into the venue list instead of bouncing back to sign-in.
class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _submitting = false;

  /// PocketBase's default minimum for its `password` field.
  static const int _minPasswordLength = 8;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    final auth = context.read<AuthController>();
    String? error;
    try {
      await auth.register(
        email: _email.text.trim(),
        password: _password.text,
        passwordConfirm: _confirmPassword.text,
        name: _name.text.trim(),
      );
    } catch (e) {
      // PocketBase explains rejections itself (e.g. an already-used email), so
      // show its wording rather than a generic failure.
      error = e is PocketBaseException ? e.message : null;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.errorWithMessage(error))),
      );
      return;
    }
    if (auth.user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.signUpFailed)),
      );
      return;
    }
    // A brand-new account manages no venues and belongs to no performers, so
    // send it to venue browsing — that is the one list every account can use.
    context.go('/venues');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.signUpTitle)),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.nameLabel),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.email),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? l10n.emailRequired : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.password),
                      validator: (v) => (v == null || v.length < _minPasswordLength)
                          ? l10n.passwordMinLength
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirmPassword,
                      obscureText: true,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(labelText: l10n.confirmPassword),
                      validator: (v) =>
                          v != _password.text ? l10n.passwordsDoNotMatch : null,
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
                          : Text(l10n.signUpAction),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _submitting ? null : () => context.go('/'),
                      child: Text(l10n.haveAccountSignIn),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
