/// Live integration test for the realtime SSE client.
///
/// This exists because the first implementation of the realtime handshake was
/// *plausible and wrong*, and nothing caught it: the unit tests all use a
/// `MockClient`, and a mock can only encode the caller's own assumption about
/// the protocol. It happily answered the `POST /api/realtime` that PocketBase
/// answers with a bodiless `204`, so the suite stayed green while no change
/// notification could ever arrive.
///
/// The protocol is server-first, and only a real server can prove that:
///
///   1. `GET /api/realtime` (SSE) is opened first and answers with a
///      `PB_CONNECT` frame carrying `clientId`.
///   2. `POST /api/realtime` with `{clientId, subscriptions}` registers the
///      subscriptions against that id.
///   3. Change notifications then arrive on the same SSE stream.
///
/// Run from the repository root: `dart run scripts/realtime_test.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:acorde/models/event.dart';
import 'package:acorde/services/pocketbase_service.dart';

import 'pb_harness.dart';

Future<void> main() async {
  exitCode = await runWithHarness(_run);
}

Future<void> _run(PbHarness h, PbAssertions a) async {
  stdout.writeln('Agenda realtime test — PocketBase SSE client');
  stdout.writeln('Target: ${h.baseUrl}\n');

  // --------------------------------------------------------------- fixtures
  // Two separate service instances on purpose: the subscriber must observe a
  // change made by *somebody else*, not by the connection it is watching.
  final writer = PocketBaseService(baseUrl: h.baseUrl);
  final reader = PocketBaseService(baseUrl: h.baseUrl);

  final signup = await h.post('/api/collections/users/records', {
    'email': 'realtime@agenda.test',
    'password': 'realtime-password-123',
    'passwordConfirm': 'realtime-password-123',
    'name': 'realtime',
  });
  a.check('fixture account is created', signup.status == 200, '$signup');

  final login = await h.post('/api/collections/users/auth-with-password', {
    'identity': 'realtime@agenda.test',
    'password': 'realtime-password-123',
  });
  final token = (login.body['token'] as String?) ?? '';
  final userId = (login.body['record'] as Map?)?['id']?.toString() ?? '';
  a.check(
    'fixture account authenticates',
    token.isNotEmpty && userId.isNotEmpty,
    '$login',
  );

  writer.restoreAuth(token, null);
  reader.restoreAuth(token, null);

  // A venue created through the API, so the guard writes its membership row and
  // the owner may book it. Creating the venue also proves the entities guard
  // accepts an app user.
  final venue = await h.post('/api/collections/venues/records', {
    'name': 'Realtime Hall',
    'address': '9 Stream St',
    'contact': 'rt@test',
  }, token: token);
  a.check('fixture venue is created', venue.status == 200, '$venue');

  // ------------------------------------------------------ subscribe and write
  final received = <RealtimeEvent>[];
  final errors = <Object>[];
  final subscription = reader
      .realtime(['events'])
      .listen(received.add, onError: errors.add);

  // Give the connection its `PB_CONNECT` and the subscription POST time to
  // land. Short: if the handshake is wrong, waiting longer never helps.
  await Future<void>.delayed(const Duration(seconds: 3));

  final created = await writer.createEvent(
    Event(
      title: 'Realtime Probe',
      start: DateTime.utc(2027, 5, 4, 19),
      end: DateTime.utc(2027, 5, 4, 20),
      venueId: venue.id,
    ),
  );
  a.check(
    'the write under test succeeds',
    (created.id ?? '').isNotEmpty,
    '$created',
  );

  // Long enough for a frame that has already been sent, short enough to fail
  // fast when nothing is coming.
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (received.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  await subscription.cancel();
  writer.close();
  reader.close();

  a.check('the subscription reports no errors', errors.isEmpty, '$errors');
  a.check(
    'a change made by another client arrives on the stream',
    received.any((e) => e.record['title'] == 'Realtime Probe'),
    'received=${received.map((e) => '${e.action}:${e.collection}:${e.record['title']}').toList()}',
  );

  final match = received
      .where((e) => e.record['title'] == 'Realtime Probe')
      .toList();
  if (match.isNotEmpty) {
    final event = match.first;
    a.check(
      'the frame names the collection',
      event.collection == 'events',
      event.collection,
    );
    a.check(
      'the frame carries the action',
      event.action == 'create',
      event.action,
    );
    a.check(
      'the frame carries the record id',
      event.record['id'] == created.id,
      '${event.record['id']}',
    );
  }
}
