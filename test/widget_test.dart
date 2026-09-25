import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:acorde/data/repositories.dart';
import 'package:acorde/data/session_store.dart';
import 'package:acorde/main.dart';
import 'package:acorde/router.dart';
import 'package:acorde/services/pocketbase_service.dart';

import 'support/fake_pocketbase.dart';
import 'support/screen_harness.dart' show strings;

/// The app shell: what the user sees on launch, and where an unauthenticated
/// deep link ends up.
///
/// [MyApp] is built with the real controllers backed by an in-memory PocketBase
/// and no realtime subscription, so the router, the auth redirect and the
/// provider wiring are the ones the app actually ships.
void main() {
  late FakePb pb;
  late PocketBaseService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pb = FakePb();
    service = PocketBaseService(baseUrl: 'http://pb.test', client: pb.client());
  });

  MyApp buildApp() {
    final session = SessionController(
      // See ScreenHarness: the keystore never answers inside a widget test.
      store: MemorySessionStore(),
      service: service,
      prefs: SharedPreferences.getInstance(),
    );
    final performers = PerformerRepository(service: service);
    final venues = VenueRepository(service: service);
    final memberships = MembershipRepository(service: service);
    final assignments = AssignmentsController(
      session: session,
      performers: performers,
      venues: venues,
      memberships: memberships,
    );
    final events = EventRepository(
      service: service,
      prefs: SharedPreferences.getInstance(),
    );

    return MyApp(
      session: session,
      assignments: assignments,
      performers: performers,
      venues: venues,
      memberships: memberships,
      events: events,
      // No socket: widget tests must not open a realtime connection.
    );
  }

  testWidgets('the app opens on the sign-in screen', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, strings.signIn), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.widgetWithText(AppBar, strings.signIn), findsOneWidget);
  });

  testWidgets('a signed-out deep link to /dashboard lands on sign-in', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final router = GoRouter.of(context);
    router.go('/dashboard');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, strings.signIn), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    // Nothing behind the redirect was built with a signed-out session.
    expect(pb.log.where((entry) => entry.contains('venues')), isEmpty);
  });

  testWidgets('the public sign-up route stays reachable while signed out', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final router = GoRouter.of(context);
    router.go('/signup');
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/signup');
    expect(find.widgetWithText(FilledButton, strings.signIn), findsNothing);
  });

  /// The reset link arrives from a mail client, so the visitor following it is
  /// normally signed out. Both recovery routes must therefore survive the
  /// signed-out redirect — they were originally listed after it, which bounced
  /// the one visit that matters straight back to a sign-in screen the user
  /// cannot get past.
  testWidgets('a signed-out visitor can open a reset link', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final router = GoRouter.of(context);
    router.go('/reset-password?token=from-the-email');
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/reset-password',
    );
    // The form, not a bounce to sign-in.
    expect(
      find.widgetWithText(FilledButton, strings.setNewPassword),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, strings.signIn), findsNothing);
  });

  testWidgets('the forgot-password route stays reachable while signed out', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    final router = GoRouter.of(context);
    router.go('/forgot-password');
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/forgot-password',
    );
  });

  testWidgets('signing in from the form leaves the sign-in screen', (
    tester,
  ) async {
    pb.authRecord = {'id': 'u1', 'email': 'me@example.com'};
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'me@example.com');
    await tester.enterText(find.byType(TextField).last, 'secret123');
    await tester.tap(find.widgetWithText(FilledButton, strings.signIn));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(Scaffold).first);
    // Home is the dashboard whatever the account has: it is the one screen that
    // reads correctly with no assignments at all.
    expect(
      GoRouter.of(context).routerDelegate.currentConfiguration.uri.path,
      kHomeLocation,
    );
  });
}
