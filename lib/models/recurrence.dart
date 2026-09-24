/// Recurrence rule for a repeating event, expanded client-side into concrete
/// event records that each go through the server's double-booking guard.
///
/// Deliberately a small subset of RRULE: frequency, interval and an end
/// condition. That covers "every week for 12 weeks" and "every other day until
/// June" without a rule parser.
library;

enum RecurrenceFreq { daily, weekly, monthly }

String recurrenceFreqWire(RecurrenceFreq freq) => switch (freq) {
  RecurrenceFreq.daily => 'daily',
  RecurrenceFreq.weekly => 'weekly',
  RecurrenceFreq.monthly => 'monthly',
};

RecurrenceFreq parseRecurrenceFreq(String? value) => switch (value) {
  'daily' => RecurrenceFreq.daily,
  'monthly' => RecurrenceFreq.monthly,
  _ => RecurrenceFreq.weekly,
};

class Recurrence {
  const Recurrence({
    this.freq = RecurrenceFreq.weekly,
    this.interval = 1,
    this.count,
    this.until,
  });

  /// Hard ceiling on generated instances, independent of the caller's cap.
  static const int hardMax = 200;

  final RecurrenceFreq freq;

  /// Step size in [freq] units; always >= 1.
  final int interval;

  /// Total number of occurrences including the first, or null when unbounded.
  final int? count;

  /// Exclusive upper bound on an occurrence's start instant, or null.
  final DateTime? until;

  bool get hasEnd => count != null || until != null;

  Map<String, dynamic> toJson() => {
    'freq': recurrenceFreqWire(freq),
    'interval': interval,
    if (count != null) 'count': count,
    if (until != null) 'until': until!.toUtc().toIso8601String(),
  };

  factory Recurrence.fromJson(Map<String, dynamic> json) => Recurrence(
    freq: parseRecurrenceFreq(json['freq']?.toString()),
    interval: (json['interval'] as num?)?.toInt() ?? 1,
    count: (json['count'] as num?)?.toInt(),
    until: json['until'] != null
        ? DateTime.tryParse(json['until'].toString())?.toUtc()
        : null,
  );

  /// Start instants for every occurrence, including [start] itself.
  ///
  /// Steps by calendar components (`DateTime(year, month, day + 7 * n, hour,
  /// minute)`), never by `Duration(days: n)`: adding a fixed duration to a
  /// local time drifts by an hour across a DST boundary and would silently move
  /// a series off its intended wall-clock slot.
  ///
  /// [max] caps the result so an "unbounded" rule cannot generate forever.
  List<DateTime> occurrences(DateTime start, {int max = hardMax}) {
    final cap = max < 1 ? 1 : (max > hardMax ? hardMax : max);
    final step = interval < 1 ? 1 : interval;
    final wanted = count != null && count! > 0
        ? (count! < cap ? count! : cap)
        : cap;

    final out = <DateTime>[];
    for (var n = 0; out.length < wanted; n++) {
      final at = _addSteps(start, step * n);
      if (until != null && !at.isBefore(until!)) break;
      // A monthly rule started on the 31st can land on the same resolved date
      // twice (Feb 28 clamped from 29/30/31); stop rather than emit duplicates.
      if (out.isNotEmpty && !at.isAfter(out.last)) break;
      out.add(at);
    }
    return out;
  }

  DateTime _addSteps(DateTime start, int steps) {
    final y = start.year;
    final m = start.month;
    final d = start.day;
    return switch (freq) {
      RecurrenceFreq.daily => DateTime(
        y,
        m,
        d + steps,
        start.hour,
        start.minute,
      ),
      RecurrenceFreq.weekly => DateTime(
        y,
        m,
        d + 7 * steps,
        start.hour,
        start.minute,
      ),
      RecurrenceFreq.monthly => _addMonths(start, steps),
    };
  }

  /// Month arithmetic clamps the day (Jan 31 + 1 month -> Feb 28/29) rather
  /// than rolling into the next month, which is what a booking series expects.
  static DateTime _addMonths(DateTime start, int steps) {
    final total = start.month - 1 + steps;
    final year = start.year + (total ~/ 12);
    final month = total % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = start.day > lastDay ? lastDay : start.day;
    return DateTime(year, month, day, start.hour, start.minute);
  }
}
