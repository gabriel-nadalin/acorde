import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'package:acorde/screens/password_reset.dart';
import 'package:acorde/screens/user_select.dart';

import 'support/fake_pocketbase.dart';

import 'support/screen_harness.dart';

/// Recovering an account, from the link on the sign-in screen to the new
/// password being usable.
///
/// The behaviour worth pinning here is not the form — it is what the app says
/// when it *cannot* deliver a reset. `request-password-reset` answers 204 for
/// every input including a server with no mailer, because answering differently
/// would make it an email-enumeration oracle. So "the request was accepted" and
/// "an email is on its way" are different claims, and only the first is true by
/// default: without SMTP the flow is a dead end that looks exactly like success.
/// These tests hold the line between the two.
///
/// The endpoints are exercised through the real client over `MockClient`, so the
/// URLs, bodies and error classification are the shipping ones.
void main() {
  late ScreenHarness h;

  /// Answers `/api/agenda/mail-status` with [enabled].
  ///
  /// Returning null from `intercept` falls through to the fake's default
  /// handler, so this only claims that one path.
  void serveMailStatus({required bool enabled}) {
    final previous = h.pb.intercept;
    h.pb.intercept = (request) async {
      if (request.url.path == '/api/agenda/mail-status') {
        return FakePb.json(200, {'enabled': enabled});
      }
      return previous?.call(request);
    };
  }

  /// Records the password-reset round-trips a screen made.
  ///
  /// The request body *is* the contract — which address, which token — so the
  /// assertions read the wire rather than reaching into the client that built it.
  List<http.Request> resetRequests(String lastSegment) => [
    for (final request in h.pb.requests)
      if (request.url.path.endsWith(lastSegment)) request,
  ];

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
  });

  group('asking for a reset link', () {
    testWidgets('says recovery is unavailable instead of promising an email', (
      tester,
    ) async {
      serveMailStatus(enabled: false);
      await h.pump(tester, const ForgotPasswordPage());

      expect(find.text(strings.resetMailUnavailable), findsOneWidget);
      // The promise that must not be made: no form, so no "check your inbox"
      // confirmation is reachable.
      expect(find.byType(TextField), findsNothing);
      expect(find.text(strings.sendResetLink), findsNothing);
      expect(find.text(strings.resetLinkSent), findsNothing);
      expect(resetRequests('request-password-reset'), isEmpty);
    });

    testWidgets('sends a link request and confirms it was accepted', (
      tester,
    ) async {
      serveMailStatus(enabled: true);
      await h.pump(tester, const ForgotPasswordPage());
      expect(find.text(strings.resetPasswordIntro), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'me@example.com');
      await tester.tap(find.text(strings.sendResetLink));
      await tester.pumpAndSettle();

      final sent = resetRequests('request-password-reset');
      expect(sent, hasLength(1));
      expect(jsonDecode(sent.single.body)['email'], 'me@example.com');
      // Worded as a conditional, because that is all the server's 204 supports.
      expect(find.text(strings.resetLinkSent), findsOneWidget);
    });

    testWidgets('carries an already-typed address into the field', (
      tester,
    ) async {
      serveMailStatus(enabled: true);
      await h.pump(
        tester,
        const ForgotPasswordPage(prefillEmail: 'typed@example.com'),
      );
      expect(find.text('typed@example.com'), findsOneWidget);
    });

    testWidgets('a server failure claims nothing', (tester) async {
      serveMailStatus(enabled: true);
      final previous = h.pb.intercept;
      h.pb.intercept = (request) async {
        if (request.url.path.endsWith('request-password-reset')) {
          return FakePb.json(500, {'message': 'boom'});
        }
        return previous?.call(request);
      };

      await h.pump(tester, const ForgotPasswordPage());
      await tester.enterText(find.byType(TextField), 'me@example.com');
      await tester.tap(find.text(strings.sendResetLink));
      await tester.pumpAndSettle();

      // Neither the confirmation nor a silent success: the form stays put so the
      // attempt can be repeated.
      expect(find.text(strings.resetLinkSent), findsNothing);
      expect(find.text(strings.sendResetLink), findsOneWidget);
    });
  });

  group('spending a reset token', () {
    testWidgets('a link with no token explains itself', (tester) async {
      await h.pump(tester, const ResetPasswordPage(token: null));

      expect(find.text(strings.resetLinkIncomplete), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('sets the password and returns to sign-in', (tester) async {
      await h.pump(tester, const ResetPasswordPage(token: 'tok-abc'));

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'brandnewpass1');
      await tester.enterText(fields.at(1), 'brandnewpass1');
      await tester.tap(find.text(strings.setNewPassword));
      await tester.pumpAndSettle();

      final sent = resetRequests('confirm-password-reset');
      expect(sent, hasLength(1));
      final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
      expect(body['token'], 'tok-abc');
      expect(body['password'], 'brandnewpass1');
      expect(body['passwordConfirm'], 'brandnewpass1');

      // Back at the sign-in screen, where the new password is what is needed.
      expect(find.text(kHomeMarker), findsOneWidget);
    });

    testWidgets('mismatched passwords never reach the server', (tester) async {
      await h.pump(tester, const ResetPasswordPage(token: 'tok-abc'));

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'brandnewpass1');
      await tester.enterText(fields.at(1), 'something-else');
      await tester.tap(find.text(strings.setNewPassword));
      await tester.pumpAndSettle();

      expect(find.text(strings.passwordsDoNotMatch), findsOneWidget);
      expect(resetRequests('confirm-password-reset'), isEmpty);
    });

    testWidgets('a refused token shows the server wording and stays put', (
      tester,
    ) async {
      final previous = h.pb.intercept;
      h.pb.intercept = (request) async {
        if (request.url.path.endsWith('confirm-password-reset')) {
          return FakePb.json(400, {
            'data': {
              'token': {
                'code': 'validation_invalid_token',
                'message': 'Invalid or expired token.',
              },
            },
            'message': 'An error occurred while validating the submitted data.',
            'status': 400,
          });
        }
        return previous?.call(request);
      };

      await h.pump(tester, const ResetPasswordPage(token: 'stale'));
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'brandnewpass1');
      await tester.enterText(fields.at(1), 'brandnewpass1');
      await tester.tap(find.text(strings.setNewPassword));
      await tester.pumpAndSettle();

      // The server's own explanation, not a client-side guess at what a 400 meant.
      expect(find.textContaining('Invalid or expired token'), findsOneWidget);
      // Still on the form: the token may be retried with a corrected password, and
      // navigating away would discard the attempt for no reason.
      expect(find.text(strings.setNewPassword), findsOneWidget);
    });

    testWidgets('a short password is refused before the round-trip', (
      tester,
    ) async {
      await h.pump(tester, const ResetPasswordPage(token: 'tok-abc'));

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'short');
      await tester.enterText(fields.at(1), 'short');
      await tester.tap(find.text(strings.setNewPassword));
      await tester.pumpAndSettle();

      expect(find.text(strings.passwordMinLength), findsOneWidget);
      expect(resetRequests('confirm-password-reset'), isEmpty);
    });
  });

  testWidgets(
    'the sign-in screen carries the typed address to the reset form',
    (tester) async {
      const marker = 'FORGOT ROUTE SEEN';
      late String seenQuery;
      await h.pump(
        tester,
        const UserSelectPage(),
        routes: [
          GoRoute(
            path: '/forgot-password',
            builder: (context, state) {
              seenQuery = state.uri.queryParameters['email'] ?? '';
              return const Scaffold(body: Center(child: Text(marker)));
            },
          ),
        ],
      );

      expect(find.text(strings.forgotPassword), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(0), 'mine@example.com');
      await tester.tap(find.text(strings.forgotPassword));
      await tester.pumpAndSettle();

      expect(find.text(marker), findsOneWidget);
      expect(seenQuery, 'mine@example.com');
    },
  );
}
