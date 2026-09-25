import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:acorde/data/repositories.dart';
import 'package:acorde/models/event.dart';
import 'package:acorde/services/pocketbase_service.dart';

import 'support/fake_pocketbase.dart';

Map<String, dynamic> eventRecord(
  String id, {
  required DateTime start,
  required DateTime end,
  String title = 'Gig',
  String venueId = 'v1',
}) => {
  'id': id,
  'title': title,
  'start': start.toUtc().toIso8601String(),
  'end': end.toUtc().toIso8601String(),
  'venueId': venueId,
  'performers': <String>[],
  'createdBy': 'u1',
  'created': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePb pb;
  late PocketBaseService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pb = FakePb();
    service = PocketBaseService(baseUrl: 'http://pb.test', client: pb.client());
  });

  group('AssignmentsController', () {
    Future<AssignmentsController> bootAssignments() async {
      pb.records('performers')
        ..add({'id': 'p1', 'name': 'My Band'})
        ..add({'id': 'p2', 'name': 'Someone Else'})
        ..add({'id': 'p3', 'name': 'Invited Performer'});
      pb.records('venues')
        ..add({'id': 'v1', 'name': 'My Hall'})
        ..add({'id': 'v2', 'name': 'Not Mine'})
        ..add({'id': 'v3', 'name': 'Invited Hall'});
      // `status` decides whether a row grants anything, and it is fail-closed:
      // a row without it parses as pending, so m1/m2 must say `active`
      // explicitly or they are (correctly) not assignments.
      pb.records('memberships')
        ..add({
          'id': 'm1',
          'userId': 'u1',
          'targetId': 'p1',
          'targetType': 'performer',
          'role': 'member',
          'status': 'active',
        })
        ..add({
          'id': 'm2',
          'userId': 'u1',
          'targetId': 'v1',
          'targetType': 'venue',
          'role': 'manager',
          'status': 'active',
        })
        ..add({
          'id': 'm3',
          'userId': 'u2',
          'targetId': 'p2',
          'targetType': 'performer',
          'role': 'member',
          'status': 'active',
        })
        ..add({
          'id': 'm4',
          'userId': '',
          'pendingEmail': 'Me@Example.com',
          'targetId': 'v3',
          'targetType': 'venue',
          'role': 'manager',
          'status': 'pending',
        });
      pb.authRecord = {'id': 'u1', 'email': 'me@example.com'};

      final session = SessionController(
        service: service,
        prefs: SharedPreferences.getInstance(),
      );
      await session.login('me@example.com', 'pw');

      return AssignmentsController(
        session: session,
        performers: PerformerRepository(service: service),
        venues: VenueRepository(service: service),
        memberships: MembershipRepository(service: service),
      );
    }

    test('derives my entities from the memberships collection', () async {
      final assignments = await bootAssignments();

      await assignments.refresh();

      expect(assignments.myPerformers.map((performer) => performer.id), ['p1']);
      expect(assignments.myVenues.map((venue) => venue.id), ['v1']);
      expect(assignments.myMemberships.map((membership) => membership.id), [
        'm1',
        'm2',
      ]);
    });

    test('isMyVenue/isMyPerformer agree with myVenues/myPerformers', () async {
      final assignments = await bootAssignments();
      await assignments.refresh();

      final venueRepo = VenueRepository(service: service);
      final performerRepo = PerformerRepository(service: service);
      await venueRepo.load();
      await performerRepo.load();

      for (final venue in venueRepo.items) {
        expect(
          assignments.isMyVenue(venue.id!),
          assignments.myVenues.any((mine) => mine.id == venue.id),
        );
      }
      for (final performer in performerRepo.items) {
        expect(
          assignments.isMyPerformer(performer.id!),
          assignments.myPerformers.any((mine) => mine.id == performer.id),
        );
      }
      expect(assignments.isMyVenue('v1'), isTrue);
      expect(assignments.isMyVenue('v2'), isFalse);
      expect(assignments.isMyPerformer('p1'), isTrue);
      expect(assignments.isMyPerformer('p2'), isFalse);
    });

    test('an unclaimed invitation is pending, not an assignment', () async {
      final assignments = await bootAssignments();
      await assignments.refresh();

      expect(assignments.pendingInvites.map((membership) => membership.id), [
        'm4',
      ]);
      expect(assignments.pendingInvites.single.targetId, 'v3');

      expect(
        assignments.myVenues.map((venue) => venue.id),
        isNot(contains('v3')),
      );
      expect(assignments.isMyVenue('v3'), isFalse);
      expect(
        assignments.myPerformers.map((performer) => performer.id),
        isNot(contains('p3')),
      );
    });
  });

  group('EntityRepository', () {
    test('loads once, reuses the cache, and refetches only when forced', () async {
      pb.records('venues').add({'id': 'v1', 'name': 'Hall'});
      final venues = VenueRepository(service: service);

      await venues.load();
      expect(pb.count('GET venues'), 1);
      expect(venues.loaded, isTrue);
      expect(venues.items.map((venue) => venue.name), ['Hall']);

      await venues.load();
      expect(
        pb.count('GET venues'),
        1,
        reason: 'a second non-forced load must reuse the cache',
      );

      pb.records('venues').add({'id': 'v2', 'name': 'Annex'});
      await venues.load(force: true);
      expect(pb.count('GET venues'), 2);
      // Name order, not insertion order: the app asks the server for `sort=name`,
      // which is what the list screens depend on. (This assertion used to read
      // 'Hall', 'Annex' because the fake ignored `sort` — it was pinning the
      // fake's behaviour rather than the server's.)
      expect(venues.items.map((venue) => venue.name), ['Annex', 'Hall']);
    });

    test(
      'a forced load issued during a non-forced pass still reaches the server',
      () async {
        pb.records('venues').add({'id': 'v1', 'name': 'First'});
        final venues = VenueRepository(service: service);

        final gate = Completer<void>();
        var gets = 0;
        pb.intercept = (request) async {
          if (request.method != 'GET' ||
              !request.url.path.contains('/venues/')) {
            return null;
          }
          gets++;
          if (gets == 1) {
            // Stall the first pass so the forced call arrives while it is running.
            await gate.future;
            return FakePb.json(200, {
              'items': [
                {'id': 'v1', 'name': 'First'},
              ],
              'totalItems': 1,
              'page': 1,
              'perPage': 200,
            });
          }
          return FakePb.json(200, {
            'items': [
              {'id': 'v1', 'name': 'Second'},
            ],
            'totalItems': 1,
            'page': 1,
            'perPage': 200,
          });
        };

        final inFlight = venues.load();
        final forced = venues.load(force: true);

        await forced;
        expect(
          venues.items.map((venue) => venue.name),
          equals(['Second']),
          reason: 'the forced pass must not silently join the in-flight one',
        );

        gate.complete();
        await inFlight;

        expect(
          pb.count('GET venues'),
          2,
          reason: 'force was dropped and never reached the server',
        );
      },
    );

    test(
      'byId finds the record and search filters on the display name',
      () async {
        pb.records('performers')
          ..add({'id': 'p1', 'name': 'Alpha Band'})
          ..add({'id': 'p2', 'name': 'Beta Duo'})
          ..add({'id': 'p3', 'name': 'Gamma Trio'});
        final performers = PerformerRepository(service: service);
        await performers.load();

        expect(performers.byId('p2')?.name, 'Beta Duo');
        expect(performers.byId('nope'), isNull);

        expect((await performers.search('beta')).map((p) => p.name), [
          'Beta Duo',
        ]);
        expect((await performers.search('TRIO')).map((p) => p.name), [
          'Gamma Trio',
        ]);
        expect(await performers.search('zzz'), isEmpty);
        expect(await performers.search(''), hasLength(3));
        expect(await performers.search('', limit: 2), hasLength(2));
        expect(
          pb.count('GET performers'),
          1,
          reason: 'search must answer from the loaded records',
        );
      },
    );

    test(
      'a failing fetch keeps the last known records and marks them stale',
      () async {
        pb.records('venues').add({'id': 'v1', 'name': 'Hall'});
        final venues = VenueRepository(service: service);
        await venues.load();

        pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/venues/')) {
            throw http.ClientException('offline');
          }
          return null;
        };

        await venues.load(force: true);

        expect(venues.items.map((venue) => venue.name), ['Hall']);
        expect(venues.stale, isTrue);
      },
    );

    test(
      'a corrupt persisted mirror sets cacheCorrupt instead of vanishing',
      () async {
        SharedPreferences.setMockInitialValues({'venues_cache': '{not json'});
        pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/venues/')) {
            throw http.ClientException('offline');
          }
          return null;
        };
        final venues = VenueRepository(service: service);

        await expectLater(venues.load(), throwsA(isA<PocketBaseException>()));

        expect(venues.cacheCorrupt, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('venues_cache'),
          isNull,
          reason: 'the unreadable entry is dropped',
        );
      },
    );
  });

  group('EventRepository', () {
    late EventRepository events;

    setUp(() {
      events = EventRepository(
        service: service,
        prefs: SharedPreferences.getInstance(),
      );
    });

    test(
      'serves the cached month and marks only that month stale when the fetch fails',
      () async {
        pb.records('events')
          ..add(
            eventRecord(
              'sep',
              start: DateTime(2026, 9, 4, 19),
              end: DateTime(2026, 9, 4, 21),
            ),
          )
          ..add(
            eventRecord(
              'oct',
              start: DateTime(2026, 10, 4, 19),
              end: DateTime(2026, 10, 4, 21),
            ),
          );

        await events.loadForMonth(DateTime(2026, 9));
        await events.loadForMonth(DateTime(2026, 10));
        expect(events.isMonthStale(DateTime(2026, 9)), isFalse);
        expect(events.isMonthStale(DateTime(2026, 10)), isFalse);

        pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/events/')) {
            throw http.ClientException('offline');
          }
          return null;
        };

        final served = await events.loadForMonth(DateTime(2026, 9));

        expect(
          served.map((event) => event.id),
          equals(['sep']),
          reason: 'the cached month is served, not an error',
        );
        expect(events.isMonthStale(DateTime(2026, 9)), isTrue);
        expect(
          events.isMonthStale(DateTime(2026, 10)),
          isFalse,
          reason: 'staleness is per month',
        );

        // A later successful load clears it again.
        pb.intercept = null;
        await events.loadForMonth(DateTime(2026, 9));
        expect(events.isMonthStale(DateTime(2026, 9)), isFalse);
      },
    );

    test(
      'a restart with an unreachable backend restores the persisted month',
      () async {
        final persisted = Event(
          id: 'e9',
          title: 'Persisted',
          start: DateTime(2026, 9, 12, 20),
          end: DateTime(2026, 9, 12, 22),
          venueId: 'v1',
        );
        SharedPreferences.setMockInitialValues({
          'events_cache_2026-09': jsonEncode([persisted.toJson()]),
        });

        pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/events/')) {
            throw http.ClientException('offline');
          }
          return null;
        };

        final repo = EventRepository(
          service: service,
          prefs: SharedPreferences.getInstance(),
        );
        final restored = await repo.loadForMonth(DateTime(2026, 9));

        expect(restored.map((event) => event.id), ['e9']);
        expect(restored.single.title, 'Persisted');
        expect(repo.cachedMonth(DateTime(2026, 9)), isNotNull);
        expect(repo.loadedMonths, contains('2026-09'));
      },
    );

    test(
      'a corrupt persisted month sets cacheCorrupt and is dropped',
      () async {
        SharedPreferences.setMockInitialValues({
          'events_cache_2026-09': '{not json',
        });
        pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/events/')) {
            throw http.ClientException('offline');
          }
          return null;
        };

        final repo = EventRepository(
          service: service,
          prefs: SharedPreferences.getInstance(),
        );

        await expectLater(
          repo.loadForMonth(DateTime(2026, 9)),
          throwsA(anything),
        );

        expect(repo.cacheCorrupt, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('events_cache_2026-09'),
          isNull,
          reason: 'the unreadable entry is dropped',
        );
      },
    );

    test(
      'a mutation reloads every loaded month, not just the newest',
      () async {
        pb.records('events')
          ..add(
            eventRecord(
              'jan',
              start: DateTime(2026, 1, 4, 19),
              end: DateTime(2026, 1, 4, 21),
            ),
          )
          ..add(
            eventRecord(
              'feb',
              start: DateTime(2026, 2, 4, 19),
              end: DateTime(2026, 2, 4, 21),
            ),
          );

        await events.loadForMonth(DateTime(2026, 1));
        await events.loadForMonth(DateTime(2026, 2));
        expect(events.loadedMonths, {'2026-01', '2026-02'});

        final before = pb.count('GET events');
        await events.update('jan', {'title': 'Renamed'});

        expect(
          pb.count('GET events'),
          before + 2,
          reason: 'both open months must be refreshed',
        );
        expect(events.loadedMonths, {'2026-01', '2026-02'});
      },
    );

    test(
      'createSeries posts every instance in turn and reports the rejected ones',
      () async {
        var active = 0;
        var peak = 0;
        var created = 0;
        pb.intercept = (request) async {
          if (request.method != 'POST' ||
              !request.url.path.contains('/events/')) {
            return null;
          }
          active++;
          peak = active > peak ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active--;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if ((body['title'] as String).startsWith('rejected')) {
            return FakePb.json(400, {
              'message':
                  'Schedule conflict: venue already booked in this time range.',
              'status': 400,
            });
          }
          return FakePb.json(200, {...body, 'id': 'created_${++created}'});
        };

        Event instance(String title, DateTime start) => Event(
          title: title,
          start: start,
          end: start.add(const Duration(hours: 2)),
          venueId: 'v1',
          seriesId: 's1',
        );

        final failures = await events.createSeries([
          instance('gig one', DateTime(2026, 5, 1, 19)),
          instance('rejected gig', DateTime(2026, 5, 8, 19)),
          instance('gig three', DateTime(2026, 5, 15, 19)),
        ]);

        expect(failures, hasLength(1));
        expect(failures.single, contains('Schedule conflict'));
        expect(
          failures.single,
          startsWith('2026-05-08'),
          reason: 'the failing occurrence is named',
        );
        expect(
          pb.count('POST events'),
          3,
          reason: 'one rejected instance must not abort the rest',
        );
        expect(
          peak,
          1,
          reason: 'instances go through the double-booking guard one at a time',
        );
      },
    );
  });

  group('SessionController', () {
    test(
      'login returns null for rejected credentials and throws for an unreachable backend',
      () async {
        final session = SessionController(
          service: service,
          prefs: SharedPreferences.getInstance(),
        );

        pb.authRecord = null; // the server answers 401
        expect(await session.login('me@example.com', 'wrong'), isNull);
        expect(session.isLoggedIn, isFalse);

        pb.authRecord = {'id': 'u1', 'email': 'me@example.com'};
        expect(await session.login('me@example.com', 'pw'), isNotNull);
        expect(session.isLoggedIn, isTrue);
        expect(session.userId, 'u1');

        pb.intercept = (request) async {
          if (request.url.path.endsWith('auth-with-password')) {
            throw http.ClientException('offline');
          }
          return null;
        };
        final attemptsBefore = pb.count('POST users');
        await expectLater(
          session.login('me@example.com', 'pw'),
          throwsA(
            isA<PocketBaseException>().having(
              (error) => error.kind,
              'kind',
              PbErrorKind.network,
            ),
          ),
        );
        expect(
          pb.count('POST users'),
          attemptsBefore + 1,
          reason: 'a write is never retried automatically',
        );
      },
    );

    test(
      'restoreSession restores offline and logout clears memory and storage',
      () async {
        SharedPreferences.setMockInitialValues({
          'auth_user': jsonEncode({'id': 'u1', 'email': 'me@example.com'}),
          'auth_token': 'persisted-token',
          'auth_cookie': 'pb_session=abc',
        });
        final session = SessionController(
          service: service,
          prefs: SharedPreferences.getInstance(),
        );

        await session.restoreSession();

        expect(session.isLoggedIn, isTrue);
        expect(session.userId, 'u1');
        expect(service.authToken, 'persisted-token');
        expect(service.authCookie, 'pb_session=abc');
        expect(
          pb.log,
          isEmpty,
          reason: 'restoring a session must not need the backend',
        );

        session.logout();

        expect(session.isLoggedIn, isFalse);
        expect(session.userId, isNull);
        expect(service.authToken, isNull);
        await pumpEventQueue();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('auth_user'), isNull);
        expect(prefs.getString('auth_token'), isNull);
        expect(prefs.getString('auth_cookie'), isNull);
      },
    );
  });

  group('PocketBaseService', () {
    test('getEvents follows pagination to the last page', () async {
      for (var day = 1; day <= 5; day++) {
        pb
            .records('events')
            .add(
              eventRecord(
                'e$day',
                start: DateTime(2026, 9, day, 10),
                end: DateTime(2026, 9, day, 12),
              ),
            );
      }

      final events = await service.getEvents(perPage: 2);

      expect(events.map((event) => event.id), ['e1', 'e2', 'e3', 'e4', 'e5']);
      expect(
        pb.count('GET events'),
        3,
        reason: '2 + 2 + 1 records across three pages',
      );
    });

    test(
      'getEvents stops on the page that completes totalItems without asking for one more',
      () async {
        for (var day = 1; day <= 4; day++) {
          pb
              .records('events')
              .add(
                eventRecord(
                  'e$day',
                  start: DateTime(2026, 9, day, 10),
                  end: DateTime(2026, 9, day, 12),
                ),
              );
        }

        final events = await service.getEvents(perPage: 2);

        expect(events, hasLength(4));
        expect(
          pb.count('GET events'),
          2,
          reason: 'a full last page must not trigger an extra request',
        );
      },
    );

    test(
      'kind is derived from the status, with a schedule conflict singled out',
      () {
        expect(
          PocketBaseException.fromBody(401, '{"message":"unauthorized"}').kind,
          PbErrorKind.auth,
        );
        expect(
          PocketBaseException.fromBody(403, '{"message":"forbidden"}').kind,
          PbErrorKind.forbidden,
        );
        expect(
          PocketBaseException.fromBody(404, '{"message":"missing"}').kind,
          PbErrorKind.notFound,
        );
        expect(
          PocketBaseException.fromBody(400, '{"message":"bad field"}').kind,
          PbErrorKind.validation,
        );
        expect(
          PocketBaseException.fromBody(422, '{"message":"bad field"}').kind,
          PbErrorKind.validation,
        );
        expect(
          PocketBaseException.fromBody(500, '{"message":"boom"}').kind,
          PbErrorKind.server,
        );
        expect(
          PocketBaseException.fromBody(503, 'not json').kind,
          PbErrorKind.server,
        );

        final conflict = PocketBaseException.fromBody(
          400,
          jsonEncode({
            'message':
                'Schedule conflict: venue already booked in this time range.',
            'status': 400,
          }),
        );
        expect(conflict.kind, PbErrorKind.conflict);
        expect(conflict.statusCode, 400);
        expect(conflict.message, startsWith('Schedule conflict'));

        expect(PocketBaseException.fromBody(401, 'x').isAuthFailure, isTrue);
        expect(PocketBaseException.fromBody(403, 'x').isAuthFailure, isFalse);
      },
    );

    test(
      'idempotent GETs retry on a transport failure, writes do not',
      () async {
        pb.records('venues').add({'id': 'v1', 'name': 'Hall'});
        var failures = 2;
        pb.intercept = (request) async {
          if (failures > 0) {
            failures--;
            throw http.ClientException('connection reset');
          }
          return null;
        };

        final venues = await service.getVenues();
        expect(venues.map((venue) => venue.name), ['Hall']);
        expect(
          pb.count('GET venues'),
          3,
          reason: 'two retries after the first attempt',
        );

        var posts = 0;
        pb.intercept = (request) async {
          if (request.method == 'POST' &&
              request.url.path.contains('/venues/')) {
            posts++;
            throw http.ClientException('connection reset');
          }
          return null;
        };

        await expectLater(
          service.createVenue({'name': 'X'}),
          throwsA(isA<PocketBaseException>()),
        );
        expect(posts, 1, reason: 'a retried write could be applied twice');
      },
    );
  });
}
