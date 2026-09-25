import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:acorde/l10n/app_localizations.dart';
import 'package:acorde/nav/destinations.dart';
import 'package:acorde/router.dart';

import 'support/screen_harness.dart';

/// How the app is navigated: dashboard as home, destinations side by side.
///
/// The rule under test is that the destinations are *siblings*, not levels. The
/// top bar moves between them laterally (`replace`), so the history never grows
/// and back from any of them lands on the home screen — which is what the top bar
/// promises. Pushing instead would make back mean "the last tab I looked at",
/// and would leave a stack of pages the user never asked to revisit.
///
/// This drives the app's real router (`createRouter`), including its redirect,
/// rather than an approximation of it: the landing route after sign-in and the
/// behaviour of back are both decided there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
  });

  /// The app's own router and provider wiring around a signed-in session.
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

  /// Taps a destination in the top bar.
  Future<void> goTo(WidgetTester tester, Destination destination) async {
    await tester.tap(find.byKey(navKey(destination.location)));
    await tester.pumpAndSettle();
  }

  group('home', () {
    testWidgets('a signed-in session lands on the dashboard', (tester) async {
      final router = await pumpApp(tester);
      expect(pathOf(router), kHomeLocation);
      expect(find.text(Destinations.mine.label(strings)), findsNothing);
    });

    testWidgets('the dashboard offers no back arrow and no link to itself', (
      tester,
    ) async {
      await pumpApp(tester);
      // It is home: every other top-level screen replaces it, so there is
      // nothing behind it. An arrow there would have nowhere honest to go — while
      // signed in the router redirects the sign-in route straight back here, so
      // "back to sign-in" would be a button that visibly does nothing.
      expect(find.byIcon(Icons.arrow_back), findsNothing);
      expect(find.byKey(navKey('/dashboard')), findsNothing);
      // The way out of the signed-in area is sign-out, which the bar offers.
      expect(find.byIcon(Icons.logout), findsOneWidget);
    });
  });

  group('the top bar moves laterally', () {
    testWidgets('every destination is reachable from the dashboard', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      for (final destination in Destinations.all) {
        if (destination.location == kHomeLocation) continue;
        await goTo(tester, destination);
        expect(
          pathOf(router),
          destination.location,
          reason: '${destination.location} is not reachable from the dashboard',
        );
        // Back to home for the next hop.
        router.go(kHomeLocation);
        await tester.pumpAndSettle();
      }
    });

    /// The requested behaviour, asserted through the control a user presses:
    /// every destination's own back button returns to the dashboard.
    testWidgets('the back button on a destination returns to the dashboard', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      for (final destination in Destinations.all) {
        if (destination.location == kHomeLocation) continue;
        await goTo(tester, destination);
        expect(pathOf(router), destination.location);

        await tester.tap(find.byTooltip(strings.backToHome));
        await tester.pumpAndSettle();
        expect(
          pathOf(router),
          kHomeLocation,
          reason: 'back from ${destination.location} did not return home',
        );
      }
    });

    /// The failure this guards: if the bar pushed instead of replacing, four
    /// hops would leave four pages behind and the stack would grow all session.
    testWidgets('several hops leave no history behind', (tester) async {
      final router = await pumpApp(tester);
      await goTo(tester, Destinations.upcoming);
      await goTo(tester, Destinations.calendar);
      await goTo(tester, Destinations.venues);
      await goTo(tester, Destinations.performers);
      expect(pathOf(router), '/performers');

      // A lateral structure has nothing to pop — the destinations replaced one
      // another, so there is exactly one page on the stack.
      expect(router.canPop(), isFalse);

      await tester.tap(find.byTooltip(strings.backToHome));
      await tester.pumpAndSettle();
      expect(pathOf(router), kHomeLocation);
    });

    testWidgets('every destination is reachable from every other one', (
      tester,
    ) async {
      final router = await pumpApp(tester);
      for (final from in Destinations.all) {
        for (final to in Destinations.all) {
          if (from.location == to.location) continue;
          router.go(from.location);
          await tester.pumpAndSettle();
          await goTo(tester, to);
          expect(
            pathOf(router),
            to.location,
            reason: '${to.location} is not reachable from ${from.location}',
          );
        }
      }
    });
  });
}
