import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../utils/error_text.dart';

/// Public account creation against the PocketBase `users` collection.
///
/// Registration is open because the collection's `createRule` is "" (see
/// pb_hooks/events.guard.pb.js for why writes then need the ownership check).
/// PocketBase also signs the new user in, so a successful signup drops straight
/// into the app.
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
  bool _obscure = true;

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
    final session = context.read<SessionController>();
    String? error;
    try {
      await session.register(
        email: _email.text.trim(),
        password: _password.text,
        passwordConfirm: _confirmPassword.text,
        name: _name.text.trim(),
      );
    } catch (e) {
      // PocketBase explains rejections itself (e.g. an already-used email), so
      // show its wording rather than a generic failure.
      error = errorText(l10n, e);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    if (session.user == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.signUpFailed)));
      return;
    }
    try {
      // A brand-new account manages no venues and belongs to no performers.
      // Refresh so a pending invitation addressed to this email is claimed and
      // the router can land the user on their calendar instead of the list.
      await context.read<AssignmentsController>().refresh();
    } catch (_) {
      // Best effort: the venue list is always available as a fallback.
    }
    if (!mounted) return;
    final assignments = context.read<AssignmentsController>();
    final has =
        assignments.myPerformers.isNotEmpty || assignments.myVenues.isNotEmpty;
    context.go(has ? '/calendar' : '/venues');
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
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? l10n.emailRequired
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l10n.password,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.length < _minPasswordLength)
                          ? l10n.passwordMinLength
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _confirmPassword,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.confirmPassword,
                      ),
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
