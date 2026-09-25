import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:acorde/l10n/app_localizations.dart';
import 'package:acorde/models/event.dart';
import 'package:acorde/utils/calendar_math.dart';
import 'package:acorde/widgets/calendar_grid.dart';

/// The day grid is a single roving tab stop with arrow-key navigation. These
/// tests drive it the way a keyboard user does — move the ring, press Enter,
/// see which day the app acts on — rather than inspecting focus nodes.
///
/// The displayed month is fixed at March 2026: the 1st is a Sunday (so the
/// first cell is day 1), it has 31 days, and it is never "today", which would
/// move the initial roving position.
DateTime get _month => DateTime(2026, 3);

void main() {
  setUpAll(() => initializeDateFormatting('pt'));

  late List<DateTime> activated;
  late List<bool> activatedHasEvent;
  late List<List<Event>> activatedEvents;

  setUp(() {
    activated = [];
    activatedHasEvent = [];
    activatedEvents = [];
  });

  Future<void> pumpGrid(
    WidgetTester tester, {
    List<Event> events = const [],
    Set<String> highlightedDays = const {},
    Set<String> Function(Event event)? eventCats,
    bool Function(bool hasEvent)? dayEnabled,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('pt'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CalendarGrid(
            focusedMonth: _month,
            onMonthChanged: (_) {},
            events: events,
            highlightedDays: highlightedDays,
            eventCats: eventCats ?? (_) => const <String>{},
            dayEnabled: dayEnabled,
            onDayTap: (_, day, dayEvents, hasEvent) {
              activated.add(DateTime(day.year, day.month, day.day));
              activatedEvents.add(dayEvents);
              activatedHasEvent.add(hasEvent);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Puts the keyboard ring on [day] and returns the cell's [Focus] widget.
  ///
  /// This is what a Tab press does: exactly one cell — the roving one — is
  /// tab-reachable, and on a month that is not the current one that cell is the
  /// 1st.
  Finder cellOf(int day) =>
      find.ancestor(of: find.text('$day'), matching: find.byType(Focus)).first;

  Future<void> focusDay(WidgetTester tester, int day) async {
    tester.widget<Focus>(cellOf(day)).focusNode!.requestFocus();
    await tester.pump();
  }

  /// Presses Enter and reports the day the app acted on.
  Future<DateTime> pressEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return activated.last;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets(
    'the 1st of the month is the only tab stop, and Enter activates it',
    (tester) async {
      await pumpGrid(tester);

      final tabStops = <int>[];
      for (var day = 1; day <= 31; day++) {
        final focus = tester.widget<Focus>(cellOf(day));
        if (focus.skipTraversal != true) tabStops.add(day);
      }
      expect(tabStops, [1]);

      await focusDay(tester, 1);
      expect(await pressEnter(tester), DateTime(2026, 3, 1));
      expect(activatedHasEvent.single, isFalse);
    },
  );

  testWidgets('space activates the focused day like Enter does', (
    tester,
  ) async {
    await pumpGrid(tester);
    await focusDay(tester, 1);

    await press(tester, LogicalKeyboardKey.space);

    expect(activated.single, DateTime(2026, 3, 1));
  });

  testWidgets('arrow keys move the ring by a day and by a week', (
    tester,
  ) async {
    await pumpGrid(tester);
    await focusDay(tester, 1);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(await pressEnter(tester), DateTime(2026, 3, 2));

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(await pressEnter(tester), DateTime(2026, 3, 1));

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(await pressEnter(tester), DateTime(2026, 3, 8));

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(await pressEnter(tester), DateTime(2026, 3, 1));

    // A week forward and back from the 2nd crosses no month edge.
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(await pressEnter(tester), DateTime(2026, 3, 9));
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(await pressEnter(tester), DateTime(2026, 3, 2));
  });

  testWidgets('Home and End jump to the first and last day of the month', (
    tester,
  ) async {
    await pumpGrid(tester);
    await focusDay(tester, 1);

    await press(tester, LogicalKeyboardKey.end);
    expect(await pressEnter(tester), DateTime(2026, 3, 31));

    await press(tester, LogicalKeyboardKey.home);
    expect(await pressEnter(tester), DateTime(2026, 3, 1));

    // From the middle of the month too.
    await focusDay(tester, 15);
    await press(tester, LogicalKeyboardKey.home);
    expect(await pressEnter(tester), DateTime(2026, 3, 1));
  });

  testWidgets(
    'arrow keys clamp at the month edges instead of wrapping or leaving the month',
    (tester) async {
      await pumpGrid(tester);
      await focusDay(tester, 1);

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(await pressEnter(tester), DateTime(2026, 3, 1));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(await pressEnter(tester), DateTime(2026, 3, 1));

      await press(tester, LogicalKeyboardKey.end);
      expect(await pressEnter(tester), DateTime(2026, 3, 31));

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(await pressEnter(tester), DateTime(2026, 3, 31));

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(await pressEnter(tester), DateTime(2026, 3, 31));
    },
  );

  testWidgets('Enter hands the focused day and its events to the callback', (
    tester,
  ) async {
    final gig = Event(
      title: 'Gig',
      start: DateTime(2026, 3, 8, 19),
      end: DateTime(2026, 3, 8, 21),
    );
    await pumpGrid(
      tester,
      events: [gig],
      highlightedDays: {ymdKey(DateTime(2026, 3, 8))},
      eventCats: (_) => const {'venue'},
    );
    await focusDay(tester, 1);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(await pressEnter(tester), DateTime(2026, 3, 8));
    expect(activatedEvents.single, [gig]);
    expect(activatedHasEvent.single, isTrue);
  });

  testWidgets('an inert day does not activate, from the keyboard either', (
    tester,
  ) async {
    final gig = Event(
      title: 'Gig',
      start: DateTime(2026, 3, 8, 19),
      end: DateTime(2026, 3, 8, 21),
    );
    await pumpGrid(
      tester,
      events: [gig],
      highlightedDays: {ymdKey(DateTime(2026, 3, 8))},
      dayEnabled: (hasEvent) => hasEvent,
    );
    await focusDay(tester, 1);

    await press(tester, LogicalKeyboardKey.enter);
    await tester.tap(cellOf(1));
    await tester.pump();
    expect(activated, isEmpty);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(await pressEnter(tester), DateTime(2026, 3, 8));
  });

  testWidgets('a day label names its booking category', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('pt'));
    DateTime day(int d) => DateTime(2026, 3, d);

    await pumpGrid(
      tester,
      events: [
        Event(
          title: 'a',
          start: DateTime(2026, 3, 8, 10),
          end: DateTime(2026, 3, 8, 12),
        ),
        Event(
          title: 'b',
          start: DateTime(2026, 3, 9, 10),
          end: DateTime(2026, 3, 9, 12),
        ),
        Event(
          title: 'c',
          start: DateTime(2026, 3, 9, 14),
          end: DateTime(2026, 3, 9, 16),
        ),
      ],
      highlightedDays: {ymdKey(day(8)), ymdKey(day(9))},
      eventCats: (event) =>
          event.title == 'a' ? const {'performer'} : const {'venue'},
    );

    expect(
      find.bySemanticsLabel(
        l10n.calendarDayPerformer(formatFullDate('pt', day(8))),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        l10n.calendarDayVenue(formatFullDate('pt', day(9))),
      ),
      findsOneWidget,
    );
    // A day with no highlighted booking stays "free"; the range is explicit.
    expect(
      find.bySemanticsLabel(
        l10n.calendarDayFree(formatFullDate('pt', day(10))),
      ),
      findsOneWidget,
    );

    // Both categories on one day, when the day carries both.
    await pumpGrid(
      tester,
      events: [
        Event(
          title: 'a',
          start: DateTime(2026, 3, 8, 10),
          end: DateTime(2026, 3, 8, 12),
        ),
        Event(
          title: 'b',
          start: DateTime(2026, 3, 8, 14),
          end: DateTime(2026, 3, 8, 16),
        ),
      ],
      highlightedDays: {ymdKey(day(8))},
      eventCats: (event) =>
          event.title == 'a' ? const {'performer'} : const {'venue'},
    );
    expect(
      find.bySemanticsLabel(l10n.calendarDayBoth(formatFullDate('pt', day(8)))),
      findsOneWidget,
    );
  });
}
