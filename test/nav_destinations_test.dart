import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:event_calendar/l10n/app_localizations.dart';
import 'package:event_calendar/models/membership.dart';
import 'package:event_calendar/nav/destinations.dart';
import 'package:event_calendar/screens/entity_browse.dart';
import 'package:event_calendar/screens/user_calendar_tabs.dart';
import 'package:event_calendar/screens/user_dashboard.dart';

import 'support/screen_harness.dart';

/// The top bar on every screen that has one.
///
/// Each destination is described once ([Destinations]) and every screen renders
/// that description, so the same feature cannot wear two different icons. Before
/// the registry existed the performer list was `person_search` on the calendar
/// and the dashboard but `person_outline` on the sign-in page and the list
/// itself — visible only by opening every screen in turn. These tests are that
/// check, automated: they assert the icon on screen *is* the registry's icon,
/// which is the invariant that makes cross-screen agreement follow.
///
/// The second thing they pin is that every action carries a name. These buttons
/// have no visible label, so the tooltip is the only name they have — for a
/// screen reader, and for `find.byTooltip`. Two of the buttons that prompted
/// this had none, which is why a missing tooltip is a failure here rather than a
/// cosmetic note.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    // The tab controller on the calendar is built from the assignments, so an
    // unwarmed harness would leave that screen on its spinner.
    await h.warm();
  });

  /// The nav button that leads to [location], or null when this screen does not
  /// offer it.
  ///
  /// Keyed rather than searched by icon or ancestor: screens nest other screens
  /// with their own top bars (the calendar's tabs), so "which bar is mine" has
  /// no reliable answer — while the key is exactly the button [navActions] built
  /// for that destination.
  IconButton? navButton(WidgetTester tester, String location) {
    final found = find.byKey(navKey(location));
    if (found.evaluate().isEmpty) return null;
    return tester.widget<IconButton>(found);
  }

  /// Asserts the whole contract for the screen showing [current].
  Future<void> expectTopBar(
    WidgetTester tester,
    Widget screen, {
    required Destination current,
    required bool signOut,
  }) async {
    await h.pump(tester, screen);
    final l10n = strings;

    for (final destination in Destinations.all) {
      final button = navButton(tester, destination.location);
      if (destination.location == current.location) {
        expect(
          button,
          isNull,
          reason:
              'the bar offers a button to the screen the user is already on',
        );
        continue;
      }
      expect(
        button,
        isNotNull,
        reason: '${destination.label(l10n)} is not offered here',
      );
      // The naming rule, enforced where the buttons are: an icon-only button
      // carries its name in the tooltip or nowhere.
      expect(
        button!.tooltip,
        destination.label(l10n),
        reason:
            'the button for ${destination.location} is labelled differently than the registry',
      );
      final iconFinder = find.descendant(
        of: find.byKey(navKey(destination.location)),
        matching: find.byType(Icon),
      );
      final icon = tester.widget<Icon>(iconFinder.first);
      expect(
        icon.icon,
        destination.icon,
        reason:
            'the button for ${destination.location} does not wear the destination\'s own icon',
      );
      // Laid out, not merely present: an Icon with no glyph, or one collapsed to
      // zero size, is a button that reserves space and paints nothing — which
      // reads to the user as a gap in the bar rather than as a missing icon.
      final size = tester.getSize(iconFinder.first);
      expect(
        size.width,
        greaterThan(0),
        reason:
            'the icon for ${destination.location} was laid out at zero width',
      );
      expect(
        size.height,
        greaterThan(0),
        reason:
            'the icon for ${destination.location} was laid out at zero height',
      );
      expect(
        size.width,
        size.height,
        reason: 'the icon for ${destination.location} is not square',
      );
    }

    final logout = navButton(tester, 'signout');
    if (signOut) {
      expect(logout, isNotNull, reason: 'this screen should offer sign-out');
      expect(logout!.tooltip, l10n.signOut);
      expect(
        tester
            .widget<Icon>(
              find
                  .descendant(
                    of: find.byKey(navKey('signout')),
                    matching: find.byType(Icon),
                  )
                  .first,
            )
            .icon,
        Icons.logout,
      );
    } else {
      expect(logout, isNull, reason: 'this screen deliberately omits sign-out');
    }
  }

  group('the top bar', () {
    testWidgets('on the calendar offers the lists and the dashboard', (
      tester,
    ) async {
      await expectTopBar(
        tester,
        const UserCalendarTabs(),
        current: Destinations.calendar,
        signOut: true,
      );
    });

    /// The bug this guards: the calendar used to draw its own bar *and* let each
    /// tab draw one, so it stacked two — "Calendário" with the destinations, and
    /// "Meu calendário" beneath it holding the back arrow. That put the back
    /// button in the middle of the screen instead of the leading position every
    /// other screen uses, and left the calendar as the only screen without
    /// sign-out (the second bar's actions overrode the first's).
    testWidgets('on the calendar draws exactly one top bar', (tester) async {
      await h.pump(tester, const UserCalendarTabs());
      expect(find.byType(AppBar), findsOneWidget);

      // One back arrow, and it is the leading control of that bar.
      expect(find.byTooltip(strings.backToHome), findsOneWidget);
      final backButton = find.ancestor(
        of: find.byTooltip(strings.backToHome),
        matching: find.byType(AppBar),
      );
      expect(
        backButton,
        findsOneWidget,
        reason: 'the back arrow is not in the top bar',
      );

      // Switching tabs must not change the shape of the bar.
      await tester.tap(find.text('My Hall'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byTooltip(strings.backToHome), findsOneWidget);
    });

    testWidgets(
      'on the dashboard offers the calendar, the lists, and sign-out',
      (tester) async {
        await expectTopBar(
          tester,
          const UserDashboardPage(),
          current: Destinations.mine,
          signOut: true,
        );
      },
    );

    // The venue list used to offer only its sibling and sign-out, which left the
    // calendar reachable from it only by popping back to the dashboard.
    testWidgets(
      'on the venue list offers the performer list and a way back out',
      (tester) async {
        await expectTopBar(
          tester,
          const EntityBrowsePage(targetType: TargetType.venue),
          current: Destinations.venues,
          signOut: true,
        );
      },
    );

    testWidgets(
      'on the performer list offers the venue list and a way back out',
      (tester) async {
        await expectTopBar(
          tester,
          const EntityBrowsePage(targetType: TargetType.performer),
          current: Destinations.performers,
          signOut: true,
        );
      },
    );
  });

  group('the registry', () {
    test('describes each destination once', () {
      final locations = [
        for (final destination in Destinations.all) destination.location,
      ];
      expect(
        locations.toSet().length,
        locations.length,
        reason:
            'two destinations share a location, so navActions would drop one',
      );
    });

    test('names every destination in every shipped locale', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final destination in Destinations.all) {
          expect(
            destination.label(l10n).trim(),
            isNotEmpty,
            reason: '${destination.location} has no name in $locale',
          );
        }
      }
    });

    /// The rule that keeps "browse performers" and "a performer" from diverging:
    /// a kind of entity has one icon, and the list that browses the kind wears
    /// it. A new kind of entity is one line here, not a sweep through the UI.
    test(
      'gives each kind of entity one icon, worn by its browse destination',
      () {
        expect(
          entityIcon(TargetType.venue),
          isNot(entityIcon(TargetType.performer)),
        );
        expect(Destinations.venues.icon, entityIcon(TargetType.venue));
        expect(Destinations.performers.icon, entityIcon(TargetType.performer));
      },
    );
  });
}
