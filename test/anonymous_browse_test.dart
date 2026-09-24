import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:event_calendar/l10n/app_localizations.dart';
import 'package:event_calendar/models/membership.dart';
import 'package:event_calendar/nav/destinations.dart';
import 'package:event_calendar/router.dart';
import 'package:event_calendar/screens/entity_browse.dart';

import 'support/screen_harness.dart';

/// What a visitor with no account can see, and what they cannot.
///
/// The venue and performer lists are the app's shop window: the person who
/// cannot sign in is exactly the person who needs to find the room they work at
/// so they can ask to join it, and the sign-in screen has always offered a
/// button to each. Both were broken, and in two different ways that had to be
/// fixed together:
///
///   * the router's redirect sent any signed-out visitor back to the sign-in
///     screen, so the routes were unreachable, and
///   * the collections' list rules required a session, so even a route that got
///     through would have rendered a list that 401'd.
///
/// These tests cover the first half — the client's half, which is what runs
/// here. The second half is a migration
/// (`pb_migrations/1790400000_public_entity_lists.js`) and is asserted against a
/// real database by `scripts/verify_schema.dart` and the container smoke tests,
/// not from a widget test with a fake server.
///
/// The assertions are deliberately about *both* directions. "The lists open" is
/// half a contract; the other half is that nothing else does. A fix that made
/// every route public would pass a test that only checked the first.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
    // The visitor has no account. `logout` is synchronous and clears the
    // session in memory, which is what the router's redirect reads.
    h.session.logout();
  });

  /// The app's own router and provider wiring around a signed-out session.
  Future<GoRouter> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
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

  String pathOf(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.path;

  group('the public lists are public', () {
    for (final destination in Destinations.public) {
      testWidgets('${destination.location} opens without a session', (
        tester,
      ) async {
        final router = await pumpApp(tester);
        router.go(destination.location);
        await tester.pumpAndSettle();

        expect(
          pathOf(router),
          destination.location,
          reason: 'a signed-out visitor was not allowed to open it',
        );
        // The registry's own icon, so this is the list and not another screen
        // reached by a stray redirect.
        expect(find.byIcon(destination.icon), findsWidgets);
      });
    }

    testWidgets('both lists are reachable from the sign-in screen', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      expect(pathOf(router), '/');

      // The exact buttons the user reported as dead: tapped through the widget
      // tree, not by driving the router directly, because "the route is public"
      // and "the button navigates" are separate claims and the bug was in the
      // second one.
      //
      // Found by their visible label rather than by tooltip: unlike the top bar's
      // icon-only buttons, these carry text, so the text is their name.
      for (final destination in Destinations.public) {
        router.go('/');
        await tester.pumpAndSettle();
        await tester.tap(find.text(destination.label(strings)));
        await tester.pumpAndSettle();
        expect(
          pathOf(router),
          destination.location,
          reason: '${destination.label(strings)} did not open its list',
        );
      }
    });
  });

  group('everything else still needs a session', () {
    /// The other half of the contract. Listed explicitly rather than derived
    /// from the registry, because this is the invariant that a bug would break
    /// by publishing too much — deriving it from the same flag under test would
    /// make the assertion agree with the bug.
    const protectedLocations = ['/dashboard', '/upcoming', '/calendar'];

    for (final location in protectedLocations) {
      testWidgets('$location sends a visitor to the sign-in screen', (
        tester,
      ) async {
        final router = await pumpApp(tester);
        router.go(location);
        await tester.pumpAndSettle();
        expect(pathOf(router), '/');
      });
    }

    testWidgets('the top bar offers no destination that would bounce', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      router.go(Destinations.venues.location);
      await tester.pumpAndSettle();

      for (final location in protectedLocations) {
        expect(
          find.byKey(navKey(location)),
          findsNothing,
          reason: 'the bar offers $location, which the router refuses',
        );
      }
      // And the sibling public list is still offered.
      expect(
        find.byKey(navKey(Destinations.performers.location)),
        findsOneWidget,
      );
    });

    testWidgets('the bar offers sign-in instead of sign-out', (tester) async {
      final router = await pumpApp(tester);
      router.go(Destinations.venues.location);
      await tester.pumpAndSettle();

      expect(
        find.byKey(navKey('signout')),
        findsNothing,
        reason: 'a visitor with no session is offered a sign-out button',
      );

      // The account action is what actually moves them forward, so it must be
      // there and must work.
      await tester.tap(find.byKey(navKey('signin')));
      await tester.pumpAndSettle();
      expect(pathOf(router), '/');
    });

    testWidgets('the bar offers exactly one way back to the sign-in screen', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      router.go(Destinations.venues.location);
      await tester.pumpAndSettle();

      // The leading back arrow is derived from `goHome`, which the router sends
      // to the sign-in screen for a visitor — the same destination as the
      // account action. Drawing both put two identically-labelled controls on
      // one bar going to one place, so the arrow is withheld and the account
      // action carries it. Same invariant as the destinations: a bar never
      // offers two buttons for one location.
      expect(
        find.byIcon(Icons.arrow_back),
        findsNothing,
        reason: 'the leading back arrow duplicates the account action',
      );
      expect(find.byKey(navKey('signin')), findsOneWidget);
    });
  });

  group('a public list read signed out', () {
    testWidgets('renders the entities and offers no create button', (
      tester,
    ) async {
      await h.pump(
        tester,
        const EntityBrowsePage(targetType: TargetType.venue),
      );

      // The list itself is the point: it has to render, not just be reachable.
      expect(find.text('My Hall'), findsOneWidget);
      expect(find.text('Not Mine'), findsOneWidget);

      // Creating requires a session to own the record, and the page has none to
      // offer — so the button is withheld rather than opening a form that
      // cannot submit.
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('offers no per-row action at all', (tester) async {
      await h.pump(
        tester,
        const EntityBrowsePage(targetType: TargetType.venue),
      );

      // Manage, ask-to-join and the pending marker all describe a relationship
      // between the visitor and the entity. A visitor has none, so the whole
      // action area is absent — including for the venue this account *would*
      // manage if it had one, which is what makes this a test of the session
      // rather than of the seeded membership.
      expect(find.byIcon(Icons.edit), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.how_to_reg_outlined), findsNothing);
      expect(find.byIcon(Icons.hourglass_empty), findsNothing);
    });
  });

  group('the registry', () {
    test('declares exactly the two lists as public', () {
      expect(Destinations.public.map((d) => d.location).toSet(), {
        Destinations.venues.location,
        Destinations.performers.location,
      });
    });
  });
}
