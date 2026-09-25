import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:acorde/l10n/app_localizations.dart';
import 'package:acorde/router.dart';

import 'support/fake_pocketbase.dart';
import 'support/screen_harness.dart';

/// Guest sign-in: a button that appears only when the server says it works.
///
/// Two claims, and the second is the one worth having. The first is that tapping
/// the button gets you into the app without typing anything — the whole point of
/// the feature. The second is that the button is *gated on a server capability*:
/// the app has already shipped a screen advertising something the backend did
/// not implement (the public lists — see `anonymous_browse_test.dart`), and the
/// rule that came out of it is that a control offered to the user must correspond
/// to something the server will actually honour. So the interesting cases are
/// the negatives: switch off, and probe failed.
///
/// The guest credentials are generated client-side and the account is created
/// through the ordinary public signup endpoint (see `pb_hooks/guest.pb.js`), so
/// what the wire test asserts is exactly that: an ordinary
/// `POST /api/collections/users/records` carrying a generated address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    // The sign-in screen is only reachable signed out, and its guest probe only
    // runs there.
    h.session.logout();
  });

  /// The real router and provider wiring, opened on the sign-in screen.
  Future<GoRouter> pumpSignIn(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = createRouter(session: h.session, assignments: h.assignments);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.session),
          ChangeNotifierProvider.value(value: h.assignments),
          ChangeNotifierProvider.value(value: h.performers),
          ChangeNotifierProvider.value(value: h.venues),
          ChangeNotifierProvider.value(value: h.memberships),
          ChangeNotifierProvider.value(value: h.events),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('pt'),
          localizationsDelegates: const [
            ...AppLocalizations.localizationsDelegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// The `users` record creation the guest path sent, if it sent one.
  Map<String, dynamic>? createdUser(ScreenHarness h) {
    for (final request in h.pb.requestsTo('users')) {
      if (request.method == 'POST' && request.url.path.endsWith('/records')) {
        return jsonDecode(request.body) as Map<String, dynamic>;
      }
    }
    return null;
  }

  group('with the server switch off', () {
    testWidgets('offers no guest button at all', (tester) async {
      h.pb.guestEnabled = false;
      await pumpSignIn(tester);

      expect(find.text(strings.guestSignIn), findsNothing);
      expect(find.text(strings.guestSignInHint), findsNothing);
      // The ordinary ways in are untouched by the switch.
      expect(find.text(strings.signIn), findsWidgets);
      expect(find.text(strings.signUpAction), findsOneWidget);
    });
  });

  group('with the server switch on', () {
    setUp(() => h.pb.guestEnabled = true);

    testWidgets('offers the guest button and its explanation', (tester) async {
      await pumpSignIn(tester);
      expect(find.text(strings.guestSignIn), findsOneWidget);
      expect(find.text(strings.guestSignInHint), findsOneWidget);
    });

    testWidgets('enters the app without anything typed into the form', (
      tester,
    ) async {
      final router = await pumpSignIn(tester);

      // The form is deliberately left empty: the button must not depend on it.
      await tester.tap(find.text(strings.guestSignIn));
      await tester.pumpAndSettle();

      expect(h.session.isLoggedIn, isTrue);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        kHomeLocation,
        reason: 'the guest did not land on the app\'s home',
      );
    });

    testWidgets('creates an ordinary account with generated credentials', (
      tester,
    ) async {
      await pumpSignIn(tester);
      await tester.tap(find.text(strings.guestSignIn));
      await tester.pumpAndSettle();

      final body = createdUser(h);
      expect(
        body,
        isNotNull,
        reason:
            'guest sign-in did not create an account through the public '
            'signup endpoint',
      );

      // The reserved `.invalid` TLD can never resolve and can never be owned, so
      // a guest address cannot collide with, or intercept mail meant for, a real
      // one.
      expect(body!['email'], matches(RegExp(r'^guest-\w+@guest\.invalid$')));
      expect(body['password'], isNotEmpty);
      expect(body['password'], body['passwordConfirm']);
      // Named for the dashboard heading, which would otherwise read
      // "Painel — guest-1758..." to the person being shown the app.
      expect(body['name'], strings.guestAccountName);
    });

    testWidgets('two guests never collide on an address', (tester) async {
      await pumpSignIn(tester);
      await tester.tap(find.text(strings.guestSignIn));
      await tester.pumpAndSettle();
      final first = createdUser(h)?['email'];

      // A second visitor on the same server: the address has to differ, or the
      // account creation is refused as a duplicate and guest sign-in works
      // exactly once.
      h.session.logout();
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.guestSignIn));
      await tester.pumpAndSettle();

      final emails = [
        for (final request in h.pb.requestsTo('users'))
          if (request.method == 'POST' && request.url.path.endsWith('/records'))
            (jsonDecode(request.body) as Map<String, dynamic>)['email'],
      ];
      expect(emails.length, 2);
      expect(emails.first, isNot(emails.last));
      expect(first, isNotNull);
    });

    testWidgets('a rate-limited guest sees the server wording, not a crash', (
      tester,
    ) async {
      // PocketBase answers a throttled signup with 429 and its own explanation.
      // The user did not choose these credentials, so the message has to say
      // what happened rather than blame a field they never filled in.
      final previous = h.pb.intercept;
      h.pb.intercept = (request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/records')) {
          return FakePb.json(429, {
            'status': 429,
            'message': 'Too many requests.',
          });
        }
        return previous?.call(request);
      };

      final router = await pumpSignIn(tester);
      await tester.tap(find.text(strings.guestSignIn));
      await tester.pumpAndSettle();

      expect(h.session.isLoggedIn, isFalse);
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        '/',
        reason: 'a refused guest sign-in must not leave the sign-in screen',
      );
      expect(find.textContaining('Too many requests.'), findsOneWidget);
    });
  });

  group('when the capability probe fails', () {
    testWidgets('the button is withheld rather than offered and broken', (
      tester,
    ) async {
      h.pb.guestEnabled = true;
      // The switch is on, but this client cannot find out. The safe direction is
      // to withhold: the ordinary form below still works, whereas a button
      // offered on a failed probe is a dead end in the user's face.
      final previous = h.pb.intercept;
      h.pb.intercept = (request) async {
        if (request.url.path == '/api/agenda/guest-status') {
          return http.Response('backend down', 500);
        }
        return previous?.call(request);
      };

      await pumpSignIn(tester);
      // The probe is an idempotent GET, so it retries a 5xx (same policy as
      // `mail-status`); the backoff is a bare timer that schedules no frame, and
      // `pumpAndSettle` returns without advancing past it. Drive the clock so the
      // probe actually finishes — otherwise this asserts on a screen whose button
      // is absent only because the answer has not arrived.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(find.text(strings.guestSignIn), findsNothing);
      // And the rest of the screen is unaffected.
      expect(find.text(strings.signUpAction), findsOneWidget);
    });
  });
}
