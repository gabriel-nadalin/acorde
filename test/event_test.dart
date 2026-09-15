import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/models/event.dart';

void main() {
  test('Event.fromMap resolves expanded venue and performer names', () {
    final event = Event.fromMap({
      'id': 'e1',
      'title': 'Show',
      'start': '2026-08-01T19:00:00Z',
      'end': '2026-08-01T21:00:00Z',
      'venueId': 'v1',
      'performers': '["p1","p2"]',
      'expand': {
        'venueId': {'id': 'v1', 'name': 'Harbor Hall'},
        'performers': [
          {'id': 'p1', 'name': 'Radiohead'},
          {'id': 'p2', 'name': 'Thom Yorke'},
        ],
      },
    });

    expect(event.venueName, 'Harbor Hall');
    expect(event.performerNames, ['Radiohead', 'Thom Yorke']);
    expect(event.venueId, 'v1');
    expect(event.performers, ['p1', 'p2']);
  });

  test('Event.fromMap falls back to IDs when expand is absent', () {
    final event = Event.fromMap({
      'id': 'e2',
      'title': 'Show 2',
      'start': '2026-08-02T19:00:00Z',
      'end': '2026-08-02T21:00:00Z',
      'venueId': 'v9',
      'performers': '["p9"]',
    });

    expect(event.venueName, isNull);
    expect(event.performerNames, isEmpty);
    expect(event.venueId, 'v9');
    expect(event.performers, ['p9']);
  });

  test('Event JSON round-trip preserves all fields', () {
    final event = Event(
      id: 'e3',
      title: 'Round Trip',
      description: 'desc',
      start: DateTime.parse('2026-09-01T19:00:00.000Z'),
      end: DateTime.parse('2026-09-01T21:30:00.000Z'),
      venueId: 'v3',
      performers: ['p1', 'p2'],
      createdBy: 'u1',
      created: DateTime.parse('2026-08-15T10:00:00.000Z'),
      venueName: 'Hall',
      performerNames: ['Alice', 'Bob'],
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
    expect(restored.venueName, event.venueName);
    expect(restored.performerNames, event.performerNames);
  });

  test('Event.toMap writes UTC instants for naive local datetimes', () {
    // Picked times are naive local (no zone); the wire format must still be
    // an unambiguous UTC instant so month-boundary string filters align.
    final event = Event(
      title: 'Local time',
      start: DateTime(2026, 8, 1, 19, 0),
      end: DateTime(2026, 8, 1, 21, 0),
    );

    final map = event.toMap();
    expect(map['start'], endsWith('Z'));
    expect(map['end'], endsWith('Z'));
    // The instant is preserved exactly, regardless of the machine timezone.
    expect(DateTime.parse(map['start'] as String).toUtc(), event.start.toUtc());
    expect(DateTime.parse(map['end'] as String).toUtc(), event.end.toUtc());
  });

  test('Event.fromMap reads the server `created` autodate', () {
    // PocketBase serializes autodates as "YYYY-MM-DD HH:MM:SS.sssZ" (space
    // separator, not 'T'); a parse failure would silently fall back to now().
    final event = Event.fromMap({
      'title': 'Wire',
      'start': '2026-05-04 19:00:00.000Z',
      'end': '2026-05-04 20:00:00.000Z',
      'created': '2026-05-30 05:02:21.328Z',
    }, 'e1');

    expect(event.created.toUtc(), DateTime.utc(2026, 5, 30, 5, 2, 21, 328));
    // `created` is server-managed and must never be sent back on write.
    expect(event.toMap().containsKey('created'), isFalse);
  });
}