import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:flutter_application_1/models/event.dart';
import 'package:flutter_application_1/utils/calendar_math.dart';

/// Guards the single implementation of the day-overlap/day-key rules that both
/// the calendar grid and the events screen depend on.
void main() {
  // The app gets this from GlobalMaterialLocalizations (which initializes intl
  // date data for every locale it ships); a bare test has no such delegate.
  setUpAll(() => initializeDateFormatting('en'));

  Event event(DateTime start, DateTime end) => Event(title: 'e', start: start, end: end);

  test('eventsForDay matches only the day an event covers', () {
    final e = event(DateTime(2026, 8, 1, 19), DateTime(2026, 8, 1, 21));

    expect(eventsForDay(DateTime(2026, 8, 1), [e]), hasLength(1));
    expect(eventsForDay(DateTime(2026, 7, 31), [e]), isEmpty);
    expect(eventsForDay(DateTime(2026, 8, 2), [e]), isEmpty);
  });

  test('an event ending exactly at midnight does not leak into the next day', () {
    final e = event(DateTime(2026, 8, 1, 22), DateTime(2026, 8, 2));

    expect(eventsForDay(DateTime(2026, 8, 1), [e]), hasLength(1));
    expect(eventsForDay(DateTime(2026, 8, 2), [e]), isEmpty);
  });

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
}
