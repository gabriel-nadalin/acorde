import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../l10n/app_localizations.dart';
import '../services/pocketbase_service.dart';
import '../utils/error_text.dart';

/// The two halves of "I forgot my password".
///
/// Both are pre-auth screens, so neither touches [SessionController]: asking for
/// a link and spending it happen while signed out, and PocketBase's
/// `confirm-password-reset` returns no session — the user signs in afterwards
/// with the password they just chose.
///
/// # Why the request half asks whether mail works
///
/// `request-password-reset` answers 204 for every input, including on a server
/// with no mailer configured. PocketBase has to answer that way — telling a
/// caller "that address has no account" would make the endpoint an
/// email-enumeration oracle — but the consequence is that the endpoint cannot
/// report a reset that will never arrive. So [ForgotPasswordPage] asks
/// `GET /api/agenda/mail-status` first and, when there is no mailer, says so
/// instead of sending the user to an inbox nothing was ever delivered to. The
/// administrator path (resetting from the PocketBase dashboard) always works, so
/// that message is actionable rather than a dead end.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key, this.prefillEmail});

  /// Whatever the sign-in form already had typed into it, so the common case
  /// (you typed your address, got it wrong, went to reset it) needs no retyping.
  final String? prefillEmail;

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final TextEditingController _email = TextEditingController(
    text: widget.prefillEmail ?? '',
  );
  bool _submitting = false;

  /// `null` until the capability probe answers; the form is not drawn before
  /// then, because what it says depends on the answer.
  bool? _mailAvailable;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _probeMail();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _probeMail() async {
    final available = await PocketBaseService.shared.mailEnabled();
    if (!mounted) return;
    setState(() => _mailAvailable = available);
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context);
    final email = _email.text.trim();
    if (email.isEmpty) {
      _showMessage(l10n.emailRequired);
      return;
    }

    setState(() => _submitting = true);
    String? error;
    try {
      await PocketBaseService.shared.requestPasswordReset(email);
    } catch (e) {
      error = errorText(l10n, e);
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      // Only a failure that reached here is shown; a success is reported by
      // switching the page to its confirmation state, because a snackbar that
      // says "check your email" over a still-filled form invites a second tap.
      if (error == null) _sent = true;
    });
    if (error != null) _showMessage(error);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.resetPasswordTitle)),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _body(context, l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final available = _mailAvailable;
    if (available == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!available) {
      return _Notice(
        icon: Icons.mark_email_unread_outlined,
        text: l10n.resetMailUnavailable,
      );
    }
    if (_sent) {
      return _Notice(icon: Icons.outgoing_mail, text: l10n.resetLinkSent);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.resetPasswordIntro),
        const SizedBox(height: 16),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(labelText: l10n.email),
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
              : Text(l10n.sendResetLink),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _submitting ? null : () => context.go('/'),
          child: Text(l10n.back),
        ),
      ],
    );
  }
}

/// Spends a reset token: the screen the emailed link opens.
///
/// The token arrives as a `token` query parameter, read from the route rather
/// than passed through `extra`, because this page is opened from outside the app
/// — a link in a mail client, or a pasted URL — where there is no `extra` and no
/// navigation stack to return to.
class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, required this.token});

  /// The token from the reset email, or null when the link carried none.
  final String? token;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;

  /// PocketBase's default minimum for its `password` field, as on sign-up.
  static const int _minPasswordLength = 8;

  @override
  void dispose() {
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final l10n = AppLocalizations.of(context);
    final token = widget.token;
    if (token == null || token.isEmpty) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    String? error;
    try {
      await PocketBaseService.shared.confirmPasswordReset(
        token: token,
        password: _password.text,
        passwordConfirm: _confirmPassword.text,
      );
    } catch (e) {
      error = errorText(l10n, e);
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    // Shown before navigating: the snackbar belongs to the app-level messenger,
    // so it survives the route change and is read on the sign-in screen it
    // applies to. Telling the user the password changed while leaving them on a
    // form that can no longer be submitted would be worse than the extra tap.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.passwordChanged)));
    context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final token = widget.token;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.newPasswordTitle)),
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: token == null || token.isEmpty
                  ? _Notice(
                      icon: Icons.link_off,
                      text: l10n.resetLinkIncomplete,
                    )
                  : _form(l10n),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(AppLocalizations l10n) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: l10n.password,
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) => (v == null || v.length < _minPasswordLength)
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
                : Text(l10n.setNewPassword),
          ),
        ],
      ),
    );
  }
}

/// A centered icon-and-explanation block, for the states where there is nothing
/// to fill in: mail unavailable, link sent, link incomplete.
///
/// One widget for the three because they differ only in glyph and sentence, and
/// three near-identical layouts would drift the moment one gained a button.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40),
        const SizedBox(height: 16),
        Text(text, textAlign: TextAlign.center),
      ],
    );
  }
}
