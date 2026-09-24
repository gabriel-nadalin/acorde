import 'package:intl/intl.dart';

import '../models/event.dart';

/// Calendar/date helpers shared by the grid, the event screens and the day
/// sheet. Kept in one place so day-overlap and day-key rules cannot drift
/// between the widget that draws them and the screen that filters them.
///
/// Every day boundary is built from calendar components — `DateTime(y, m, d+1)`
/// — and never by adding `Duration(days: 1)`. Adding a fixed duration to a
/// local midnight lands on 23:00 or 01:00 across a DST transition, which would
/// attribute events near midnight to the wrong day.

/// `YYYY-MM-DD` key for a day, used for highlight sets and event-day matching.
String ymdKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Midnight at the start of [day]'s local calendar day.
DateTime startOfDay(DateTime day) => DateTime(day.year, day.month, day.day);

/// Midnight at the start of the day after [day] (DST-safe).
DateTime startOfNextDay(DateTime day) =>
    DateTime(day.year, day.month, day.day + 1);

/// Midnight at the start of the local calendar day [n] days after [day].
DateTime addDays(DateTime day, int n) =>
    DateTime(day.year, day.month, day.day + n);

/// Events overlapping the given calendar day (local time).
List<Event> eventsForDay(DateTime day, List<Event> items) {
  final dayStart = startOfDay(day);
  final dayEnd = startOfNextDay(day);
  return [
    for (final e in items)
      if (e.start.toLocal().isBefore(dayEnd) &&
          e.end.toLocal().isAfter(dayStart))
        e,
  ];
}

/// Every day key touched by [items]' time ranges (local time), including the
/// end day of a multi-day event.
Set<String> highlightedDayKeys(List<Event> items) {
  final keys = <String>{};
  for (final e in items) {
    final start = e.start.toLocal();
    final end = e.end.toLocal();
    var day = startOfDay(start);
    final last = startOfDay(end);
    // Bounded by the event's own span so a reversed or absurd range cannot loop.
    var guard = 0;
    while (!day.isAfter(last) && guard < 400) {
      keys.add(ymdKey(day));
      day = addDays(day, 1);
      guard++;
    }
  }
  return keys;
}

/// Locale-aware "August 2026".
String monthLabel(String locale, DateTime month) =>
    DateFormat.yMMMM(locale).format(month);

/// Locale-aware abbreviated weekday names, Sunday first (grid column order).
List<String> weekdayAbbreviations(String locale) {
  final format = DateFormat.E(locale);
  // 2026-01-04 is a Sunday.
  final sunday = DateTime(2026, 1, 4);
  return [for (var i = 0; i < 7; i++) format.format(addDays(sunday, i))];
}

/// Locale-aware date + time, e.g. for the event form fields.
String formatDateTime(String locale, DateTime dt) =>
    DateFormat.yMd(locale).add_Hm().format(dt);

/// Locale-aware time of day, e.g. for the upcoming list's leading column.
String formatTime(String locale, DateTime dt) =>
    DateFormat.Hm(locale).format(dt);

/// Locale-aware date only.
String formatDate(String locale, DateTime dt) =>
    DateFormat.yMd(locale).format(dt);

/// Locale-aware full date, e.g. for the day sheet header.
String formatFullDate(String locale, DateTime d) =>
    DateFormat.yMMMMd(locale).format(d);
