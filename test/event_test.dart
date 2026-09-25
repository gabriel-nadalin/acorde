import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:acorde/models/event.dart';
import 'package:acorde/models/recurrence.dart';

/// `Event` has two serialization paths on purpose: [Event.toMap] is the wire
/// payload the double-booking guard reads, [Event.toJson] is the offline cache.
/// These tests pin the observable difference between them.
void main() {
  Event sample({Recurrence? recurrence, String? seriesId}) => Event(
    id: 'e3',
    title: 'Round Trip',
    description: 'desc',
    start: DateTime.parse('2026-09-01T19:00:00.000Z'),
    end: DateTime.parse('2026-09-01T21:30:00.000Z'),
    venueId: 'v3',
    performers: const ['p1', 'p2'],
    createdBy: 'u1',
    created: DateTime.parse('2026-08-15T10:00:00.000Z'),
    updated: DateTime.parse('2026-08-16T09:30:00.000Z'),
    seriesId: seriesId,
    recurrence: recurrence,
  );

  group('fromMap', () {
    test('reads the venue and performer ids a record carries', () {
      final event = Event.fromMap({
        'id': 'e2',
        'title': 'Gig',
        'start': '2026-09-01 19:00:00.000Z',
        'end': '2026-09-01 21:00:00.000Z',
        'venueId': 'v9',
        'performers': ['p9'],
      });

      expect(event.venueId, 'v9');
      expect(event.performers, ['p9']);
    });

    test(
      'reads the server `created`/`updated` autodates and the series fields',
      () {
        final event = Event.fromMap({
          'id': 'e4',
          'title': 'Series',
          'start': '2026-09-01 19:00:00.000Z',
          'end': '2026-09-01 21:00:00.000Z',
          'created': '2026-08-01 08:00:00.000Z',
          'updated': '2026-08-02 09:00:00.000Z',
          'seriesId': 's1',
          'recurrence': {'freq': 'weekly', 'interval': 2, 'count': 4},
        });

        expect(event.created, DateTime.parse('2026-08-01T08:00:00.000Z'));
        expect(event.updated, DateTime.parse('2026-08-02T09:00:00.000Z'));
        expect(event.seriesId, 's1');
        expect(event.recurrence?.freq, RecurrenceFreq.weekly);
        expect(event.recurrence?.interval, 2);
        expect(event.recurrence?.count, 4);
        expect(event.isSeriesInstance, isTrue);
      },
    );

    test('throws FormatException when start or end is missing', () {
      Map<String, dynamic> base() => {
        'title': 'Gig',
        'start': '2026-09-01 19:00:00.000Z',
        'end': '2026-09-01 21:00:00.000Z',
      };

      final noStart = base()..remove('start');
      final noEnd = base()..remove('end');

      expect(() => Event.fromMap(noStart), throwsFormatException);
      expect(() => Event.fromMap(noEnd), throwsFormatException);
    });

    test('throws FormatException when start or end is unparseable', () {
      // The old behaviour substituted DateTime.now(), which surfaced a broken
      // record as a plausible booking at the current time.
      expect(
        () => Event.fromMap({
          'title': 'Gig',
          'start': 'not-a-date',
          'end': '2026-09-01 21:00:00.000Z',
        }),
        throwsFormatException,
      );
      expect(
        () => Event.fromMap({
          'title': 'Gig',
          'start': '2026-09-01 19:00:00.000Z',
          'end': '',
        }),
        throwsFormatException,
      );
    });

    test(
      'parses performers from a JSON string, a real array and a CSV string alike',
      () {
        Map<String, dynamic> withPerformers(Object? performers) => {
          'title': 'Gig',
          'start': '2026-09-01 19:00:00.000Z',
          'end': '2026-09-01 21:00:00.000Z',
          'performers': performers,
        };

        const expected = ['p1', 'p2'];
        expect(
          Event.fromMap(withPerformers(['p1', 'p2'])).performers,
          expected,
        );
        expect(
          Event.fromMap(withPerformers('["p1","p2"]')).performers,
          expected,
        );
        expect(Event.fromMap(withPerformers('p1, p2')).performers, expected);
        expect(Event.fromMap(withPerformers(null)).performers, isEmpty);
      },
    );
  });

  group('toMap (wire payload)', () {
    test('writes naive local dates as UTC instants with a Z suffix', () {
      final local = DateTime(2026, 9, 1, 19, 0);
      final map = Event(
        title: 'Gig',
        start: local,
        end: DateTime(2026, 9, 1, 21, 30),
      ).toMap();

      expect(map['start'], isA<String>());
      final wireStart = map['start'] as String;
      final wireEnd = map['end'] as String;
      expect(wireStart, endsWith('Z'));
      expect(wireEnd, endsWith('Z'));
      // The instant survives; only the representation is UTC.
      expect(DateTime.parse(wireStart).isUtc, isTrue);
      expect(DateTime.parse(wireStart), local.toUtc());
      expect(DateTime.parse(wireEnd), DateTime(2026, 9, 1, 21, 30).toUtc());
    });

    test('emits performers as a real JSON array', () {
      final map = Event(
        title: 'Gig',
        start: DateTime(2026, 9, 1, 19),
        end: DateTime(2026, 9, 1, 21),
        performers: const ['p1', 'p2'],
      ).toMap();

      expect(map['performers'], isA<List>());
      final decoded = jsonDecode(jsonEncode(map)) as Map<String, dynamic>;
      expect(decoded['performers'], ['p1', 'p2']);
    });

    test(
      'carries seriesId and recurrence, and never a server-managed field',
      () {
        final map = sample(
          seriesId: 's1',
          recurrence: const Recurrence(
            freq: RecurrenceFreq.weekly,
            interval: 2,
            count: 4,
          ),
        ).toMap();

        expect(map['seriesId'], 's1');
        expect(map['recurrence'], {
          'freq': 'weekly',
          'interval': 2,
          'count': 4,
        });
        expect(map.containsKey('createdBy'), isFalse);
        expect(map.containsKey('created'), isFalse);
        expect(map.containsKey('updated'), isFalse);
      },
    );

    test('emits a null recurrence for a one-off event', () {
      expect(sample().toMap()['recurrence'], isNull);
    });
  });

  group('toJson (offline cache)', () {
    test('round-trips every canonical field', () {
      final event = sample(
        seriesId: 's1',
        recurrence: const Recurrence(
          freq: RecurrenceFreq.monthly,
          interval: 1,
          count: 3,
        ),
      );
      final restored = Event.fromJson(event.toJson());

      expect(restored.id, event.id);
      expect(restored.title, event.title);
      expect(restored.description, event.description);
      expect(restored.start, event.start);
      expect(restored.end, event.end);
      expect(restored.venueId, event.venueId);
      expect(restored.performers, event.performers);
      expect(restored.createdBy, event.createdBy);
      expect(restored.created, event.created);
      expect(restored.updated, event.updated);
      expect(restored.seriesId, event.seriesId);
      expect(restored.recurrence?.toJson(), event.recurrence?.toJson());
    });
  });

  group('duration and occurrenceAt', () {
    test('duration is the span between start and end', () {
      final event = Event(
        title: 'Gig',
        start: DateTime(2026, 9, 1, 19),
        end: DateTime(2026, 9, 1, 21, 30),
      );

      expect(event.duration, const Duration(hours: 2, minutes: 30));
    });

    test('occurrenceAt keeps the wall-clock time and the span', () {
      final event = Event(
        title: 'Gig',
        start: DateTime(2026, 9, 1, 19),
        end: DateTime(2026, 9, 1, 21, 30),
        performers: const ['p1'],
      );

      final next = event.occurrenceAt(DateTime(2026, 9, 8, 19));

      expect(next.start.hour, 19);
      expect(next.start.minute, 0);
      expect(next.end, DateTime(2026, 9, 8, 21, 30));
      expect(next.duration, event.duration);
      expect(next.performers, event.performers);
    });
  });
}
