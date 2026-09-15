import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_application_1/data/repositories.dart';
import 'package:flutter_application_1/services/pocketbase_service.dart';

/// Fake PocketBase responding to the record endpoints used by the repos.
MockClient fakeClient({required Map<String, List<Map<String, dynamic>>> collections}) {
  return MockClient((request) async {
    final parts = request.url.path.split('/');
    if (request.url.path.endsWith('auth-with-password')) {
      return http.Response(
        jsonEncode({'token': 'tok', 'record': {'id': 'u1', 'email': 'x@example.com', 'name': 'X'}}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // /api/collections/<name>/records
    final collection = parts[3];
    return http.Response(
      jsonEncode({'items': collections[collection] ?? []}),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

void main() {
  test('AuthController computes assignments from memberIds/managerIds', () async {
    final client = fakeClient(collections: {
      'performers': [
        {'id': 'p1', 'name': 'Radiohead', 'memberIds': '["u1","u2"]'},
        {'id': 'p2', 'name': 'Other Band', 'memberIds': '["u3"]'},
      ],
      'venues': [
        {'id': 'v1', 'name': 'Harbor Hall', 'managerIds': '["u1"]'},
        {'id': 'v2', 'name': 'Bluebird Club', 'managerIds': '["u9"]'},
      ],
    });
    final auth = AuthController(service: PocketBaseService(client: client));

    final ok = await auth.login('x@example.com', 'pw');
    expect(ok, isTrue);
    expect(auth.user?['id'], 'u1');
    expect(auth.myPerformers.map((p) => p['id']), ['p1']);
    expect(auth.myVenues.map((v) => v['id']), ['v1']);
  });

  test('PerformerRepository loads once and reuses cache', () async {
    var fetchCount = 0;
    final client = MockClient((request) async {
      fetchCount++;
      return http.Response(
        jsonEncode({'items': [{'id': 'p1', 'name': 'Radiohead'}]}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = PerformerRepository(service: PocketBaseService(client: client));

    await repo.load();
    await repo.load();
    await repo.load();
    expect(fetchCount, 1);
    expect(repo.items.single['name'], 'Radiohead');
  });

  test('EventRepository falls back to cache when the network fails', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    var offline = false;
    final client = MockClient((request) async {
      if (offline) throw http.ClientException('offline');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'e1',
              'title': 'Gig',
              'start': '2026-08-01T19:00:00Z',
              'end': '2026-08-01T21:00:00Z',
              'venueId': 'v1',
              'performers': '[]',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = EventRepository(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    final month = DateTime(2026, 8);

    final first = await repo.loadForMonth(month);
    expect(first, hasLength(1));
    expect(repo.isMonthStale(month), isFalse);

    offline = true;
    final cached = await repo.loadForMonth(month);
    expect(cached, hasLength(1));
    expect(cached.single.title, 'Gig');
    expect(repo.isMonthStale(month), isTrue);
    // Staleness is per-month: an unrelated month is not flagged.
    expect(repo.isMonthStale(DateTime(2026, 9)), isFalse);

    offline = false;
    await repo.loadForMonth(month);
    expect(repo.isMonthStale(month), isFalse);
  });

  test('EventRepository survives restart via persisted cache', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final okClient = MockClient((request) async => http.Response(
          jsonEncode({
            'items': [
              {
                'id': 'e1',
                'title': 'Gig',
                'start': '2026-08-01T19:00:00Z',
                'end': '2026-08-01T21:00:00Z',
                'venueId': 'v1',
                'performers': '[]',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final firstRepo = EventRepository(
      service: PocketBaseService(client: okClient),
      prefs: Future.value(prefs),
    );
    await firstRepo.loadForMonth(DateTime(2026, 8));

    // Simulate a restart: a new repo whose service is unreachable, sharing
    // the same SharedPreferences store.
    final offlineClient = MockClient((request) async => throw http.ClientException('offline'));
    final secondRepo = EventRepository(
      service: PocketBaseService(client: offlineClient),
      prefs: Future.value(prefs),
    );
    final restored = await secondRepo.loadForMonth(DateTime(2026, 8));

    expect(restored, hasLength(1));
    expect(restored.single.title, 'Gig');
    expect(secondRepo.isMonthStale(DateTime(2026, 8)), isTrue);
  });

  test('EventRepository overlapping falls back to cached months offline', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    var offline = false;
    final client = MockClient((request) async {
      if (offline) throw http.ClientException('offline');
      return http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'e1',
              'title': 'Gig',
              'start': '2026-08-01T19:00:00Z',
              'end': '2026-08-01T21:00:00Z',
              'venueId': 'v1',
              'performers': '[]',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = EventRepository(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    await repo.loadForMonth(DateTime(2026, 8));

    offline = true;
    final overlapping = await repo.overlapping(
      DateTime.utc(2026, 8, 1, 18),
      DateTime.utc(2026, 8, 1, 22),
    );
    expect(overlapping, hasLength(1));
    final none = await repo.overlapping(
      DateTime.utc(2026, 9, 1),
      DateTime.utc(2026, 9, 2),
    );
    expect(none, isEmpty);
  });

  test('EventRepository dedups concurrent loads of the same month', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    var fetchCount = 0;
    final client = MockClient((request) async {
      fetchCount++;
      return http.Response(
        jsonEncode({'items': []}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = EventRepository(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    final month = DateTime(2026, 8);

    final results = await Future.wait([
      repo.loadForMonth(month),
      repo.loadForMonth(month),
      repo.loadForMonth(month),
    ]);
    expect(fetchCount, 1);
    expect(results, hasLength(3));
  });

  test('getEvents paginates until every record is fetched', () async {
    final pages = <int>[];
    final client = MockClient((request) async {
      final page = int.parse(request.url.queryParameters['page'] ?? '1');
      final perPage = int.parse(request.url.queryParameters['perPage'] ?? '100');
      pages.add(page);
      final start = (page - 1) * perPage;
      final chunk = <Map<String, dynamic>>[];
      for (var i = start; i < (start + perPage).clamp(0, 5); i++) {
        chunk.add({
          'id': 'e$i',
          'title': 'E$i',
          'start': '2026-08-01T19:00:00Z',
          'end': '2026-08-01T21:00:00Z',
        });
      }
      return http.Response(
        jsonEncode({'items': chunk, 'totalItems': 5}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = PocketBaseService(client: client);

    final events = await service.getEvents(perPage: 2);
    expect(events, hasLength(5));
    expect(pages, [1, 2, 3]);
  });

  test('AuthController.refresh(force: true) refetches and recomputes assignments', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    var secondBandMembers = '["u9"]';
    final client = MockClient((request) async {
      if (request.url.path.endsWith('auth-with-password')) {
        return http.Response(
          jsonEncode({'token': 'tok', 'record': {'id': 'u1', 'email': 'x@example.com'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final parts = request.url.path.split('/');
      final collection = parts[3];
      final body = collection == 'performers'
          ? [
              {'id': 'p1', 'name': 'Radiohead', 'memberIds': '["u1"]'},
              {'id': 'p2', 'name': 'Other Band', 'memberIds': secondBandMembers},
            ]
          : <Map<String, dynamic>>[];
      return http.Response(
        jsonEncode({'items': body}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final auth = AuthController(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    await auth.login('x@example.com', 'pw');
    expect(auth.myPerformers.map((p) => p['id']), ['p1']);

    secondBandMembers = '["u1"]';
    // Without force, refresh() reuses the loaded cache and sees no change.
    await auth.refresh();
    expect(auth.myPerformers.map((p) => p['id']), ['p1']);

    await auth.refresh(force: true);
    expect(auth.myPerformers.map((p) => p['id']), ['p1', 'p2']);
  });

  test('AuthController.restoreSession restores a persisted session offline', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    var offline = false;
    final client = MockClient((request) async {
      if (offline) throw http.ClientException('offline');
      if (request.url.path.endsWith('auth-with-password')) {
        return http.Response(
          jsonEncode({'token': 'tok', 'record': {'id': 'u1', 'email': 'x@example.com', 'name': 'X'}}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      final parts = request.url.path.split('/');
      final collection = parts[3];
      return http.Response(
        jsonEncode({
          'items': collection == 'performers'
              ? [
                  {'id': 'p1', 'name': 'Radiohead', 'memberIds': '["u1"]'},
                ]
              : <Map<String, dynamic>>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final first = AuthController(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    await first.login('x@example.com', 'pw');
    expect(first.isLoggedIn, isTrue);

    // A fresh controller, offline: the session must come back from storage.
    offline = true;
    final second = AuthController(
      service: PocketBaseService(client: client),
      prefs: Future.value(prefs),
    );
    await second.restoreSession();
    expect(second.isLoggedIn, isTrue);
    expect(second.user?['id'], 'u1');
    // Offline, assignments can't be recomputed; keep them empty rather than wrong.
    expect(second.myPerformers, isEmpty);
  });
}