import 'package:flutter_test/flutter_test.dart';

import 'package:event_calendar/models/recurrence.dart';

import 'support/local_time_zone.dart';

/// The rule is expanded client-side into concrete event records, so a wrong
/// step lands real bookings on the wrong wall-clock slot. Every case here is
/// about *start instants*, not about the JSON shape that carries them.
void main() {
  // America/New_York springs forward on 2026-03-08 (02:00 -> 03:00) and falls
  // back on 2026-11-01, so a `Duration(days: 1)` step is visible as an hour of
  // drift. Without this the suite would run in a zone with no transition and
  // could not tell the two implementations apart.
  late String? originalZone;

  setUpAll(() {
    originalZone = LocalTimeZone.current();
    LocalTimeZone.use('America/New_York');
  });

  tearDownAll(() => LocalTimeZone.restore(originalZone));

  test('weekly interval 2 produces starts 14 days apart at the same time', () {
    final start = DateTime(2026, 1, 5, 19, 30);
    final occurrences = const Recurrence(
      freq: RecurrenceFreq.weekly,
      interval: 2,
      count: 4,
    ).occurrences(start);

    expect(occurrences, hasLength(4));
    expect(occurrences.first, start);
    for (final at in occurrences) {
      expect(at.hour, 19);
      expect(at.minute, 30);
    }
    for (var i = 1; i < occurrences.length; i++) {
      expect(
        occurrences[i].difference(occurrences[i - 1]),
        const Duration(days: 14),
      );
    }
    expect(occurrences.map((at) => at.day), [5, 19, 2, 16]);
    expect(occurrences.map((at) => at.month), [1, 1, 2, 2]);
  });

  test(
    'daily occurrences keep the local hour across the spring-forward transition',
    () {
      final start = DateTime(2026, 3, 6, 9, 30);
      final occurrences = const Recurrence(
        freq: RecurrenceFreq.daily,
        count: 5,
      ).occurrences(start);

      expect(occurrences, hasLength(5));
      expect(occurrences.map((at) => at.day), [6, 7, 8, 9, 10]);
      for (final at in occurrences) {
        expect(at.hour, 9);
        expect(at.minute, 30);
      }
      // 2026-03-08 is 23 hours long locally: the wall clock held while the
      // instant stepped. A `Duration(days: 1)` implementation reports 24 here
      // and lands on 10:30 for the following days.
      expect(
        occurrences[2].difference(occurrences[1]),
        const Duration(hours: 23),
      );
      expect(
        occurrences[3].difference(occurrences[2]),
        const Duration(hours: 24),
      );
    },
  );

  test(
    'daily occurrences keep the local hour across the fall-back transition',
    () {
      final start = DateTime(2026, 10, 31, 9, 30);
      final occurrences = const Recurrence(
        freq: RecurrenceFreq.daily,
        count: 3,
      ).occurrences(start);

      expect(occurrences.map((at) => at.day), [31, 1, 2]);
      for (final at in occurrences) {
        expect(at.hour, 9);
        expect(at.minute, 30);
      }
      expect(
        occurrences[1].difference(occurrences[0]),
        const Duration(hours: 25),
      );
    },
  );

  test(
    'monthly from the 31st clamps to the short month and does not roll over',
    () {
      final start = DateTime(2026, 1, 31, 20);
      final occurrences = const Recurrence(
        freq: RecurrenceFreq.monthly,
        count: 4,
      ).occurrences(start);

      expect(occurrences, hasLength(4));
      expect(occurrences.map((at) => '${at.year}-${at.month}-${at.day}'), [
        '2026-1-31',
        '2026-2-28',
        '2026-3-31',
        '2026-4-30',
      ]);
      for (final at in occurrences) {
        expect(at.hour, 20);
      }
    },
  );

  test('monthly clamps to a 29-day February in a leap year', () {
    final occurrences = const Recurrence(
      freq: RecurrenceFreq.monthly,
      count: 2,
    ).occurrences(DateTime(2028, 1, 31, 20));

    expect(occurrences.map((at) => '${at.year}-${at.month}-${at.day}'), [
      '2028-1-31',
      '2028-2-29',
    ]);
  });

  test(
    'monthly occurrences are strictly increasing and never repeat a start',
    () {
      final occurrences = const Recurrence(
        freq: RecurrenceFreq.monthly,
        count: 6,
      ).occurrences(DateTime(2026, 1, 31, 20));

      final months = <String>{};
      for (var i = 0; i < occurrences.length; i++) {
        expect(
          months.add('${occurrences[i].year}-${occurrences[i].month}'),
          isTrue,
          reason: 'month repeated at index $i: ${occurrences[i]}',
        );
        if (i > 0) expect(occurrences[i].isAfter(occurrences[i - 1]), isTrue);
      }
    },
  );

  test('until is exclusive', () {
    final occurrences = Recurrence(
      freq: RecurrenceFreq.daily,
      until: DateTime(2026, 3, 3),
    ).occurrences(DateTime(2026, 3, 1, 19));

    expect(occurrences.map((at) => at.day), [1, 2]);
  });

  test('count includes the first occurrence', () {
    final start = DateTime(2026, 5, 4, 8);
    final occurrences = const Recurrence(
      freq: RecurrenceFreq.daily,
      count: 3,
    ).occurrences(start);

    expect(occurrences.first, start);
    expect(occurrences, hasLength(3));
  });

  test('max caps an unbounded rule', () {
    final capped = const Recurrence(
      freq: RecurrenceFreq.daily,
    ).occurrences(DateTime(2026, 1, 1, 8), max: 5);

    expect(capped, hasLength(5));
    expect(capped.last.day, 5);
  });

  test('an unbounded rule stops at the hard ceiling', () {
    expect(
      const Recurrence(
        freq: RecurrenceFreq.daily,
      ).occurrences(DateTime(2026, 1, 1, 8)),
      hasLength(Recurrence.hardMax),
    );
  });

  test('toJson/fromJson round-trips the rule', () {
    final rule = Recurrence(
      freq: RecurrenceFreq.monthly,
      interval: 3,
      count: 5,
      until: DateTime(2026, 12, 1, 20),
    );
    final restored = Recurrence.fromJson(rule.toJson());

    expect(restored.freq, RecurrenceFreq.monthly);
    expect(restored.interval, 3);
    expect(restored.count, 5);
    expect(restored.until!.isAtSameMomentAs(rule.until!), isTrue);
    // The restored rule expands identically, which is what the cache is for.
    expect(
      restored.occurrences(DateTime(2026, 1, 31, 20)).map((at) => at.toUtc()),
      rule.occurrences(DateTime(2026, 1, 31, 20)).map((at) => at.toUtc()),
    );
  });

  test('an unbounded rule round-trips without inventing a count', () {
    final restored = Recurrence.fromJson(
      const Recurrence(freq: RecurrenceFreq.weekly, interval: 2).toJson(),
    );

    expect(restored.count, isNull);
    expect(restored.until, isNull);
    expect(restored.hasEnd, isFalse);
    expect(restored.interval, 2);
    expect(restored.freq, RecurrenceFreq.weekly);
  });
}
