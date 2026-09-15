import 'package:intl/intl.dart';

import '../models/event.dart';

/// Calendar/date helpers shared by the grid, the event screens and the day
/// sheet. Kept in one place so day-overlap and day-key rules cannot drift
/// between the widget that draws them and the screen that filters them.

/// `YYYY-MM-DD` key for a day, used for highlight sets and event-day matching.
String ymdKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Events overlapping the given calendar day (local time).
List<Event> eventsForDay(DateTime day, List<Event> items) {
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  return items.where((e) {
    final start = e.start.toLocal();
    final end = e.end.toLocal();
    return start.isBefore(dayEnd) && end.isAfter(dayStart);
  }).toList();
}

/// Every day key touched by [items]' time ranges (local time), including the
/// end day of a multi-day event.
Set<String> highlightedDayKeys(List<Event> items) {
  final keys = <String>{};
  for (final e in items) {
    final start = e.start.toLocal();
    final end = e.end.toLocal();
    var day = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    while (!day.isAfter(last)) {
      keys.add(ymdKey(day));
      day = day.add(const Duration(days: 1));
    }
  }
  return keys;
}

/// Locale-aware "August 2026".
String monthLabel(String locale, DateTime month) => DateFormat.yMMMM(locale).format(month);

/// Locale-aware abbreviated weekday names, Sunday first (grid column order).
List<String> weekdayAbbreviations(String locale) {
  final format = DateFormat.E(locale);
  // 2026-01-04 is a Sunday.
  final sunday = DateTime(2026, 1, 4);
  return [for (var i = 0; i < 7; i++) format.format(sunday.add(Duration(days: i)))];
}

/// Locale-aware date + time, e.g. for the event form fields.
String formatDateTime(String locale, DateTime dt) => DateFormat.yMd(locale).add_Hm().format(dt);

/// Locale-aware full date, e.g. for the day sheet header.
String formatFullDate(String locale, DateTime d) => DateFormat.yMMMMd(locale).format(d);
