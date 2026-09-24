import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:event_calendar/models/event.dart';
import 'package:event_calendar/utils/calendar_math.dart';

import 'support/local_time_zone.dart';

/// Guards the single implementation of the day-overlap/day-key rules that both
/// the calendar grid and the events screen depend on.
void main() {
  // The app gets this from GlobalMaterialLocalizations (which initializes intl
  // date data for every locale it ships); a bare test has no such delegate.
  //
  // The zone is forced to one with a DST transition: the machine's own zone has
  // had no transition since 2019, where a `Duration(days: 1)` bug is invisible.
  late String? originalZone;

  setUpAll(() {
    initializeDateFormatting('en');
    originalZone = LocalTimeZone.current();
    LocalTimeZone.use('America/New_York');
  });

  tearDownAll(() => LocalTimeZone.restore(originalZone));

  Event event(DateTime start, DateTime end) =>
      Event(title: 'e', start: start, end: end);

  test('eventsForDay matches only the day an event covers', () {
    final e = event(DateTime(2026, 8, 1, 19), DateTime(2026, 8, 1, 21));

    expect(eventsForDay(DateTime(2026, 8, 1), [e]), hasLength(1));
    expect(eventsForDay(DateTime(2026, 7, 31), [e]), isEmpty);
    expect(eventsForDay(DateTime(2026, 8, 2), [e]), isEmpty);
  });

  test(
    'an event ending exactly at midnight does not leak into the next day',
    () {
      final e = event(DateTime(2026, 8, 1, 22), DateTime(2026, 8, 2));

      expect(eventsForDay(DateTime(2026, 8, 1), [e]), hasLength(1));
      expect(eventsForDay(DateTime(2026, 8, 2), [e]), isEmpty);
    },
  );

  test('highlightedDayKeys covers every day of a multi-day event', () {
    final e = event(DateTime(2026, 8, 1, 22), DateTime(2026, 8, 3, 6));

    expect(highlightedDayKeys([e]), {'2026-08-01', '2026-08-02', '2026-08-03'});
  });

  test('ymdKey zero-pads month and day', () {
    expect(ymdKey(DateTime(2026, 1, 5)), '2026-01-05');
  });

  test('month and weekday labels come from the locale', () {
    final august = monthLabel('en', DateTime(2026, 8, 1));
    expect(august, contains('August'));
    expect(august, contains('2026'));

    final weekdays = weekdayAbbreviations('en');
    expect(weekdays, hasLength(7));
    // Grid columns are Sunday-first.
    expect(weekdays.first, startsWith('S'));
    expect(weekdays.last, startsWith('S'));
  });

  group('DST transitions', () {
    // America/New_York springs forward 2026-03-08 (02:00 -> 03:00) and falls
    // back 2026-11-01 (02:00 -> 01:00).
    //
    // These are functions, not values: a `DateTime` built while the group body
    // is declared is built in the *original* zone, and reading its calendar
    // components back after the zone switches returns the wrong day.
    DateTime springForwardDay() => DateTime(2026, 3, 8);
    DateTime fallBackDay() => DateTime(2026, 11, 1);

    test(
      'day boundaries stay at local midnight across a spring-forward day',
      () {
        expect(startOfNextDay(springForwardDay()), DateTime(2026, 3, 9));
        expect(startOfNextDay(springForwardDay()).hour, 0);
        expect(addDays(springForwardDay(), 1), DateTime(2026, 3, 9));
        expect(addDays(springForwardDay(), 1).hour, 0);
        // The local day really is 23 hours long, which is what makes a
        // `Duration(days: 1)` boundary land an hour into the next day.
        expect(
          startOfNextDay(
            springForwardDay(),
          ).difference(startOfDay(springForwardDay())),
          const Duration(hours: 23),
        );
      },
    );

    test('day boundaries stay at local midnight across a fall-back day', () {
      expect(startOfNextDay(fallBackDay()), DateTime(2026, 11, 2));
      expect(
        startOfNextDay(fallBackDay()).difference(startOfDay(fallBackDay())),
        const Duration(hours: 25),
      );
    });

    test(
      'the day containing the transition resolves to exactly one day key',
      () {
        expect(ymdKey(startOfDay(springForwardDay())), '2026-03-08');
        expect(ymdKey(startOfNextDay(springForwardDay())), '2026-03-09');

        final spanning = event(
          DateTime(2026, 3, 8, 1),
          DateTime(2026, 3, 8, 4),
        );
        expect(highlightedDayKeys([spanning]), {'2026-03-08'});
      },
    );

    test(
      'an event just after midnight the following day is not attributed to the transition day',
      () {
        final afterMidnight = event(
          DateTime(2026, 3, 9, 0, 30),
          DateTime(2026, 3, 9, 1, 30),
        );

        expect(eventsForDay(springForwardDay(), [afterMidnight]), isEmpty);
        expect(
          eventsForDay(DateTime(2026, 3, 9), [afterMidnight]),
          hasLength(1),
        );
      },
    );

    test(
      'highlightedDayKeys covers every calendar day of a range spanning the transition',
      () {
        final festival = event(
          DateTime(2026, 3, 6, 22),
          DateTime(2026, 3, 9, 6),
        );

        expect(highlightedDayKeys([festival]), {
          '2026-03-06',
          '2026-03-07',
          '2026-03-08',
          '2026-03-09',
        });
      },
    );

    test('formatTime renders a time of day without the date', () {
      // The upcoming list leads each row with the time, so it needs the clock
      // alone — deriving it by splitting a formatted date would break in any
      // locale that orders or separates the parts differently.
      final at = DateTime(2026, 3, 4, 20, 30);
      expect(formatTime('en', at), '20:30');
      expect(formatTime('pt', at), '20:30');
      expect(formatTime('en', at), isNot(contains('2026')));
    });

    test(
      'highlightedDayKeys covers every calendar day of a range spanning the fall-back day',
      () {
        final festival = event(
          DateTime(2026, 10, 30, 22),
          DateTime(2026, 11, 2, 6),
        );

        expect(highlightedDayKeys([festival]), {
          '2026-10-30',
          '2026-10-31',
          '2026-11-01',
          '2026-11-02',
        });
      },
    );
  });
}
