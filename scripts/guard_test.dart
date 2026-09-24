#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'pb_harness.dart';

/// End-to-end guard test for the Agenda PocketBase backend.
///
/// Usage:
///   dart run scripts/guard_test.dart
///
/// See `pb_harness.dart` for the environment overrides (`PB_TEST_URL`,
/// `PB_TEST_BINARY`, `PB_TEST_PORT`, `PB_TEST_ADMIN_EMAIL`,
/// `PB_TEST_ADMIN_PASSWORD`) and for how the backend is booted.
///
/// # What this proves that a unit test cannot
///
/// Every assertion is a round trip through the real binary with the real
/// migrations applied and the real hook files loaded. The three parts of this
/// backend that fail *silently* when they are wrong are all covered:
///
///   * The `json`-field byte-array trap: `performers` arrives on a request
///     record as `[]uint8`, so a naive decoder turns ids into digit characters
///     and the overlap comparison becomes nonsense. The "shared performer" case
///     only passes when the decoder is correct.
///   * The `date`-filter trap: a `date` column is compared as TEXT in
///     PocketBase's normalised `YYYY-MM-DD HH:MM:SS.sssZ` form, so an RFC3339
///     value in the filter matches nothing and turns the double-booking guard
///     into a no-op instead of an error. A passing conflict assertion is the
///     only real evidence the guard is alive.
///   * The `venueId` normalisation trap: `venueId` is a plain text column, and
///     a padded value would silently skip both the ownership lookup and the
///     overlap comparison.
///
/// The event payloads come from [eventPayload], which mirrors `Event.toMap()`
/// in `lib/models/event.dart` field for field — UTC `Z` timestamps, a nullable
/// string `venueId`, a real JSON array for `performers`, and no
/// `createdBy`/`created`/`updated`. That is the cross-language contract check:
/// if the client's shape and the guard's expectations drift, these assertions
/// fail against the running server rather than against a mock.
Future<void> main(List<String> args) async {
  final code = await runWithHarness(_run);
  // `dart run` does NOT honour a `Future<int>` returned from `main` (verified
  // against Dart 3.13: a run with failing assertions still exited 0). The exit
  // code must therefore be set explicitly, or CI would go green on a broken
  // schema and a broken guard alike.
  await stdout.flush();
  exit(code);
}

/// The exact JSON the Flutter client posts. Kept in lockstep with
/// `Event.toMap()`.
Map<String, dynamic> eventPayload({
  required String title,
  required DateTime start,
  required DateTime end,
  String? venueId,
  List<String> performers = const [],
  String? seriesId,
  Map<String, dynamic>? recurrence,
  String description = '',
}) => {
  'title': title,
  'description': description,
  'start': start.toUtc().toIso8601String(),
  'end': end.toUtc().toIso8601String(),
  'venueId': venueId,
  'performers': performers,
  'seriesId': seriesId,
  'recurrence': recurrence,
};

class _Identity {
  const _Identity(this.id, this.token);
  final String id;
  final String token;
}

Future<void> _run(PbHarness h, PbAssertions a) async {
  stdout.writeln('Agenda guard test — PocketBase backend');
  stdout.writeln('Target: ${h.baseUrl}\n');

  final superuser = await h.superuserToken();
  a.check('superuser authenticates', superuser.isNotEmpty);

  // --------------------------------------------------------------- fixtures
  // Every account is a plain signup and every entity is created through the
  // API, so the memberships rows below are written by the guard under test
  // rather than seeded behind its back.
  final ownerA = await _signup(h, 'owner.a@agenda.test'); // manages venue V1
  final ownerC = await _signup(
    h,
    'owner.c@agenda.test',
  ); // manages performer P1
  final outsider = await _signup(h, 'outsider@agenda.test'); // manages nothing
  a.check(
    'fixture accounts authenticate',
    ownerA.token.isNotEmpty &&
        ownerC.token.isNotEmpty &&
        outsider.token.isNotEmpty,
  );

  final venueResp = await h.post('/api/collections/venues/records', {
    'name': 'Guard Test Hall',
    'address': '1 Test Way',
    'capacity': 100,
    'timezone': 'UTC',
    'contact': 'v@test',
  }, token: ownerA.token);
  a.check('owner creates a venue', venueResp.status == 200, '$venueResp');
  final venueId = venueResp.id;

  final performerResp = await h.post('/api/collections/performers/records', {
    'name': 'Guard Test Band',
    'type': 'band',
    'contact': 'p@test',
  }, token: ownerC.token);
  a.check(
    'manager creates a performer',
    performerResp.status == 200,
    '$performerResp',
  );
  final performerId = performerResp.id;

  // The create hook is meant to write the memberships row after saving. Without
  // it nothing else in this file can pass, so it is asserted directly instead of
  // being inferred from the event assertions.
  final venueMemberships = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('userId="${ownerA.id}" && targetId="$venueId"')}',
    token: ownerA.token,
  );
  final venueMembershipItems = _items(venueMemberships);
  // The row must be an ACTIVE MANAGER row, not merely present: `canAdminister`
  // has no `createdBy` shortcut any more, so this row is the creator's only
  // claim on the venue.
  a.check(
    'venue create auto-writes an ACTIVE manager memberships row for the creator',
    venueMembershipItems.length == 1 &&
        venueMembershipItems.first['targetType'] == 'venue' &&
        venueMembershipItems.first['role'] == 'manager' &&
        venueMembershipItems.first['status'] == 'active' &&
        venueMembershipItems.first['initiatedBy'] == 'invite',
    '$venueMemberships',
  );

  final performerMemberships = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('userId="${ownerC.id}" && targetId="$performerId"')}',
    token: ownerC.token,
  );
  final performerMembershipItems = _items(performerMemberships);
  // The creator is the entity's first manager for both kinds. A performer's
  // creator used to get `role = "member"`, which `canAdminister` rejects — they
  // held admin rights only through the `ownerId` shortcut. See `roleFor`.
  a.check(
    'performer create auto-writes an active manager memberships row',
    performerMembershipItems.length == 1 &&
        performerMembershipItems.first['role'] == 'manager' &&
        performerMembershipItems.first['status'] == 'active',
    '$performerMemberships',
  );

  // -------------------------------------------------- 1. outsider is denied
  final outsiderCreate = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Outsider event',
      start: DateTime.utc(2026, 3, 1, 10),
      end: DateTime.utc(2026, 3, 1, 11),
      venueId: venueId,
      performers: [performerId],
    ),
    token: outsider.token,
  );
  a.check(
    'a user who manages neither the venue nor any performer is refused (403)',
    outsiderCreate.status == 403,
    '$outsiderCreate',
  );

  // ---------------------------------------------------- 2. manager may create
  final baseEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Booked by the venue manager',
      start: DateTime.utc(2026, 3, 2, 19),
      end: DateTime.utc(2026, 3, 2, 21),
      venueId: venueId,
      performers: [performerId],
    ),
    token: ownerA.token,
  );
  a.check(
    'a manager can create an event for their venue',
    baseEvent.status == 200,
    '$baseEvent',
  );
  a.check(
    'createdBy is forced to the caller on create',
    baseEvent.body['createdBy'] == ownerA.id,
    '$baseEvent',
  );

  final forged = await h.post('/api/collections/events/records', {
    ...eventPayload(
      title: 'Forged authorship',
      start: DateTime.utc(2026, 3, 3, 19),
      end: DateTime.utc(2026, 3, 3, 20),
      venueId: venueId,
    ),
    'createdBy': outsider.id,
  }, token: ownerA.token);
  a.check(
    'a client-supplied createdBy is never trusted',
    forged.status == 200 && forged.body['createdBy'] == ownerA.id,
    '$forged',
  );
  if (forged.id.isNotEmpty) {
    await h.delete(
      '/api/collections/events/records/${forged.id}',
      token: ownerA.token,
    );
  }

  // -------------------------------------------- 3. same-venue double-booking
  final venueOverlap = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Venue double-booking',
      start: DateTime.utc(2026, 3, 2, 20),
      end: DateTime.utc(2026, 3, 2, 22),
      venueId: venueId,
    ),
    token: ownerA.token,
  );
  a.check(
    'overlapping the same venue is a 400 Schedule conflict',
    venueOverlap.status == 400 &&
        venueOverlap.message.startsWith('Schedule conflict'),
    '$venueOverlap',
  );

  // ------------------------------------------ 4. shared-performer double-booking
  // A DIFFERENT venue in the same window, so the only thing that can trip the
  // guard is the performer set — the path that depends on decoding the
  // `[]uint8` json field correctly.
  final performerOverlap = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Performer double-booking',
      start: DateTime.utc(2026, 3, 2, 19, 30),
      end: DateTime.utc(2026, 3, 2, 20, 30),
      performers: [performerId],
    ),
    token: ownerC.token,
  );
  a.check(
    'overlapping a shared performer is a 400 Schedule conflict',
    performerOverlap.status == 400 &&
        performerOverlap.message.startsWith('Schedule conflict'),
    '$performerOverlap',
  );

  // A non-overlapping booking for the same performer must still be allowed, or
  // the assertion above would only prove "the guard rejects everything".
  final performerOk = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Performer later that night',
      start: DateTime.utc(2026, 3, 2, 22),
      end: DateTime.utc(2026, 3, 2, 23),
      performers: [performerId],
    ),
    token: ownerC.token,
  );
  a.check(
    'a non-overlapping booking for the same performer is allowed',
    performerOk.status == 200,
    '$performerOk',
  );

  // -------------------------------- 5. required dates + "booked somewhere"
  final missingDates = await h.post('/api/collections/events/records', {
    'title': 'No dates',
  }, token: ownerA.token);
  a.check(
    'a direct API write with start/end omitted is rejected',
    missingDates.status == 400,
    '$missingDates',
  );

  final emptyDates = await h.post('/api/collections/events/records', {
    'title': 'Blank dates',
    'start': '',
    'end': '',
  }, token: ownerA.token);
  a.check(
    'a direct API write with empty start/end is rejected',
    emptyDates.status == 400,
    '$emptyDates',
  );

  final superuserMissingDates = await h.send(
    'POST',
    '/api/collections/events/records',
    body: {'title': 'No dates (admin)'},
    token: superuser,
  );
  a.check(
    'the schema itself rejects a start/end-less row, superuser included',
    superuserMissingDates.status == 400,
    '$superuserMissingDates',
  );

  final reversed = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Backwards',
      start: DateTime.utc(2026, 3, 4, 20),
      end: DateTime.utc(2026, 3, 4, 19),
      venueId: venueId,
    ),
    token: ownerA.token,
  );
  a.check(
    'an event whose end precedes its start is rejected',
    reversed.status == 400,
    '$reversed',
  );

  final unbooked = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Nowhere',
      start: DateTime.utc(2026, 3, 4, 20),
      end: DateTime.utc(2026, 3, 4, 21),
    ),
    token: ownerA.token,
  );
  a.check(
    'an event with neither venue nor performer is rejected',
    unbooked.status == 400,
    '$unbooked',
  );

  // ------------------------------ 6. self-overlap allowed, other overlap not
  final selfUpdate = await h.patch(
    '/api/collections/events/records/${baseEvent.id}',
    {'title': 'Renamed in place'},
    token: ownerA.token,
  );
  a.check(
    'an update that would overlap only itself is allowed',
    selfUpdate.status == 200,
    '$selfUpdate',
  );

  final clashingUpdate = await h
      .patch('/api/collections/events/records/${performerOk.id}', {
        'start': DateTime.utc(2026, 3, 2, 19, 15).toIso8601String(),
        'end': DateTime.utc(2026, 3, 2, 20, 15).toIso8601String(),
      }, token: ownerC.token);
  a.check(
    'an update overlapping a DIFFERENT event is rejected',
    clashingUpdate.status == 400 &&
        clashingUpdate.message.startsWith('Schedule conflict'),
    '$clashingUpdate',
  );

  // -------------------------------------- 7. venueId whitespace normalisation
  final padded = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Padded venue id',
      start: DateTime.utc(2026, 3, 5, 19),
      end: DateTime.utc(2026, 3, 5, 20),
      venueId: '  $venueId  ',
    ),
    token: ownerA.token,
  );
  a.check(
    'a padded venueId still resolves ownership (no false 403)',
    padded.status == 200,
    '$padded',
  );
  a.check(
    'the padded venueId is stored normalised',
    padded.body['venueId'] == venueId,
    'stored=${padded.body['venueId']}',
  );

  final paddedCollision = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Clean id against the padded row',
      start: DateTime.utc(2026, 3, 5, 19, 30),
      end: DateTime.utc(2026, 3, 5, 20, 30),
      venueId: venueId,
    ),
    token: ownerA.token,
  );
  a.check(
    'a clean venueId collides with the padded row',
    paddedCollision.status == 400 &&
        paddedCollision.message.startsWith('Schedule conflict'),
    '$paddedCollision',
  );

  // ------------------------------------------------- 8. DELETE is exempt
  final deleteTarget = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Somebody else booked it',
      start: DateTime.utc(2026, 3, 6, 19),
      end: DateTime.utc(2026, 3, 6, 21),
      performers: [performerId],
    ),
    token: ownerC.token,
  );
  a.check(
    'fixture event for the delete case is created',
    deleteTarget.status == 200,
    '$deleteTarget',
  );

  final sameSlot = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Owner cancels while a peer event runs',
      start: DateTime.utc(2026, 3, 6, 20),
      end: DateTime.utc(2026, 3, 6, 22),
      venueId: venueId,
    ),
    token: ownerA.token,
  );
  a.check(
    'an overlapping window sharing no venue or performer is allowed',
    sameSlot.status == 200,
    '$sameSlot',
  );

  final deleteResp = await h.delete(
    '/api/collections/events/records/${sameSlot.id}',
    token: ownerA.token,
  );
  a.check(
    'DELETE is allowed for an owner even when the range overlaps',
    deleteResp.status == 204,
    '$deleteResp',
  );

  final gone = await h.get(
    '/api/collections/events/records/${sameSlot.id}',
    token: ownerA.token,
  );
  a.check('the deleted event is really gone', gone.status == 404, '$gone');

  final deleteOthers = await h.delete(
    '/api/collections/events/records/${deleteTarget.id}',
    token: ownerA.token,
  );
  a.check(
    "an unrelated user cannot delete somebody else's event (403)",
    deleteOthers.status == 403,
    '$deleteOthers',
  );

  // A row stored before the "booked somewhere" rule existed — the live dataset
  // has exactly one — must stay deletable by its owner. Shape validation
  // describes what a WRITE produces, and a DELETE produces nothing, so applying
  // it there would strand the row forever.
  final legacyShape = await h.send(
    'POST',
    '/api/collections/events/records',
    token: superuser,
    body: {
      ...eventPayload(
        title: 'Legacy unbooked row',
        start: DateTime.utc(2026, 3, 9, 19),
        end: DateTime.utc(2026, 3, 9, 20),
      ),
      'createdBy': ownerA.id,
    },
  );
  a.check(
    'superuser can insert an unbooked event (legacy shape)',
    legacyShape.status == 200,
    '$legacyShape',
  );
  // The create branch clears `createdBy` for a superuser, so attribute the row
  // to an app user the way an import of pre-existing data would.
  final legacyAttributed = await h.send(
    'PATCH',
    '/api/collections/events/records/${legacyShape.id}',
    token: superuser,
    body: {'createdBy': ownerA.id},
  );
  a.check(
    'a superuser may attribute an imported event to a user',
    legacyAttributed.status == 200 &&
        legacyAttributed.body['createdBy'] == ownerA.id,
    '$legacyAttributed',
  );
  final legacyDelete = await h.delete(
    '/api/collections/events/records/${legacyShape.id}',
    token: ownerA.token,
  );
  a.check(
    'an owner can still delete an event with no venue and no performers',
    legacyDelete.status == 204,
    '$legacyDelete',
  );

  // --------------------------------------------- 9. invite-by-email lifecycle
  const inviteeEmail = 'invitee@agenda.test';
  const inviteePassword = 'invitee-password-123';

  final outsiderInvite = await h.post('/api/collections/memberships/records', {
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'manager',
    'pendingEmail': 'nobody@agenda.test',
  }, token: outsider.token);
  a.check(
    'a non-manager cannot invite to the venue (403)',
    outsiderInvite.status == 403,
    '$outsiderInvite',
  );

  final invite = await h.post('/api/collections/memberships/records', {
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'manager',
    'pendingEmail': inviteeEmail,
  }, token: ownerA.token);
  a.check(
    'the first manager of a venue can invite by email',
    invite.status == 200,
    '$invite',
  );
  a.check(
    'the invite starts out pending (no userId)',
    (invite.body['userId'] ?? '') == '' &&
        invite.body['pendingEmail'] == inviteeEmail,
    '$invite',
  );
  final inviteId = invite.id;

  final inviteeSignup = await h.post('/api/collections/users/records', {
    'email': inviteeEmail,
    'password': inviteePassword,
    'passwordConfirm': inviteePassword,
    'name': 'Invitee',
  });
  a.check(
    'the invited account can sign up',
    inviteeSignup.status == 200,
    '$inviteeSignup',
  );
  final inviteeId = inviteeSignup.id;

  final pendingAfterSignup = await h.get(
    '/api/collections/memberships/records/$inviteId',
    token: superuser,
  );
  a.check(
    'the invite is still unclaimed before the invitee authenticates',
    (pendingAfterSignup.body['userId'] ?? '') == '',
    '$pendingAfterSignup',
  );

  // Authentication is the only point where ownership of the address is proven,
  // so it is the claim trigger.
  final inviteeLogin = await h.post(
    '/api/collections/users/auth-with-password',
    {'identity': inviteeEmail, 'password': inviteePassword},
  );
  final inviteeToken = (inviteeLogin.body['token'] as String?) ?? '';
  a.check(
    'the invited account authenticates',
    inviteeToken.isNotEmpty,
    '$inviteeLogin',
  );

  final claimed = await h.get(
    '/api/collections/memberships/records/$inviteId',
    token: superuser,
  );
  a.check(
    'the invited account gains access only after authenticating (pendingEmail claimed)',
    claimed.body['userId'] == inviteeId,
    '$claimed',
  );
  // Claiming the address is NOT consent. The row must stay pending: a manager
  // typing an address must not hand out booking rights before the invitee has
  // answered. (This assertion replaces `targetOwnerId is recorded server-side
  // on the invite` — that column no longer exists, and a matched email used to
  // activate the row outright, which is the consent bug this phase fixes.)
  a.check(
    'a claimed invitation stays pending, it does not activate',
    claimed.body['status'] == 'pending',
    '$claimed',
  );
  a.check(
    'an invitation records itself as manager-initiated',
    claimed.body['initiatedBy'] == 'invite',
    '$claimed',
  );
  a.check(
    'targetOwnerId is gone from the membership schema',
    claimed.body.containsKey('targetOwnerId') == false,
    '$claimed',
  );

  // The memberships read rule is self-only now: the denormalised `targetOwnerId`
  // that used to let an owner list their whole team is gone, and the roster
  // endpoint (asserted in the Phase 2 section below) replaced it.
  final ownRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter=${Uri.encodeComponent('targetId="$venueId"')}',
    token: ownerA.token,
  );
  a.check(
    "the collection read rule returns only the caller's own rows",
    ownRows.status == 200 &&
        _items(ownRows).length == 1 &&
        _items(ownRows).first['userId'] == ownerA.id,
    '$ownRows',
  );

  final outsiderRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter=${Uri.encodeComponent('targetId="$venueId"')}',
    token: outsider.token,
  );
  a.check(
    "a non-owner cannot list other people's membership rows",
    _items(outsiderRows).isEmpty,
    '$outsiderRows',
  );

  final pendingBooking = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Invited manager books',
      start: DateTime.utc(2026, 3, 7, 19),
      end: DateTime.utc(2026, 3, 7, 20),
      venueId: venueId,
    ),
    token: inviteeToken,
  );
  a.check(
    'a PENDING invitation grants no event access (403)',
    pendingBooking.status == 403,
    '$pendingBooking',
  );

  final accept = await h.post('/api/agenda/invite/respond', {
    'membershipId': inviteId,
    'action': 'accept',
  }, token: inviteeToken);
  a.check(
    'the invitee can accept the invitation (200 active)',
    accept.status == 200 && accept.body['status'] == 'active',
    '$accept',
  );

  final inviteeCreate = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Invited manager books',
      start: DateTime.utc(2026, 3, 7, 19),
      end: DateTime.utc(2026, 3, 7, 20),
      venueId: venueId,
    ),
    token: inviteeToken,
  );
  a.check(
    'after accepting, the invitee can create events for the venue',
    inviteeCreate.status == 200,
    '$inviteeCreate',
  );

  final acceptAgain = await h.post('/api/agenda/invite/respond', {
    'membershipId': inviteId,
    'action': 'accept',
  }, token: inviteeToken);
  a.check(
    'accepting an already-active invitation is refused (400)',
    acceptAgain.status == 400,
    '$acceptAgain',
  );

  final strangerResponds = await h.post('/api/agenda/invite/respond', {
    'membershipId': inviteId,
    'action': 'decline',
  }, token: outsider.token);
  a.check(
    'only the invitee may answer an invitation (403)',
    strangerResponds.status == 403,
    '$strangerResponds',
  );

  // ------------------------------------------ 9b. declining an invitation
  const declinerEmail = 'decliner@agenda.test';
  final declined = await h.post('/api/collections/memberships/records', {
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'pendingEmail': declinerEmail,
  }, token: ownerA.token);
  a.check(
    'the manager can invite the future decliner',
    declined.status == 200,
    '$declined',
  );
  final declinerSignup = await h.post('/api/collections/users/records', {
    'email': declinerEmail,
    'password': inviteePassword,
    'passwordConfirm': inviteePassword,
    'name': 'Decliner',
  });
  final declinerLogin = await h.post(
    '/api/collections/users/auth-with-password',
    {'identity': declinerEmail, 'password': inviteePassword},
  );
  final declinerToken = (declinerLogin.body['token'] as String?) ?? '';
  a.check(
    'the decliner can sign up and authenticate',
    declinerSignup.status == 200 && declinerToken.isNotEmpty,
    '$declinerSignup',
  );

  final decline = await h.post('/api/agenda/invite/respond', {
    'membershipId': declined.id,
    'action': 'decline',
  }, token: declinerToken);
  a.check(
    'the invitee can decline (200 declined)',
    decline.status == 200 && decline.body['status'] == 'declined',
    '$decline',
  );

  final declinedGone = await h.get(
    '/api/collections/memberships/records/${declined.id}',
    token: superuser,
  );
  a.check(
    'a declined invitation is deleted, not kept',
    declinedGone.status == 404,
    '$declinedGone',
  );

  final declineAgain = await h.post('/api/agenda/invite/respond', {
    'membershipId': declined.id,
    'action': 'decline',
  }, token: declinerToken);
  a.check(
    'answering a deleted invitation is refused (400)',
    declineAgain.status == 400,
    '$declineAgain',
  );

  final reinvite = await h.post('/api/collections/memberships/records', {
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'pendingEmail': declinerEmail,
  }, token: ownerA.token);
  a.check(
    'a declined invitation does not block a re-invite',
    reinvite.status == 200 && reinvite.id.isNotEmpty,
    '$reinvite',
  );
  // The address now has an account, so the guard resolves `userId` — and leaves
  // the row pending. Matching the address is how the invitee is FOUND, never a
  // reason to grant access.
  a.check(
    'an invite to an existing address resolves userId and stays pending',
    reinvite.body['userId'] == declinerSignup.id &&
        reinvite.body['status'] == 'pending',
    '$reinvite',
  );

  final badAction = await h.post('/api/agenda/invite/respond', {
    'membershipId': reinvite.id,
    'action': 'maybe',
  }, token: declinerToken);
  a.check(
    'an unknown respond action is refused (400)',
    badAction.status == 400,
    '$badAction',
  );

  final declinerBooking = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Decliner books anyway',
      start: DateTime.utc(2026, 3, 10, 19),
      end: DateTime.utc(2026, 3, 10, 20),
      venueId: venueId,
    ),
    token: declinerToken,
  );
  a.check(
    'a re-invited account still has no access until it accepts',
    declinerBooking.status == 403,
    '$declinerBooking',
  );

  // ------------------------------- 10. referential integrity on entity delete
  final busyVenue = await h.post('/api/collections/venues/records', {
    'name': 'Busy Hall',
    'address': '2 Test Way',
    'contact': 'busy@test',
  }, token: outsider.token);
  a.check(
    'the outsider can create their own venue',
    busyVenue.status == 200,
    '$busyVenue',
  );

  final busyEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Keeps Busy Hall alive',
      start: DateTime.utc(2026, 3, 8, 19),
      end: DateTime.utc(2026, 3, 8, 20),
      venueId: busyVenue.id,
    ),
    token: outsider.token,
  );
  a.check(
    'the venue owner can book their own venue',
    busyEvent.status == 200,
    '$busyEvent',
  );

  final refusedDelete = await h.delete(
    '/api/collections/venues/records/${busyVenue.id}',
    token: outsider.token,
  );
  a.check(
    'deleting a venue that still has events is refused',
    refusedDelete.status == 400 &&
        refusedDelete.message.contains('still has events'),
    '$refusedDelete',
  );

  final busyPerformerDelete = await h.delete(
    '/api/collections/performers/records/$performerId',
    token: ownerC.token,
  );
  a.check(
    'deleting a performer that still has events is refused',
    busyPerformerDelete.status == 400 &&
        busyPerformerDelete.message.contains('still has events'),
    '$busyPerformerDelete',
  );

  final ownerStillUpdates = await h.patch(
    '/api/collections/venues/records/${busyVenue.id}',
    {'name': 'Hijacked'},
    token: outsider.token,
  );
  a.check(
    'the delete refusal does not lock the owner out of updating',
    ownerStillUpdates.status == 200,
    '$ownerStillUpdates',
  );

  final outsiderVenueUpdate = await h.patch(
    '/api/collections/venues/records/$venueId',
    {'name': 'Not mine'},
    token: outsider.token,
  );
  a.check(
    "a non-owner cannot update somebody else's venue (403)",
    outsiderVenueUpdate.status == 403,
    '$outsiderVenueUpdate',
  );

  // The admin dashboard and the seed script are superusers: they carry no auth
  // record, so both guards have to bypass for them or tooling breaks.
  final adminEventDelete = await h.send(
    'DELETE',
    '/api/collections/events/records/${busyEvent.id}',
    token: superuser,
  );
  a.check(
    'a superuser bypasses the event guards',
    adminEventDelete.status == 204,
    '$adminEventDelete',
  );

  final adminVenueDelete = await h.send(
    'DELETE',
    '/api/collections/venues/records/${busyVenue.id}',
    token: superuser,
  );
  a.check(
    'a superuser bypasses the reference check on venue delete',
    adminVenueDelete.status == 204,
    '$adminVenueDelete',
  );

  // ------------------------------------------- 11. the role actually gates
  // A `member` is someone who works for an entity, not someone who administers
  // it. Before this was enforced the column was decorative: a member could
  // rename and delete the venue and rewrite the roster exactly like its owner.
  final crew = await _signup(h, 'crew@agenda.test');
  // `status: active` because this is the manager adding somebody who is already
  // present and has agreed — the deliberate exception to the pending default.
  // Without it the row would be an invitation and the crew member could not
  // book anything, which the booking assertion below would catch.
  final inviteResp = await h.post('/api/collections/memberships/records', {
    'userId': crew.id,
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'status': 'active',
    'targetOwnerId': ownerA.id,
  }, token: ownerA.token);
  a.check(
    'an owner can add a member (not just a manager)',
    inviteResp.status == 200,
    '$inviteResp',
  );
  a.check(
    'an added member is stored active, and targetOwnerId is ignored',
    inviteResp.body['status'] == 'active' &&
        inviteResp.body.containsKey('targetOwnerId') == false,
    '$inviteResp',
  );
  final crewMembershipId = inviteResp.id;

  final crewCreate = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Crew books the hall',
      start: DateTime.utc(2026, 3, 20, 19),
      end: DateTime.utc(2026, 3, 20, 20),
      venueId: venueId,
    ),
    token: crew.token,
  );
  a.check(
    'a venue member may still book events (booking is not administration)',
    crewCreate.status == 200,
    '$crewCreate',
  );

  final crewRename = await h.patch('/api/collections/venues/records/$venueId', {
    'name': 'Crew Hall',
  }, token: crew.token);
  a.check(
    'a member cannot rename the venue (403)',
    crewRename.status == 403,
    '$crewRename',
  );

  final crewDelete = await h.delete(
    '/api/collections/venues/records/$venueId',
    token: crew.token,
  );
  a.check(
    'a member cannot delete the venue (403)',
    crewDelete.status == 403,
    '$crewDelete',
  );

  final crewInvite = await h.post('/api/collections/memberships/records', {
    'userId': crew.id,
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'manager',
    'status': 'active',
  }, token: crew.token);
  a.check(
    'a member cannot invite anyone (403)',
    crewInvite.status == 403,
    '$crewInvite',
  );

  // The owner's own manager row, resolved earlier from the create hook.
  final ownerMembershipId = '${venueMembershipItems.first['id']}';
  final crewEvict = await h.delete(
    '/api/collections/memberships/records/$ownerMembershipId',
    token: crew.token,
  );
  a.check(
    'a member cannot evict another member (403)',
    crewEvict.status == 403,
    '$crewEvict',
  );

  // The manager invited to a performer keeps booking rights there too, so the
  // role filter must not have narrowed the event guard.
  final performerInvite = await h.post('/api/collections/memberships/records', {
    'userId': crew.id,
    'targetId': performerId,
    'targetType': 'performer',
    'role': 'member',
    'status': 'active',
  }, token: ownerC.token);
  a.check(
    'a performer owner can add a member',
    performerInvite.status == 200,
    '$performerInvite',
  );

  final crewPerformerEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Crew plays the club',
      start: DateTime.utc(2026, 3, 21, 19),
      end: DateTime.utc(2026, 3, 21, 20),
      performers: [performerId],
    ),
    token: crew.token,
  );
  a.check(
    'a performer member may book that performer',
    crewPerformerEvent.status == 200,
    '$crewPerformerEvent',
  );

  final crewPerformerDelete = await h.delete(
    '/api/collections/performers/records/$performerId',
    token: crew.token,
  );
  a.check(
    'a performer member cannot delete the act (403)',
    crewPerformerDelete.status == 403,
    '$crewPerformerDelete',
  );

  // The owner's own membership row is a `manager`, so the owner must still be
  // able to administer even though they also hold a non-owner-sounding row.
  final ownerRename = await h.patch(
    '/api/collections/venues/records/$venueId',
    {'name': 'Guard Test Hall'},
    token: ownerA.token,
  );
  a.check(
    'the owner still administers their venue after the role filter',
    ownerRename.status == 200,
    '$ownerRename',
  );

  final crewSelfLeave = await h.delete(
    '/api/collections/memberships/records/$crewMembershipId',
    token: crew.token,
  );
  a.check(
    'a member may remove their own membership',
    crewSelfLeave.status == 204,
    '$crewSelfLeave',
  );

  // ------------------------------------------------------- 12. claim (orphans)
  // An entity with no manager — exactly what the seed script and the admin
  // dashboard produce, since the create hook skips superuser callers — used to
  // be unreachable by anybody. `POST /api/agenda/claim` adopts it.
  final orphan = await h.post('/api/collections/venues/records', {
    'name': 'Orphan Hall',
    'address': '3 Test Way',
    'contact': 'orphan@test',
  }, token: superuser);
  a.check(
    'a superuser-created venue exists (the orphan case)',
    orphan.status == 200,
    '$orphan',
  );

  final orphanOwner = await h.get(
    '/api/collections/venues/records/${orphan.id}',
    token: superuser,
  );
  a.check(
    'the orphan really has no creator',
    (orphanOwner.body['createdBy'] ?? '') == '' &&
        orphanOwner.body.containsKey('ownerId') == false,
    '$orphanOwner',
  );

  final orphanRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('targetId="${orphan.id}"')}',
    token: superuser,
  );
  a.check(
    'the orphan really has no membership rows',
    _items(orphanRows).isEmpty,
    '$orphanRows',
  );

  // Nobody can administer it before the claim.
  final orphanBefore = await h.patch(
    '/api/collections/venues/records/${orphan.id}',
    {'name': 'Mine now'},
    token: outsider.token,
  );
  a.check(
    'an unmanaged entity cannot be edited by a stranger (403)',
    orphanBefore.status == 403,
    '$orphanBefore',
  );

  final badType = await h.post('/api/agenda/claim', {
    'targetType': 'spaceship',
    'targetId': orphan.id,
  }, token: outsider.token);
  a.check(
    'claim rejects an unknown targetType (400)',
    badType.status == 400,
    '$badType',
  );

  final missingTarget = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': 'doesnotexist1234',
  }, token: outsider.token);
  a.check(
    'claim rejects an unknown target (404)',
    missingTarget.status == 404,
    '$missingTarget',
  );

  final anonClaim = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': orphan.id,
  });
  a.check(
    'claim requires authentication (401)',
    anonClaim.status == 401,
    '$anonClaim',
  );

  final claim = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': orphan.id,
  }, token: outsider.token);
  a.check('an unmanaged entity can be claimed', claim.status == 200, '$claim');
  a.check(
    'the claim reports itself as claimed',
    claim.body['status'] == 'claimed',
    '$claim',
  );

  final claimAgain = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': orphan.id,
  }, token: outsider.token);
  a.check(
    'a repeated claim is idempotent, not a second manager row',
    claimAgain.status == 200 && claimAgain.body['status'] == 'already',
    '$claimAgain',
  );

  final orphanRowsAfter = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('targetId="${orphan.id}" && role="manager"')}',
    token: superuser,
  );
  a.check(
    'exactly one manager row exists after two claims',
    _items(orphanRowsAfter).length == 1,
    '$orphanRowsAfter',
  );
  a.check(
    'the manager row names the claimer',
    _items(orphanRowsAfter).first['userId'] == outsider.id,
    '$orphanRowsAfter',
  );

  // The point of the whole exercise: the claimer can now administer it.
  final orphanAfter = await h.patch(
    '/api/collections/venues/records/${orphan.id}',
    {'name': 'Claimed Hall'},
    token: outsider.token,
  );
  a.check(
    'after claiming, the claimer can edit the entity',
    orphanAfter.status == 200,
    '$orphanAfter',
  );

  final orphanEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Claimed venue booking',
      start: DateTime.utc(2026, 4, 2, 19),
      end: DateTime.utc(2026, 4, 2, 20),
      venueId: orphan.id,
    ),
    token: outsider.token,
  );
  a.check(
    'after claiming, the claimer can book the entity',
    orphanEvent.status == 200,
    '$orphanEvent',
  );

  // ...and somebody else cannot take it from them.
  final steal = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': orphan.id,
  }, token: crew.token);
  a.check(
    'a managed entity cannot be claimed by a stranger (409)',
    steal.status == 409,
    '$steal',
  );

  final claimerRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=${orphan.id}',
    token: outsider.token,
  );
  a.check(
    'the claimer can read the roster of the entity they claimed',
    claimerRoster.status == 200 && _items(claimerRoster).length == 1,
    '$claimerRoster',
  );

  // ------------------------------- 14. ensemble collisions (shared performers)
  //
  // A booking conflicts with another not only when it names the same act, but
  // when the two acts share a person: the whole point is that a solo booking for
  // Thom Yorke cannot sit on top of a Radiohead slot. "Who plays in what" is
  // derived from the roster (a performer's active members ARE the people in the
  // act), so these assertions exist to pin BOTH directions of the rule — the
  // collision it must catch and, just as importantly, the legitimate bookings it
  // must NOT refuse.
  //
  // Driven by the superuser: it bypasses the ownership check while the overlap
  // check still runs for it, so a result here is about the collision rule and
  // never about authorization.
  {
    final band = await h.post('/api/collections/performers/records', {
      'name': 'Collision Band',
      'type': 'band',
      'contact': 'band@ensemble.test',
    }, token: superuser);
    final solo = await h.post('/api/collections/performers/records', {
      'name': 'Collision Solo',
      'type': 'solo',
      'contact': 'solo@ensemble.test',
    }, token: superuser);
    final unrelated = await h.post('/api/collections/performers/records', {
      'name': 'Collision Unrelated',
      'type': 'band',
      'contact': 'other@ensemble.test',
    }, token: superuser);
    final pendingOnly = await h.post('/api/collections/performers/records', {
      'name': 'Collision Pending',
      'type': 'solo',
      'contact': 'pending@ensemble.test',
    }, token: superuser);
    a.check(
      'ensemble fixtures exist',
      [band, solo, unrelated, pendingOnly].every((r) => r.status == 200),
      '$band $solo $unrelated $pendingOnly',
    );

    // One person in both acts. Written directly, because the invite route would
    // require the invitee to accept before the link became active — which is the
    // very distinction the last assertion below pins.
    final shared = await _signup(h, 'shared.musician@agenda.test');

    Future<PbResponse> join(String performerId, String userId, String status) =>
        h.post('/api/collections/memberships/records', {
          'userId': userId,
          'targetId': performerId,
          'targetType': 'performer',
          'role': 'member',
          'status': status,
          'initiatedBy': 'invite',
        }, token: superuser);

    a.check(
      'an ACTIVE membership links the person to the band',
      (await join(band.id, shared.id, 'active')).status == 200,
    );
    a.check(
      'the same person is an ACTIVE member of the solo act',
      (await join(solo.id, shared.id, 'active')).status == 200,
    );
    // A different person, in an act unrelated to the band.
    final otherPerson = await _signup(h, 'other.musician@agenda.test');
    a.check(
      'an unrelated act has its own separate member',
      (await join(unrelated.id, otherPerson.id, 'active')).status == 200,
    );
    // A PENDING row must not create a link, or an unanswered invite would
    // invent a collision between two acts.
    a.check(
      'a PENDING membership is recorded for the pending-only act',
      (await join(pendingOnly.id, shared.id, 'pending')).status == 200,
    );

    final night = DateTime.utc(2030, 3, 1, 19);
    final overlapStart = DateTime.utc(2030, 3, 1, 20);
    final overlapEnd = DateTime.utc(2030, 3, 1, 21);

    final bandBooking = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Band night',
        start: night,
        end: night.add(const Duration(hours: 3)),
        performers: [band.id],
      ),
      token: superuser,
    );
    a.check(
      'the band books its night',
      bandBooking.status == 200,
      '$bandBooking',
    );

    final soloClash = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Solo clash',
        start: overlapStart,
        end: overlapEnd,
        performers: [solo.id],
      ),
      token: superuser,
    );
    a.check(
      'a SOLO booking overlapping the band it shares a member with is refused (400)',
      soloClash.status == 400 &&
          soloClash.message.contains('Schedule conflict'),
      '$soloClash',
    );
    a.check(
      'the refusal names the act and the person who links them',
      soloClash.message.contains('Collision Band') &&
          soloClash.message.contains('Collision Solo'),
      '$soloClash',
    );

    final sameAct = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Band clash',
        start: overlapStart,
        end: overlapEnd,
        performers: [band.id],
      ),
      token: superuser,
    );
    a.check(
      'the same act booked twice is still refused (400)',
      sameAct.status == 400 &&
          sameAct.message.contains('performer already booked'),
      '$sameAct',
    );

    // --- the cases that must still be allowed ---
    final soloLater = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Solo later',
        start: DateTime.utc(2030, 3, 1, 23),
        end: DateTime.utc(2030, 3, 1, 23, 59),
        performers: [solo.id],
      ),
      token: superuser,
    );
    a.check(
      'the solo act is fine in a non-overlapping slot',
      soloLater.status == 200,
      '$soloLater',
    );

    final unrelatedSameHour = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Unrelated',
        start: overlapStart,
        end: overlapEnd,
        performers: [unrelated.id],
      ),
      token: superuser,
    );
    a.check(
      'an act sharing nobody is NOT refused at the same hour',
      unrelatedSameHour.status == 200,
      '$unrelatedSameHour',
    );

    final coBilled = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Co-billed',
        start: DateTime.utc(2030, 3, 2, 19),
        end: DateTime.utc(2030, 3, 2, 22),
        performers: [band.id, solo.id],
      ),
      token: superuser,
    );
    a.check(
      'billing the band AND the solo act on ONE event is allowed',
      coBilled.status == 200,
      '$coBilled',
    );

    // The link must work from either side, not just solo-against-band.
    final soloVsCoBilled = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Solo vs co-billed',
        start: DateTime.utc(2030, 3, 2, 20),
        end: DateTime.utc(2030, 3, 2, 21),
        performers: [solo.id],
      ),
      token: superuser,
    );
    a.check(
      'the co-billed night blocks that act again (400)',
      soloVsCoBilled.status == 400,
      '$soloVsCoBilled',
    );

    // A pending invitation is not a person in the act.
    final pendingClash = await h.post(
      '/api/collections/events/records',
      eventPayload(
        title: 'Pending only',
        start: overlapStart,
        end: overlapEnd,
        performers: [pendingOnly.id],
      ),
      token: superuser,
    );
    a.check(
      'a PENDING membership does not create a collision',
      pendingClash.status == 200,
      '$pendingClash',
    );

    // Editing the band's booking to add the solo act is the same event, so it
    // must be accepted rather than colliding with itself.
    final selfEdit = await h.patch(
      '/api/collections/events/records/${bandBooking.id}',
      {
        'performers': [band.id, solo.id],
        'start': night.toIso8601String(),
        'end': night.add(const Duration(hours: 3)).toIso8601String(),
      },
      token: superuser,
    );
    a.check(
      'adding a co-billed act to an existing booking is allowed',
      selfEdit.status == 200,
      '$selfEdit',
    );
  }

  // --------------------------- 13. Phase 2: roster, role gates, re-pointing
  //
  // `createdBy` is provenance from here on; an active manager membership is the
  // only thing that administers an entity, and the roster is the only way to
  // read the team (the collection rule is self-only now).
  final plain = await _signup(h, 'plain.member@agenda.test');
  final second = await _signup(h, 'second.manager@agenda.test');

  final plainAdded = await h.post('/api/collections/memberships/records', {
    'userId': plain.id,
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'status': 'active',
  }, token: ownerA.token);
  a.check(
    'a manager can add a plain member',
    plainAdded.status == 200,
    '$plainAdded',
  );

  final unansweredInvite = await h
      .post('/api/collections/memberships/records', {
        'targetId': venueId,
        'targetType': 'venue',
        'role': 'manager',
        'pendingEmail': 'unanswered@agenda.test',
      }, token: ownerA.token);
  a.check(
    'a manager can leave an invitation unanswered',
    unansweredInvite.status == 200 &&
        unansweredInvite.body['status'] == 'pending',
    '$unansweredInvite',
  );

  final plainRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: plain.token,
  );
  a.check(
    'a plain member gets 403 from the roster',
    plainRoster.status == 403,
    '$plainRoster',
  );

  final outsiderRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: outsider.token,
  );
  a.check(
    'a non-manager gets 403 from the roster',
    outsiderRoster.status == 403,
    '$outsiderRoster',
  );

  final anonRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
  );
  a.check(
    'the roster requires authentication (401)',
    anonRoster.status == 401,
    '$anonRoster',
  );

  final badRosterType = await h.get(
    '/api/agenda/roster?targetType=spaceship&targetId=$venueId',
    token: ownerA.token,
  );
  a.check(
    'the roster rejects an unknown targetType (400)',
    badRosterType.status == 400,
    '$badRosterType',
  );

  final unknownRosterTarget = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=doesnotexist1234',
    token: ownerA.token,
  );
  a.check(
    'the roster answers 404 for an unknown target',
    unknownRosterTarget.status == 404,
    '$unknownRosterTarget',
  );

  final ownerRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: ownerA.token,
  );
  final rosterItems = _items(ownerRoster);
  a.check(
    'a manager can read the roster',
    ownerRoster.status == 200,
    '$ownerRoster',
  );
  // Five rows on V1 by this point: ownerA (manager, active), the accepted
  // invitee (manager, active), the plain member (member, active), the
  // unanswered invitation (manager, pending), and the re-invite to the decliner
  // — whose address HAS an account, so its `userId` is resolved while its
  // status stays pending (member, pending).
  a.check(
    'the roster lists every row of the target, active and pending',
    rosterItems.length == 5,
    '$ownerRoster',
  );
  a.check(
    'the roster sorts active rows before pending ones',
    rosterItems.take(3).every((row) => row['status'] == 'active') &&
        rosterItems.skip(3).every((row) => row['status'] == 'pending'),
    '$ownerRoster',
  );
  a.check(
    'the roster sorts managers before plain members',
    rosterItems.length == 5 &&
        rosterItems[0]['role'] == 'manager' &&
        rosterItems[1]['role'] == 'manager' &&
        rosterItems[2]['role'] == 'member' &&
        rosterItems[3]['role'] == 'manager' &&
        rosterItems[4]['role'] == 'member',
    '$ownerRoster',
  );
  a.check(
    'the roster sorts by name inside a group',
    rosterItems.length == 5 &&
        rosterItems[0]['name'] == 'Invitee' &&
        rosterItems[1]['name'] == 'owner.a',
    '$ownerRoster',
  );

  Map<String, dynamic> rosterRow(String userId) => rosterItems.firstWhere(
    (row) => row['userId'] == userId,
    orElse: () => <String, dynamic>{},
  );

  final ownerRow = rosterRow(ownerA.id);
  a.check(
    "the roster resolves an account's name and email",
    ownerRow['name'] == 'owner.a' && ownerRow['email'] == 'owner.a@agenda.test',
    '$ownerRoster',
  );
  a.check(
    'the roster marks the caller own row with isSelf',
    ownerRow['isSelf'] == true && rosterRow(plain.id)['isSelf'] == false,
    '$ownerRoster',
  );
  final unresolvedRow = rosterItems.firstWhere(
    (row) => row['email'] == 'unanswered@agenda.test',
    orElse: () => <String, dynamic>{},
  );
  a.check(
    'the roster resolves an unanswered invitation from its address alone',
    unresolvedRow['userId'] == '' &&
        unresolvedRow['name'] == '' &&
        unresolvedRow['role'] == 'manager' &&
        unresolvedRow['status'] == 'pending' &&
        unresolvedRow['initiatedBy'] == 'invite',
    '$ownerRoster',
  );
  final resolvedPendingRow = rosterItems.firstWhere(
    (row) => row['email'] == 'decliner@agenda.test',
    orElse: () => <String, dynamic>{},
  );
  a.check(
    'an invitation to an existing account shows that name and stays pending',
    resolvedPendingRow['userId'] != '' &&
        resolvedPendingRow['name'] == 'Decliner' &&
        resolvedPendingRow['status'] == 'pending',
    '$ownerRoster',
  );

  final superRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: superuser,
  );
  a.check(
    'a superuser reads the roster without holding any membership',
    superRoster.status == 200 && _items(superRoster).length == 5,
    '$superRoster',
  );

  final performerRoster = await h.get(
    '/api/agenda/roster?targetType=performer&targetId=$performerId',
    token: ownerC.token,
  );
  a.check(
    'the roster works for a performer too',
    performerRoster.status == 200 && _items(performerRoster).isNotEmpty,
    '$performerRoster',
  );
  // Roster rows are parsed by `Membership.fromMap` in the client, which defaults
  // a missing `targetType` to `venue` — so a performer roster must carry its own
  // identity or every row arrives mis-typed.
  final performerRosterRow = _items(performerRoster).isEmpty
      ? <String, dynamic>{}
      : _items(performerRoster).first;
  a.check(
    'a roster row carries the target identity the client model reads',
    performerRosterRow['targetType'] == 'performer' &&
        performerRosterRow['targetId'] == performerId,
    '$performerRoster',
  );

  // ------------------------------------------- 13b. the re-pointing hole
  // A venue managed by crew, so ownerA (a manager of a DIFFERENT venue) has a
  // row they must not be able to touch.
  final venueB = await h.post('/api/collections/venues/records', {
    'name': 'Second Hall',
    'address': '5 Test Way',
    'contact': 'b@test',
  }, token: crew.token);
  a.check(
    'the crew member can create their own venue',
    venueB.status == 200,
    '$venueB',
  );
  final venueBId = venueB.id;

  final crewBRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('userId="${crew.id}" && targetId="$venueBId"')}',
    token: superuser,
  );
  final crewBItems = _items(crewBRows);
  final crewBMembershipId = crewBItems.isEmpty
      ? ''
      : '${crewBItems.first['id']}';
  a.check(
    'creating a venue makes the creator its active manager',
    crewBItems.length == 1 &&
        crewBItems.first['role'] == 'manager' &&
        crewBItems.first['status'] == 'active',
    '$crewBRows',
  );

  // Before the freeze, supplying `targetId` WAS the permission: the check ran
  // `canAdminister` against the request's target, so a manager of venue A could
  // re-point a row belonging to venue B at A and keep B's `userId`.
  final repoint = await h.patch(
    '/api/collections/memberships/records/$crewBMembershipId',
    {'targetId': venueId, 'targetType': 'venue', 'role': 'member'},
    token: ownerA.token,
  );
  a.check(
    'a manager of another venue cannot re-point a membership (403)',
    repoint.status == 403,
    '$repoint',
  );

  final repointAfter = await h.get(
    '/api/collections/memberships/records/$crewBMembershipId',
    token: superuser,
  );
  a.check(
    'the refused re-point left the row on its original venue',
    repointAfter.body['targetId'] == venueBId &&
        repointAfter.body['userId'] == crew.id &&
        repointAfter.body['role'] == 'manager',
    '$repointAfter',
  );

  final selfRewrite = await h
      .patch('/api/collections/memberships/records/$crewBMembershipId', {
        'userId': plain.id,
        'targetId': venueId,
        'targetType': 'venue',
        'pendingEmail': 'stolen@agenda.test',
      }, token: crew.token);
  a.check(
    'a manager may still update their own membership row',
    selfRewrite.status == 200,
    '$selfRewrite',
  );
  a.check(
    'the identity fields of a membership are frozen on update',
    selfRewrite.body['userId'] == crew.id &&
        selfRewrite.body['targetId'] == venueBId &&
        selfRewrite.body['targetType'] == 'venue' &&
        '${selfRewrite.body['pendingEmail']}' == '',
    '$selfRewrite',
  );

  // ------------------------------------------ 13c. the last-manager fence
  final demoteLast = await h.patch(
    '/api/collections/memberships/records/$crewBMembershipId',
    {'role': 'member'},
    token: crew.token,
  );
  a.check(
    'the last manager of an entity cannot be demoted (400)',
    demoteLast.status == 400 && demoteLast.message.contains('last manager'),
    '$demoteLast',
  );

  final pendingLast = await h.patch(
    '/api/collections/memberships/records/$crewBMembershipId',
    {'status': 'pending'},
    token: crew.token,
  );
  a.check(
    'the last manager cannot be set back to pending (400)',
    pendingLast.status == 400 && pendingLast.message.contains('last manager'),
    '$pendingLast',
  );

  final leaveLast = await h.delete(
    '/api/collections/memberships/records/$crewBMembershipId',
    token: crew.token,
  );
  a.check(
    'the last manager cannot remove themselves (400)',
    leaveLast.status == 400 && leaveLast.message.contains('last manager'),
    '$leaveLast',
  );

  final secondAdded = await h.post('/api/collections/memberships/records', {
    'userId': second.id,
    'targetId': venueBId,
    'targetType': 'venue',
    'role': 'manager',
    'status': 'active',
  }, token: crew.token);
  a.check(
    'a second manager can be added',
    secondAdded.status == 200,
    '$secondAdded',
  );

  final demoteNow = await h.patch(
    '/api/collections/memberships/records/$crewBMembershipId',
    {'role': 'member'},
    token: crew.token,
  );
  a.check(
    'with another manager present the previous manager may step down',
    demoteNow.status == 200 && demoteNow.body['role'] == 'member',
    '$demoteNow',
  );

  final memberRemovesManager = await h.delete(
    '/api/collections/memberships/records/${secondAdded.id}',
    token: crew.token,
  );
  a.check(
    'a stepped-down member cannot remove the manager (403)',
    memberRemovesManager.status == 403,
    '$memberRemovesManager',
  );

  final lastManagerLeaves = await h.delete(
    '/api/collections/memberships/records/${secondAdded.id}',
    token: second.token,
  );
  a.check(
    'the last remaining manager still cannot remove themselves (400)',
    lastManagerLeaves.status == 400 &&
        lastManagerLeaves.message.contains('last manager'),
    '$lastManagerLeaves',
  );

  // ------------------------------- 13d. provenance is not authorization
  final provenanceOnly = await h.post('/api/collections/venues/records', {
    'name': 'Provenance Hall',
    'address': '7 Test Way',
    'contact': 'prov@test',
  }, token: superuser);
  final attributed = await h.send(
    'PATCH',
    '/api/collections/venues/records/${provenanceOnly.id}',
    token: superuser,
    body: {'createdBy': outsider.id},
  );
  a.check(
    'a superuser can record a creator on a managerless venue',
    attributed.status == 200 && attributed.body['createdBy'] == outsider.id,
    '$attributed',
  );

  final byProvenance = await h.patch(
    '/api/collections/venues/records/${provenanceOnly.id}',
    {'name': 'Mine by provenance'},
    token: outsider.token,
  );
  a.check(
    'being the creator no longer grants administration (403)',
    byProvenance.status == 403,
    '$byProvenance',
  );

  final provenanceRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=${provenanceOnly.id}',
    token: outsider.token,
  );
  a.check(
    'being the creator does not grant roster access either (403)',
    provenanceRoster.status == 403,
    '$provenanceRoster',
  );

  final forgedProvenance = await h.patch(
    '/api/collections/venues/records/$venueId',
    {'createdBy': outsider.id},
    token: ownerA.token,
  );
  a.check(
    'createdBy is not client-writable on update',
    forgedProvenance.status == 200 &&
        forgedProvenance.body['createdBy'] == ownerA.id,
    '$forgedProvenance',
  );

  final initiatedByForged = await h
      .post('/api/collections/memberships/records', {
        'targetId': venueId,
        'targetType': 'venue',
        'role': 'member',
        'pendingEmail': 'forged-direction@agenda.test',
        'initiatedBy': 'request',
      }, token: ownerA.token);
  a.check(
    'a client cannot claim the invitation came from the invitee',
    initiatedByForged.status == 200 &&
        initiatedByForged.body['initiatedBy'] == 'invite',
    '$initiatedByForged',
  );

  // ---------- 14. Phase 3: join requests, approval and the invite hint
  //
  // A membership is a QUESTION until a manager of its target answers it, and
  // either side can ask: a manager naming an address is `initiatedBy: "invite"`,
  // the person asking for access is `initiatedBy: "request"`. Everything below
  // is the second direction and the two things that must never fall out of it —
  // a pending request granting anything, and the requester waving themselves in.
  final seeker = await _signup(h, 'seeker@agenda.test'); // manages nothing
  final rejectee = await _signup(h, 'rejectee@agenda.test'); // manages nothing

  final anonJoin = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  });
  a.check(
    'join requires authentication (401)',
    anonJoin.status == 401,
    '$anonJoin',
  );

  final badJoinType = await h.post('/api/agenda/join', {
    'targetType': 'spaceship',
    'targetId': venueId,
  }, token: seeker.token);
  a.check(
    'join rejects an unknown targetType (400)',
    badJoinType.status == 400 &&
        badJoinType.message.toLowerCase().contains('targettype'),
    '$badJoinType',
  );

  final missingJoinTarget = await h.post('/api/agenda/join', {
    'targetType': 'venue',
  }, token: seeker.token);
  a.check(
    'join rejects a missing targetId (400)',
    missingJoinTarget.status == 400 &&
        missingJoinTarget.message.toLowerCase().contains('targetid'),
    '$missingJoinTarget',
  );

  final unknownJoinTarget = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': 'doesnotexist1234',
  }, token: seeker.token);
  a.check(
    'join answers 404 for an unknown target',
    unknownJoinTarget.status == 404,
    '$unknownJoinTarget',
  );

  // The four refusals are 400s with four DIFFERENT sentences, because the UI
  // shows the server's own wording next to the button that was just pressed.
  // None of them is a 409, and none of them is a row.
  final badRole = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
    'role': 'owner',
  }, token: seeker.token);
  a.check(
    'join refuses a role it does not know (400)',
    badRole.status == 400 &&
        badRole.message.toLowerCase().contains('role must be'),
    '$badRole',
  );

  final alreadyMember = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: plain.token);
  a.check(
    'joining an entity you are already an active member of is a 400 of its own',
    alreadyMember.status == 400 &&
        alreadyMember.message.contains('already a member'),
    '$alreadyMember',
  );

  final alreadyManager = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: ownerA.token);
  a.check(
    'joining an entity you already manage is a 400 of its own',
    alreadyManager.status == 400 &&
        alreadyManager.message.contains('You already manage'),
    '$alreadyManager',
  );

  // Not one of the four the contract names, and it cannot be folded into one: an
  // unanswered INVITATION is neither an active row, nor the caller's own
  // request, nor management of the entity — and the row the caller already
  // holds IS the invitation, so writing a second one for the same (user, target)
  // pair would list them twice on the roster.
  final alreadyInvited = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: declinerToken);
  a.check(
    'joining while your own invitation is unanswered is refused, as its own 400',
    alreadyInvited.status == 400 &&
        alreadyInvited.message.contains('already have an invitation'),
    '$alreadyInvited',
  );

  // ------------------------------------------------------- the request itself
  final join = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: seeker.token);
  a.check(
    'a non-manager can ask to join (200 requested)',
    join.status == 200 && join.body['status'] == 'requested',
    '$join',
  );
  final seekerRequestId = '${join.body['membershipId'] ?? ''}';
  a.check(
    'the request answers with the row it wrote',
    seekerRequestId.isNotEmpty,
    '$join',
  );

  final seekerRow = await h.get(
    '/api/collections/memberships/records/$seekerRequestId',
    token: superuser,
  );
  a.check(
    'a request is written pending and request-initiated',
    seekerRow.body['status'] == 'pending' &&
        seekerRow.body['initiatedBy'] == 'request' &&
        seekerRow.body['userId'] == seeker.id &&
        seekerRow.body['targetId'] == venueId &&
        seekerRow.body['targetType'] == 'venue' &&
        seekerRow.body['role'] == 'member' &&
        '${seekerRow.body['pendingEmail']}' == '',
    '$seekerRow',
  );

  final duplicate = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: seeker.token);
  a.check(
    'a duplicate request while one is pending is refused, as its own 400',
    duplicate.status == 400 &&
        duplicate.message.contains('already waiting for approval'),
    '$duplicate',
  );

  // --------------------------------- the manager-side aggregate (dashboard)
  // `memberships.listRule` is self-only and the roster answers one target at a
  // time, so this route is the only way a dashboard can ask "what is waiting for
  // me?" without a call per entity. It must show a request to the manager who
  // can answer it, show nothing else, and answer an empty list — not a 403 — to
  // the (common) account that manages nothing.
  final latecomer = await _signup(h, 'latecomer@agenda.test');
  final latecomerJoin = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: latecomer.token);
  a.check(
    'a second requester can ask to join the same venue (fixture)',
    latecomerJoin.status == 200,
    '$latecomerJoin',
  );
  final latecomerRequestId = '${latecomerJoin.body['membershipId'] ?? ''}';

  final requestsForOwner = await h.get(
    '/api/agenda/requests',
    token: ownerA.token,
  );
  final ownerRequestItems = _items(requestsForOwner);
  a.check(
    'a manager sees the pending join requests for their entity',
    requestsForOwner.status == 200 &&
        ownerRequestItems.length == 2 &&
        ownerRequestItems.any((row) => row['userId'] == seeker.id) &&
        ownerRequestItems.any((row) => row['userId'] == latecomer.id),
    '$requestsForOwner',
  );
  a.check(
    'an unanswered INVITATION is not an incoming request',
    ownerRequestItems.every((row) => row['initiatedBy'] == 'request'),
    '$requestsForOwner',
  );
  a.check(
    'the request rows carry the entity they are for',
    ownerRequestItems.every(
      (row) =>
          row['targetId'] == venueId &&
          row['targetType'] == 'venue' &&
          row['status'] == 'pending' &&
          row['role'] == 'member' &&
          row['isSelf'] == false &&
          row['requestedByMe'] == false,
    ),
    '$requestsForOwner',
  );
  final latecomerRow = await h.get(
    '/api/collections/memberships/records/$latecomerRequestId',
    token: superuser,
  );
  final seekerCreated = '${seekerRow.body['created']}';
  final latecomerCreated = '${latecomerRow.body['created']}';
  // `created` is `YYYY-MM-DD HH:MM:SS.sssZ`, which compares chronologically as
  // text. The two requests can land in the same millisecond, and then the order
  // is legitimately either way — so the assertion names the newer row only when
  // the clock actually distinguished them.
  final newestRequestId = latecomerCreated.compareTo(seekerCreated) == 0
      ? ''
      : (latecomerCreated.compareTo(seekerCreated) > 0
            ? latecomer.id
            : seeker.id);
  a.check(
    'the newest request is listed first',
    newestRequestId.isEmpty ||
        ownerRequestItems.first['userId'] == newestRequestId,
    'created: $seekerCreated / $latecomerCreated — $requestsForOwner',
  );

  final requestsForSeeker = await h.get(
    '/api/agenda/requests',
    token: seeker.token,
  );
  a.check(
    'a requester who manages nothing gets an empty list, not a 403',
    requestsForSeeker.status == 200 && _items(requestsForSeeker).isEmpty,
    '$requestsForSeeker',
  );

  final requestsForCrew = await h.get(
    '/api/agenda/requests',
    token: crew.token,
  );
  a.check(
    'a user who manages nothing gets 200 with an empty list, not 403',
    requestsForCrew.status == 200 &&
        _items(requestsForCrew).isEmpty &&
        requestsForCrew.message.isEmpty,
    '$requestsForCrew',
  );

  final requestsForOtherType = await h.get(
    '/api/agenda/requests',
    token: ownerC.token,
  );
  a.check(
    'a manager of a DIFFERENT entity sees none of these requests',
    requestsForOtherType.status == 200 && _items(requestsForOtherType).isEmpty,
    '$requestsForOtherType',
  );

  final requestsForSuperuser = await h.send(
    'GET',
    '/api/agenda/requests',
    token: superuser,
  );
  a.check(
    'a superuser sees pending requests across entities',
    requestsForSuperuser.status == 200 &&
        _items(requestsForSuperuser).any((row) => row['userId'] == seeker.id),
    '$requestsForSuperuser',
  );

  final anonRequests = await h.get('/api/agenda/requests');
  a.check(
    'the request list requires authentication (401)',
    anonRequests.status == 401,
    '$anonRequests',
  );

  // ------------------------------------------ a pending request grants nothing
  final pendingRequestEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Seeker books before approval',
      start: DateTime.utc(2026, 6, 1, 19),
      end: DateTime.utc(2026, 6, 1, 20),
      venueId: venueId,
    ),
    token: seeker.token,
  );
  a.check(
    'a PENDING join request grants no event access (403)',
    pendingRequestEvent.status == 403,
    '$pendingRequestEvent',
  );

  final pendingRequestRename = await h.patch(
    '/api/collections/venues/records/$venueId',
    {'name': 'Seeker Hall'},
    token: seeker.token,
  );
  a.check(
    'a PENDING join request grants no admin rights (403)',
    pendingRequestRename.status == 403,
    '$pendingRequestRename',
  );

  final pendingRequestRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: seeker.token,
  );
  a.check(
    'a PENDING join request does not open the roster (403)',
    pendingRequestRoster.status == 403,
    '$pendingRequestRoster',
  );

  // ------------------------------------------ nobody approves their own request
  final selfApprove = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'approve',
  }, token: seeker.token);
  a.check(
    'a requester cannot approve their own request (403)',
    selfApprove.status == 403,
    '$selfApprove',
  );

  final stillPending = await h.get(
    '/api/collections/memberships/records/$seekerRequestId',
    token: superuser,
  );
  a.check(
    'the refused self-approval left the request pending',
    stillPending.body['status'] == 'pending',
    '$stillPending',
  );

  // `crew` is a plain member of another venue (and was demoted from manager
  // earlier in this run): belonging to an entity is not managing it.
  final strangerDecide = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'approve',
  }, token: crew.token);
  a.check(
    'a user who manages nothing cannot decide on a request (403)',
    strangerDecide.status == 403,
    '$strangerDecide',
  );

  final anonDecide = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'approve',
  });
  a.check(
    'decide requires authentication (401)',
    anonDecide.status == 401,
    '$anonDecide',
  );

  final missingDecide = await h.post('/api/agenda/roster/decide', {
    'membershipId': 'doesnotexist1234',
    'action': 'approve',
  }, token: ownerA.token);
  a.check(
    'deciding on a membership that does not exist is a 404',
    missingDecide.status == 404,
    '$missingDecide',
  );

  final badDecideAction = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'maybe',
  }, token: ownerA.token);
  a.check(
    'an unknown decide action is refused (400)',
    badDecideAction.status == 400 &&
        badDecideAction.message.contains("'approve' or 'reject'"),
    '$badDecideAction',
  );

  // The manager's roster is where a request becomes visible, and the caller's
  // own rows are told apart from it: `isSelf` is false here because the row is
  // somebody else's, and `requestedByMe` is false for the same reason.
  final requestRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueId',
    token: ownerA.token,
  );
  final rosterRequestRow = _items(requestRoster).firstWhere(
    (row) => row['userId'] == seeker.id,
    orElse: () => <String, dynamic>{},
  );
  a.check(
    'the roster shows somebody else pending request as their row, not mine',
    rosterRequestRow['status'] == 'pending' &&
        rosterRequestRow['initiatedBy'] == 'request' &&
        rosterRequestRow['role'] == 'member' &&
        rosterRequestRow['isSelf'] == false &&
        rosterRequestRow['requestedByMe'] == false,
    '$requestRoster',
  );

  // ------------------------------------------------- approve: access appears
  final approve = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'approve',
  }, token: ownerA.token);
  a.check(
    'a manager can approve a request (200 active)',
    approve.status == 200 && approve.body['status'] == 'active',
    '$approve',
  );

  final approvedRow = await h.get(
    '/api/collections/memberships/records/$seekerRequestId',
    token: superuser,
  );
  a.check(
    'approving activates the row and keeps the requested role',
    approvedRow.body['status'] == 'active' &&
        approvedRow.body['role'] == 'member' &&
        approvedRow.body['initiatedBy'] == 'request',
    '$approvedRow',
  );

  final afterApprovalEvent = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Seeker books after approval',
      start: DateTime.utc(2026, 6, 1, 19),
      end: DateTime.utc(2026, 6, 1, 20),
      venueId: venueId,
    ),
    token: seeker.token,
  );
  a.check(
    'after approval the requester can book the venue',
    afterApprovalEvent.status == 200,
    '$afterApprovalEvent',
  );

  final approvedRename = await h.patch(
    '/api/collections/venues/records/$venueId',
    {'name': 'Seeker Hall'},
    token: seeker.token,
  );
  a.check(
    'approval grants booking, not administration (403)',
    approvedRename.status == 403,
    '$approvedRename',
  );

  final approveAgain = await h.post('/api/agenda/roster/decide', {
    'membershipId': seekerRequestId,
    'action': 'approve',
  }, token: ownerA.token);
  a.check(
    'deciding on a row that is no longer pending is refused (400)',
    approveAgain.status == 400 &&
        approveAgain.message.contains('not waiting for approval'),
    '$approveAgain',
  );

  // ----------------------------------- reject: the row goes, the door does not
  final rejecteeJoin = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
    'role': 'manager',
  }, token: rejectee.token);
  a.check(
    'a request may ask for the manager role (200)',
    rejecteeJoin.status == 200 && rejecteeJoin.body['status'] == 'requested',
    '$rejecteeJoin',
  );
  final rejecteeRequestId = '${rejecteeJoin.body['membershipId'] ?? ''}';

  final reject = await h.post('/api/agenda/roster/decide', {
    'membershipId': rejecteeRequestId,
    'action': 'reject',
  }, token: ownerA.token);
  a.check(
    'a manager can reject a request (200 rejected)',
    reject.status == 200 && reject.body['status'] == 'rejected',
    '$reject',
  );

  final rejectedGone = await h.get(
    '/api/collections/memberships/records/$rejecteeRequestId',
    token: superuser,
  );
  a.check(
    'a rejected request is deleted, not kept',
    rejectedGone.status == 404,
    '$rejectedGone',
  );

  final rejecteeAgain = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
    'role': 'manager',
  }, token: rejectee.token);
  a.check(
    'a rejected request does not block a second one',
    rejecteeAgain.status == 200 &&
        rejecteeAgain.body['membershipId'] != rejecteeRequestId,
    '$rejecteeAgain',
  );

  final requestsAfterApproval = await h.get(
    '/api/agenda/requests',
    token: ownerA.token,
  );
  final afterApprovalItems = _items(requestsAfterApproval);
  a.check(
    'an answered request leaves the incoming list, leaving the unanswered two',
    afterApprovalItems.length == 2 &&
        afterApprovalItems.any((row) => row['userId'] == latecomer.id) &&
        afterApprovalItems.any((row) => row['userId'] == rejectee.id) &&
        afterApprovalItems.every((row) => row['userId'] != seeker.id),
    '$requestsAfterApproval',
  );

  // ... and the list is scoped to the caller's targets, not to every request in
  // the database: `plain` is a member of venueId and belongs to no other entity,
  // so they can ask to join venueB — which `second` manages and `ownerA` does
  // not.
  final plainAsksB = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueBId,
  }, token: plain.token);
  a.check(
    'a member of one venue can ask to join another (fixture)',
    plainAsksB.status == 200,
    '$plainAsksB',
  );

  final requestsForSecond = await h.get(
    '/api/agenda/requests',
    token: second.token,
  );
  a.check(
    'a manager sees the request filed against THEIR entity, and only that',
    requestsForSecond.status == 200 &&
        _items(requestsForSecond).length == 1 &&
        _items(requestsForSecond).first['userId'] == plain.id &&
        _items(requestsForSecond).first['targetId'] == venueBId,
    '$requestsForSecond',
  );

  final ownerAfterPlainAsksB = await h.get(
    '/api/agenda/requests',
    token: ownerA.token,
  );
  a.check(
    "somebody else's request for another venue never appears in mine",
    _items(ownerAfterPlainAsksB).every((row) => row['targetId'] == venueId),
    '$ownerAfterPlainAsksB',
  );

  // Filing a request does not turn a caller into a manager: `plain` manages
  // nothing, so their own list stays empty even with a request to their name.
  final requestsForPlain = await h.get(
    '/api/agenda/requests',
    token: plain.token,
  );
  a.check(
    'a requester sees nothing in the incoming list until they manage something',
    requestsForPlain.status == 200 && _items(requestsForPlain).isEmpty,
    '$requestsForPlain',
  );

  // ------------------------- a manager may push an unanswered INVITATION through
  // Deliberate, and deliberately the same route: with no email channel there is
  // no way to remind an invitee who never signs in, so admitting them is the
  // only recovery path. `decide` does not read `initiatedBy` at all — the
  // question it answers is "may this person in?", whoever asked.
  final invitePushed = await h.post('/api/agenda/roster/decide', {
    'membershipId': reinvite.id,
    'action': 'approve',
  }, token: ownerA.token);
  a.check(
    'a manager can approve an unanswered invitation (200 active)',
    invitePushed.status == 200 && invitePushed.body['status'] == 'active',
    '$invitePushed',
  );

  final pushedRow = await h.get(
    '/api/collections/memberships/records/${reinvite.id}',
    token: superuser,
  );
  a.check(
    'approving an invitation leaves it an invitation for the same person',
    pushedRow.body['status'] == 'active' &&
        pushedRow.body['initiatedBy'] == 'invite' &&
        pushedRow.body['userId'] == declinerSignup.id,
    '$pushedRow',
  );

  final declinerBooked = await h.post(
    '/api/collections/events/records',
    eventPayload(
      title: 'Pushed-through invitee books',
      start: DateTime.utc(2026, 6, 2, 19),
      end: DateTime.utc(2026, 6, 2, 20),
      venueId: venueId,
    ),
    token: declinerToken,
  );
  a.check(
    'the invitee admitted by a manager can book',
    declinerBooked.status == 200,
    '$declinerBooked',
  );

  final rejectActive = await h.post('/api/agenda/roster/decide', {
    'membershipId': reinvite.id,
    'action': 'reject',
  }, token: ownerA.token);
  a.check(
    'rejecting an already-active membership is refused (400)',
    rejectActive.status == 400 &&
        rejectActive.message.contains('not waiting for approval'),
    '$rejectActive',
  );

  final afterRejectActive = await h.get(
    '/api/collections/memberships/records/${reinvite.id}',
    token: superuser,
  );
  a.check(
    'the refused rejection did not delete the active row',
    afterRejectActive.status == 200 &&
        afterRejectActive.body['status'] == 'active',
    '$afterRejectActive',
  );

  final declinerJoin = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': venueId,
  }, token: declinerToken);
  a.check(
    'an admitted member asking again is refused as already a member',
    declinerJoin.status == 400 &&
        declinerJoin.message.contains('already a member'),
    '$declinerJoin',
  );

  // ------------------------------------------ `requestedByMe` is not `isSelf`
  // No route can produce a pending REQUEST row for somebody who already manages
  // the target (`join` refuses exactly that, and the collection's create hook
  // forces `initiatedBy: "invite"`), so a manager's own roster never contains
  // one in the app. It is staged here with a superuser — which bypasses the
  // hook — purely to pin the flag: without this, `requestedByMe` could regress
  // to `isSelf` and every other assertion in this file would still pass.
  final stagedRequest = await h.send(
    'POST',
    '/api/collections/memberships/records',
    token: superuser,
    body: {
      'userId': second.id,
      'targetId': venueBId,
      'targetType': 'venue',
      'role': 'manager',
      'status': 'pending',
    },
  );
  final markedRequest = await h.send(
    'PATCH',
    '/api/collections/memberships/records/${stagedRequest.id}',
    token: superuser,
    body: {'initiatedBy': 'request'},
  );
  a.check(
    'the staged pending request row is honoured (fixture)',
    markedRequest.status == 200 &&
        markedRequest.body['initiatedBy'] == 'request',
    '$markedRequest',
  );

  final secondRoster = await h.get(
    '/api/agenda/roster?targetType=venue&targetId=$venueBId',
    token: second.token,
  );
  final secondOwnPending = _items(secondRoster).firstWhere(
    (row) => row['id'] == stagedRequest.id,
    orElse: () => <String, dynamic>{},
  );
  a.check(
    'the roster flags the caller own pending REQUEST with requestedByMe',
    secondOwnPending['status'] == 'pending' &&
        secondOwnPending['initiatedBy'] == 'request' &&
        secondOwnPending['isSelf'] == true &&
        secondOwnPending['requestedByMe'] == true,
    '$secondRoster',
  );

  final secondOwnActive = _items(secondRoster).firstWhere(
    (row) => row['status'] == 'active' && row['isSelf'] == true,
    orElse: () => <String, dynamic>{},
  );
  a.check(
    'an ACTIVE row of the caller is isSelf but never requestedByMe',
    secondOwnActive['requestedByMe'] == false,
    '$secondRoster',
  );

  // ------------------------------------------------- the invite form hint
  final anonLookup = await h.get(
    '/api/agenda/user-lookup?email=plain.member@agenda.test',
  );
  a.check(
    'user-lookup requires authentication (401)',
    anonLookup.status == 401,
    '$anonLookup',
  );

  final crewLookup = await h.get(
    '/api/agenda/user-lookup?email=${Uri.encodeComponent('plain.member@agenda.test')}',
    token: crew.token,
  );
  a.check(
    'user-lookup is 403 for a user who manages nothing',
    crewLookup.status == 403,
    '$crewLookup',
  );

  final managerLookup = await h.get(
    '/api/agenda/user-lookup?email=${Uri.encodeComponent('plain.member@agenda.test')}',
    token: ownerA.token,
  );
  a.check(
    'a manager learns the display name of a registered address',
    managerLookup.status == 200 &&
        managerLookup.body['exists'] == true &&
        managerLookup.body['name'] == 'plain.member',
    '$managerLookup',
  );
  a.check(
    'user-lookup answers with exactly {exists, name}',
    managerLookup.body.keys.length == 2 &&
        managerLookup.body.containsKey('exists') &&
        managerLookup.body.containsKey('name'),
    '$managerLookup',
  );

  final performerManagerLookup = await h.get(
    '/api/agenda/user-lookup?email=${Uri.encodeComponent('plain.member@agenda.test')}',
    token: ownerC.token,
  );
  a.check(
    'managing a performer is enough to use the hint',
    performerManagerLookup.status == 200,
    '$performerManagerLookup',
  );

  final unknownLookup = await h.get(
    '/api/agenda/user-lookup?email=${Uri.encodeComponent('nobody.at.all@agenda.test')}',
    token: ownerA.token,
  );
  a.check(
    'an unregistered address answers exists false with an empty name',
    unknownLookup.status == 200 &&
        unknownLookup.body['exists'] == false &&
        unknownLookup.body['name'] == '',
    '$unknownLookup',
  );

  final malformedLookup = await h.get(
    '/api/agenda/user-lookup?email=not-an-address',
    token: ownerA.token,
  );
  a.check(
    'a malformed address is refused (400)',
    malformedLookup.status == 400 && malformedLookup.message.contains('email'),
    '$malformedLookup',
  );

  final emptyLookup = await h.get(
    '/api/agenda/user-lookup',
    token: ownerA.token,
  );
  a.check(
    'a missing address is refused (400)',
    emptyLookup.status == 400,
    '$emptyLookup',
  );

  final superLookup = await h.send(
    'GET',
    '/api/agenda/user-lookup?email=${Uri.encodeComponent('plain.member@agenda.test')}',
    token: superuser,
  );
  a.check(
    'a superuser may use the hint without holding any membership',
    superLookup.status == 200,
    '$superLookup',
  );

  // ------------------------------------------------------- the inviter
  //
  // `invitedBy` is provenance for the invitation email, and it is provenance in
  // the strict sense: nothing authorizes against it. What must hold is that only
  // the server can set it — a client that could name somebody else as the inviter
  // would be putting words in their mouth, and one that could rewrite it later
  // would make the record meaningless.

  final inviterInvite = await h.post('/api/collections/memberships/records', {
    'pendingEmail': 'inviter.probe@agenda.test',
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'status': 'pending',
    'initiatedBy': 'invite',
  }, token: ownerA.token);
  a.check(
    'a create records the caller as invitedBy',
    inviterInvite.status == 200 && inviterInvite.body['invitedBy'] == ownerA.id,
    'status=${inviterInvite.status} invitedBy=${inviterInvite.body['invitedBy']} expected=${ownerA.id}',
  );

  /// The caller manages the target, so the create is allowed — and it asserts
  /// `invitedBy: <somebody else>`. The guard overwrites it from the authenticated
  /// identity, exactly as it already does for `initiatedBy`, so the stored value
  /// is the truth about who called rather than what they claimed.
  final spoofInvite = await h.post('/api/collections/memberships/records', {
    'pendingEmail': 'inviter.spoof@agenda.test',
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'member',
    'status': 'pending',
    'initiatedBy': 'invite',
    'invitedBy': ownerC.id,
  }, token: ownerA.token);
  a.check(
    'a client cannot name somebody else as the inviter',
    spoofInvite.status == 200 && spoofInvite.body['invitedBy'] == ownerA.id,
    'status=${spoofInvite.status} invitedBy=${spoofInvite.body['invitedBy']} claimed=${ownerC.id} expected=${ownerA.id}',
  );

  /// And a later update cannot rewrite it either: it is in the identity-field set
  /// the update branch copies back from the stored row.
  final inviterRowId = inviterInvite.body['id'];
  final rewriteInvite = await h.patch(
    '/api/collections/memberships/records/$inviterRowId',
    {'invitedBy': ownerC.id, 'role': 'manager'},
    token: ownerA.token,
  );
  a.check(
    'an update cannot rewrite invitedBy',
    rewriteInvite.status == 200 && rewriteInvite.body['invitedBy'] == ownerA.id,
    'status=${rewriteInvite.status} invitedBy=${rewriteInvite.body['invitedBy']} expected=${ownerA.id}',
  );

  // ------------------------------------------------ password recovery
  //
  // The reset flow has two properties worth guarding, and neither is visible
  // from the client: the capability probe has to be reachable with no session
  // (the visitor following a reset link is normally signed out), and neither
  // recovery endpoint may disclose whether an address has an account.

  final anonMailStatus = await h.get('/api/agenda/mail-status');
  a.check(
    'mail-status is reachable with no session, because the reset flow is pre-auth',
    anonMailStatus.status == 200,
    '$anonMailStatus',
  );
  a.check(
    'mail-status answers with exactly {enabled}, one bit and no user data',
    anonMailStatus.body.keys.length == 1 &&
        anonMailStatus.body.containsKey('enabled') &&
        anonMailStatus.body['enabled'] is bool,
    '$anonMailStatus',
  );

  /// 204 for a registered address and for an unknown one alike. This is the
  /// endpoint's whole security property: if the two differed, it would be an
  /// email-enumeration oracle, and the client's "if that address has an account,
  /// a link is on its way" wording would be a lie either way.
  final resetKnown = await h.post(
    '/api/collections/users/request-password-reset',
    {'email': 'plain.member@agenda.test'},
  );
  final resetUnknown = await h.post(
    '/api/collections/users/request-password-reset',
    {'email': 'definitely.no.account@agenda.test'},
  );
  a.check(
    'request-password-reset answers 204 for a registered and an unknown address alike',
    resetKnown.status == 204 && resetUnknown.status == 204,
    'known=$resetKnown unknown=$resetUnknown',
  );
  a.check(
    'request-password-reset discloses nothing in the body',
    resetKnown.raw.body.trim().isEmpty && resetUnknown.raw.body.trim().isEmpty,
    'known="${resetKnown.raw.body}" unknown="${resetUnknown.raw.body}"',
  );

  /// A forged token is refused, and with the field-level message rather than the
  /// envelope one: the client shows the server's own prose, so "Invalid or
  /// expired token." is what the user must see, not "An error occurred while
  /// validating the submitted data."
  final forgedReset = await h
      .post('/api/collections/users/confirm-password-reset', {
        'token': 'not.a.real.token',
        'password': 'irrelevant123',
        'passwordConfirm': 'irrelevant123',
      });
  a.check(
    'confirm-password-reset refuses a forged token (400)',
    forgedReset.status == 400,
    '$forgedReset',
  );

  /// The built-in template links to PocketBase's own dashboard reset page, which
  /// in this deployment falls through the SPA catch-all and renders nothing — a
  /// link that fails only once it reaches the recipient's mail client, where no
  /// test would ever see it. `1790300000_password_reset_link.js` repoints it.
  final usersCollection = await h.get(
    '/api/collections/users',
    token: superuser,
  );
  final resetTemplate =
      (usersCollection.body['resetPasswordTemplate'] as Map?)?['body']
          ?.toString() ??
      '';
  a.check(
    'the reset email links to the app, not the PocketBase dashboard',
    resetTemplate.contains('/#/reset-password?token={TOKEN}') &&
        !resetTemplate.contains('/_/#/auth/confirm-password-reset'),
    resetTemplate.isEmpty ? '(template missing)' : resetTemplate,
  );

  // ---------------------------------------- a direct POST cannot self-grant
  // The collection's create branch authorizes on `canAdminister` BEFORE it looks
  // at `status`, and `canAdminister` accepts nothing less than an active manager
  // row — so "give me an active row on somebody else's venue" is a 403 and
  // writes nothing at all.
  final selfGrant = await h.post('/api/collections/memberships/records', {
    'userId': crew.id,
    'targetId': venueId,
    'targetType': 'venue',
    'role': 'manager',
    'status': 'active',
  }, token: crew.token);
  a.check(
    'a direct membership POST cannot create an ACTIVE row for oneself (403)',
    selfGrant.status == 403,
    '$selfGrant',
  );

  final selfGrantRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('userId="${crew.id}" && targetId="$venueId"')}',
    token: superuser,
  );
  a.check(
    'the refused self-grant wrote no row at all',
    _items(selfGrantRows).isEmpty,
    '$selfGrantRows',
  );

  final selfGrantByEmail = await h
      .post('/api/collections/memberships/records', {
        'pendingEmail': 'crew@agenda.test',
        'targetId': venueId,
        'targetType': 'venue',
        'role': 'manager',
        'status': 'active',
      }, token: crew.token);
  a.check(
    'the same POST addressed to your own email is refused too (403)',
    selfGrantByEmail.status == 403,
    '$selfGrantByEmail',
  );

  // ------------------------- an unmanaged entity: request now, claim promotes
  // A request can be aimed at an entity nobody manages — there is nobody to
  // approve it, which is the honest state for an entity with no gatekeeper, and
  // the claim route is how it gets one. The claim must then PROMOTE that row
  // rather than write a twin: one person, one row, or the roster lists them
  // twice.
  final unmanagedVenue = await h.post('/api/collections/venues/records', {
    'name': 'Requested Orphan',
    'address': '9 Test Way',
    'contact': 'ro@test',
  }, token: superuser);
  final orphanRequester = await _signup(h, 'orphan.requester@agenda.test');
  final orphanJoin = await h.post('/api/agenda/join', {
    'targetType': 'venue',
    'targetId': unmanagedVenue.id,
  }, token: orphanRequester.token);
  a.check(
    'a request against an unmanaged entity is accepted (200)',
    orphanJoin.status == 200,
    '$orphanJoin',
  );

  final unmanagedRows = await h.get(
    '/api/collections/memberships/records?perPage=50&filter='
    '${Uri.encodeComponent('targetId="${unmanagedVenue.id}"')}',
    token: superuser,
  );
  a.check(
    'the request is the only row on the unmanaged entity',
    _items(unmanagedRows).length == 1 &&
        _items(unmanagedRows).first['status'] == 'pending' &&
        _items(unmanagedRows).first['initiatedBy'] == 'request',
    '$unmanagedRows',
  );

  final orphanClaim = await h.post('/api/agenda/claim', {
    'targetType': 'venue',
    'targetId': unmanagedVenue.id,
  }, token: orphanRequester.token);
  a.check(
    'an entity whose only row is a pending request can still be claimed',
    orphanClaim.status == 200 && orphanClaim.body['status'] == 'claimed',
    '$orphanClaim',
  );
  a.check(
    'the claim promotes the pending request row instead of twinning it',
    orphanClaim.body['membershipId'] == '${orphanJoin.body['membershipId']}',
    '$orphanClaim',
  );

  // --------------------------------- 15. the rename preserves data (proof)
  await _proveCreatedByRename(a);
}

List<Map<String, dynamic>> _items(PbResponse response) =>
    (response.body['items'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

Future<_Identity> _signup(PbHarness h, String email) async {
  const password = 'guard-test-password-123';
  final resp = await h.post('/api/collections/users/records', {
    'email': email,
    'password': password,
    'passwordConfirm': password,
    'name': email.split('@').first,
  });
  if (resp.status != 200) {
    throw StateError('signup failed for $email: $resp');
  }
  final login = await h.post('/api/collections/users/auth-with-password', {
    'identity': email,
    'password': password,
  });
  return _Identity(resp.id, (login.body['token'] as String?) ?? '');
}

/// A raw HTTP reply from the rename-proof instances, kept local to the proof so
/// it does not depend on the shared harness (which applies EVERY migration
/// before the first request and so cannot observe the pre-rename shape).
class _Reply {
  const _Reply(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  @override
  String toString() => '$status $body';
}

/// Proves that the `ownerId` -> `createdBy` rename in
/// `1790250200_membership_roles_and_roster.js` preserves data, on a POPULATED
/// database.
///
/// PocketBase tracks a field by its ID and renames the SQLite column when the
/// Field is renamed, so the values are expected to travel with it. That is an
/// assumption about the engine, and getting it wrong fails SILENTLY: every venue
/// and performer keeps its row and loses its creator, and nothing else in this
/// suite would notice — the entities stay reachable through their membership
/// rows, and the column is never read for authorization again. So it is proven
/// instead of trusted:
///
///   1. a throwaway instance is booted on the PRE-Phase-2 migrations only, with
///      no hooks, and populated in the old shape — a venue created by an app
///      user and one by a superuser with `ownerId` set, one with it empty, the
///      same for a performer, plus the membership rows the two backfills have to
///      classify;
///   2. the full migration set (including 1790250200) is applied on top of that
///      database;
///   3. the records are read back through the API and checked row by row.
///
/// The pre-Phase-2 hook files no longer exist in the repository (this phase
/// rewrote them), and running the CURRENT hooks against the OLD schema would
/// fail on every field the phase adds, so the pre-rename rows are written
/// directly: `ownerId` in the request body IS the column the old hook wrote
/// (`e.record.set("ownerId", userId)`), field for field.
Future<void> _proveCreatedByRename(PbAssertions a) async {
  final root = Directory.current.path;
  final configured = Platform.environment['PB_TEST_BINARY']?.trim() ?? '';
  final exe = configured.isEmpty ? '$root/pocketbase' : configured;
  if (File(exe).existsSync() == false) {
    a.check('the rename proof runs (pocketbase binary found)', false, exe);
    return;
  }

  final failuresBefore = a.failed.length;
  final dataDir = Directory.systemTemp.createTempSync('agenda_rename_data_');
  final preDir = Directory.systemTemp.createTempSync('agenda_rename_pre_');
  final noHooks = Directory.systemTemp.createTempSync('agenda_rename_hooks_');
  final log = StringBuffer();
  final client = http.Client();
  Process? server;
  var base = '';
  var token = '';

  Future<int> cli(List<String> args) async {
    final result = await Process.run(exe, args);
    log.write('${args.join(' ')}\n${result.stdout}${result.stderr}\n');
    return result.exitCode;
  }

  /// `migrate down` asks for confirmation on stdin ("Do you really want to
  /// revert the last 1 applied migration(s)? (y/N)"), and a run whose stdin is
  /// closed answers N and exits 0 — which would look exactly like a successful
  /// rollback while nothing happened. The prompt is therefore answered
  /// explicitly, and the outcome is asserted on the SCHEMA, not on the exit
  /// code.
  Future<int> rollbackOneMigration() async {
    final process = await Process.start(exe, [
      'migrate',
      'down',
      '1',
      '--dir=${dataDir.path}',
      '--migrationsDir=$root/pb_migrations',
    ]);
    process.stdin.write('y\n');
    await process.stdin.flush();
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    log.write('migrate down 1\n$out$err\n');
    return process.exitCode;
  }

  Future<bool> boot(String migrationsDir, String hooksDir) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    // `--automigrate=false` because this proof drives the migrations through the
    // CLI on purpose: with the default (`true`), booting a rolled-back database
    // would silently re-apply the migration being observed and the rollback
    // assertions would pass without ever seeing the old schema.
    final process = await Process.start(exe, [
      'serve',
      '--dir=${dataDir.path}',
      '--migrationsDir=$migrationsDir',
      '--hooksDir=$hooksDir',
      '--automigrate=false',
      '--http=127.0.0.1:$port',
    ]);
    server = process;
    process.stdout.transform(utf8.decoder).listen(log.write);
    process.stderr.transform(utf8.decoder).listen(log.write);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final health = await client
            .get(Uri.parse('http://127.0.0.1:$port/api/health'))
            .timeout(const Duration(seconds: 3));
        if (health.statusCode == 200) {
          base = 'http://127.0.0.1:$port';
          return true;
        }
      } catch (_) {
        // Not listening yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  Future<void> stopServer() async {
    final process = server;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    server = null;
  }

  Future<_Reply> call(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? as,
  }) async {
    final uri = Uri.parse('$base$path');
    final headers = <String, String>{'Content-Type': 'application/json'};
    final bearer = as ?? token;
    if (bearer.isNotEmpty) headers['Authorization'] = 'Bearer $bearer';
    final payload = body == null ? null : jsonEncode(body);
    final http.Response resp;
    switch (method) {
      case 'GET':
        resp = await client.get(uri, headers: headers);
      case 'POST':
        resp = await client.post(uri, headers: headers, body: payload);
      case 'PATCH':
        resp = await client.patch(uri, headers: headers, body: payload);
      default:
        throw ArgumentError('unsupported method $method');
    }
    Map<String, dynamic> decoded = const {};
    try {
      final value = jsonDecode(resp.body);
      if (value is Map<String, dynamic>) decoded = value;
    } catch (_) {
      // A non-JSON body leaves the map empty; the status is what matters.
    }
    return _Reply(resp.statusCode, decoded);
  }

  Future<List<Map<String, dynamic>>> memberships(String filter) async {
    final resp = await call(
      'GET',
      '/api/collections/memberships/records?perPage=50&filter=${Uri.encodeComponent(filter)}',
    );
    return (resp.body['items'] as List?)?.cast<Map<String, dynamic>>() ??
        const [];
  }

  Future<String> signup(String email) async {
    final created = await call(
      'POST',
      '/api/collections/users/records',
      body: {
        'email': email,
        'password': 'rename-proof-123',
        'passwordConfirm': 'rename-proof-123',
        'name': email.split('@').first,
      },
    );
    return created.body['id']?.toString() ?? '';
  }

  Future<String> login(String email) async {
    final resp = await call(
      'POST',
      '/api/collections/users/auth-with-password',
      body: {'identity': email, 'password': 'rename-proof-123'},
    );
    return (resp.body['token'] as String?) ?? '';
  }

  try {
    // Pre-Phase-2 migrations only, so the database can be populated before the
    // rename exists.
    for (final entry in Directory('$root/pb_migrations').listSync()) {
      if (entry is! File) continue;
      final name = entry.path.split('/').last;
      if (name.startsWith('1790250200')) continue;
      entry.copySync('${preDir.path}/$name');
    }

    final migrated = await cli([
      'migrate',
      'up',
      '--dir=${dataDir.path}',
      '--migrationsDir=${preDir.path}',
    ]);
    final superuser = await cli([
      'superuser',
      'upsert',
      PbHarness.defaultAdminEmail,
      PbHarness.defaultAdminPassword,
      '--dir=${dataDir.path}',
      '--migrationsDir=${preDir.path}',
    ]);
    a.check(
      'rename proof: the pre-Phase-2 database migrates and seeds',
      migrated == 0 && superuser == 0,
      'exit $migrated / $superuser',
    );
    if (migrated != 0 || superuser != 0) return;

    final up = await boot(preDir.path, noHooks.path);
    a.check('rename proof: the pre-Phase-2 instance boots', up);
    if (up == false) return;

    final admin = await call(
      'POST',
      '/api/collections/_superusers/auth-with-password',
      body: {
        'identity': PbHarness.defaultAdminEmail,
        'password': PbHarness.defaultAdminPassword,
      },
    );
    token = (admin.body['token'] as String?) ?? '';
    a.check(
      'rename proof: the superuser authenticates',
      token.isNotEmpty,
      '$admin',
    );

    final alice = await signup('rename.alice@agenda.test');
    final bob = await signup('rename.bob@agenda.test');
    final aliceToken = await login('rename.alice@agenda.test');
    a.check(
      'rename proof: the fixture accounts exist',
      alice.isNotEmpty && bob.isNotEmpty && aliceToken.isNotEmpty,
      '$alice / $bob',
    );

    // --- the pre-Phase-2 rows ---------------------------------------------
    // An app user's row carries the `ownerId` the old create hook would have
    // written from their token; a superuser's row carries the one the seed
    // script's `ensureCreatedBy` would have written; and two rows carry none at all,
    // so the "empty stays empty" case is covered for both collections.
    final appVenue = await call(
      'POST',
      '/api/collections/venues/records',
      as: aliceToken,
      body: {
        'name': 'Rename App Venue',
        'address': '1 Old Way',
        'contact': 'a@test',
        'ownerId': alice,
      },
    );
    final adminVenue = await call(
      'POST',
      '/api/collections/venues/records',
      body: {
        'name': 'Rename Admin Venue',
        'address': '2 Old Way',
        'contact': 'b@test',
        'ownerId': bob,
      },
    );
    final ownerlessVenue = await call(
      'POST',
      '/api/collections/venues/records',
      body: {
        'name': 'Rename Ownerless Venue',
        'address': '3 Old Way',
        'contact': 'c@test',
      },
    );
    final appPerformer = await call(
      'POST',
      '/api/collections/performers/records',
      as: aliceToken,
      body: {
        'name': 'Rename App Performer',
        'type': 'band',
        'contact': 'p@test',
        'ownerId': alice,
      },
    );
    final ownerlessPerformer = await call(
      'POST',
      '/api/collections/performers/records',
      body: {
        'name': 'Rename Ownerless Performer',
        'type': 'solo',
        'contact': 'q@test',
      },
    );
    a.check(
      'rename proof: the pre-Phase-2 entity rows are written',
      appVenue.status == 200 &&
          adminVenue.status == 200 &&
          ownerlessVenue.status == 200 &&
          appPerformer.status == 200 &&
          ownerlessPerformer.status == 200,
      '$appVenue / $adminVenue / $ownerlessVenue / $appPerformer / $ownerlessPerformer',
    );

    // Membership rows for both backfills to classify: one that names an account
    // (must end up ACTIVE) and one addressed to an email (must stay PENDING).
    // They are written while the collection has neither `status` nor
    // `initiatedBy`.
    final appVenueId = '${appVenue.body['id']}';
    final ownerlessVenueId = '${ownerlessVenue.body['id']}';
    final appPerformerId = '${appPerformer.body['id']}';
    final ownerlessPerformerId = '${ownerlessPerformer.body['id']}';
    final activeRow = await call(
      'POST',
      '/api/collections/memberships/records',
      body: {
        'userId': alice,
        'targetId': appVenueId,
        'targetType': 'venue',
        'role': 'manager',
        'targetOwnerId': alice,
      },
    );
    final pendingRow = await call(
      'POST',
      '/api/collections/memberships/records',
      body: {
        'pendingEmail': 'rename.pending@agenda.test',
        'targetId': appVenueId,
        'targetType': 'venue',
        'role': 'manager',
        'targetOwnerId': alice,
      },
    );
    final ownerlessVenueRow = await call(
      'POST',
      '/api/collections/memberships/records',
      body: {
        'userId': bob,
        'targetId': ownerlessVenueId,
        'targetType': 'venue',
        'role': 'manager',
        'targetOwnerId': '',
      },
    );
    a.check(
      'rename proof: the pre-Phase-2 membership rows are written',
      activeRow.status == 200 &&
          pendingRow.status == 200 &&
          ownerlessVenueRow.status == 200,
      '$activeRow / $pendingRow / $ownerlessVenueRow',
    );

    final beforeRename = await call(
      'GET',
      '/api/collections/venues/records/$appVenueId',
    );
    a.check(
      'rename proof: the seeded shape really is the old one',
      beforeRename.body['ownerId'] == alice &&
          beforeRename.body.containsKey('createdBy') == false,
      '$beforeRename',
    );

    await stopServer();

    // --- apply the Phase 2 migration to the populated database -------------
    final renamed = await cli([
      'migrate',
      'up',
      '--dir=${dataDir.path}',
      '--migrationsDir=$root/pb_migrations',
    ]);
    a.check(
      'rename proof: 1790250200 applies to a populated database',
      renamed == 0,
      'exit $renamed',
    );
    if (renamed != 0) return;

    final upAgain = await boot('$root/pb_migrations', '$root/pb_hooks');
    a.check(
      'rename proof: the migrated instance boots with the Phase 2 hooks',
      upAgain,
    );
    if (upAgain == false) return;

    final adminAgain = await call(
      'POST',
      '/api/collections/_superusers/auth-with-password',
      body: {
        'identity': PbHarness.defaultAdminEmail,
        'password': PbHarness.defaultAdminPassword,
      },
    );
    token = (adminAgain.body['token'] as String?) ?? '';

    Future<Map<String, dynamic>> readRecord(
      String collection,
      String id,
    ) async =>
        (await call('GET', '/api/collections/$collection/records/$id')).body;

    final appVenueAfter = await readRecord('venues', appVenueId);
    a.check(
      'createdBy survives the rename on an app-user venue',
      appVenueAfter['createdBy'] == alice,
      '$appVenueAfter',
    );
    a.check(
      'the renamed column is the only creator column left',
      appVenueAfter.containsKey('ownerId') == false &&
          appVenueAfter.containsKey('createdBy') == true,
      '$appVenueAfter',
    );

    final adminVenueAfter = await readRecord(
      'venues',
      '${adminVenue.body['id']}',
    );
    a.check(
      'createdBy survives the rename on a superuser venue',
      adminVenueAfter['createdBy'] == bob,
      '$adminVenueAfter',
    );

    final ownerlessVenueAfter = await readRecord('venues', ownerlessVenueId);
    a.check(
      'an empty ownerId stays an empty createdBy on a venue',
      '${ownerlessVenueAfter['createdBy']}' == '',
      '$ownerlessVenueAfter',
    );

    final appPerformerAfter = await readRecord('performers', appPerformerId);
    a.check(
      'createdBy survives the rename on an app-user performer',
      appPerformerAfter['createdBy'] == alice,
      '$appPerformerAfter',
    );

    final ownerlessPerformerAfter = await readRecord(
      'performers',
      ownerlessPerformerId,
    );
    a.check(
      'an empty ownerId stays an empty createdBy on a performer',
      '${ownerlessPerformerAfter['createdBy']}' == '',
      '$ownerlessPerformerAfter',
    );

    // --- the two backfills ------------------------------------------------
    final aliceRows = await memberships(
      'userId="$alice" && targetId="$appVenueId"',
    );
    a.check(
      'backfill 1 activates a membership that names an account',
      aliceRows.length == 1 &&
          aliceRows.first['status'] == 'active' &&
          aliceRows.first['initiatedBy'] == 'invite',
      '$aliceRows',
    );
    a.check(
      'backfill 2 does not duplicate a creator who is already a manager',
      aliceRows.length == 1,
      '$aliceRows',
    );

    final stillPending = await memberships(
      'targetId="$appVenueId" && pendingEmail="rename.pending@agenda.test"',
    );
    a.check(
      'backfill 1 keeps an unclaimed invitation pending, and drops targetOwnerId',
      stillPending.length == 1 &&
          stillPending.first['status'] == 'pending' &&
          stillPending.first.containsKey('targetOwnerId') == false,
      '$stillPending',
    );

    final performerManagers = await memberships(
      'userId="$alice" && targetId="$appPerformerId"',
    );
    a.check(
      'backfill 2 gives an active manager row to a creator who has none',
      performerManagers.length == 1 &&
          performerManagers.first['role'] == 'manager' &&
          performerManagers.first['status'] == 'active',
      '$performerManagers',
    );

    final adminVenueRows = await memberships(
      'targetId="${adminVenue.body['id']}"',
    );
    a.check(
      'backfill 2 covers a superuser-created venue whose creator is set',
      adminVenueRows.length == 1 && adminVenueRows.first['userId'] == bob,
      '$adminVenueRows',
    );

    final ownerlessPerformerRows = await memberships(
      'targetId="$ownerlessPerformerId"',
    );
    a.check(
      'backfill 2 invents no manager for an entity with no creator',
      ownerlessPerformerRows.isEmpty,
      '$ownerlessPerformerRows',
    );

    final ownerlessVenueRows = await memberships(
      'targetId="$ownerlessVenueId"',
    );
    a.check(
      'an entity with no creator keeps exactly the rows it had',
      ownerlessVenueRows.length == 1 &&
          ownerlessVenueRows.first['userId'] == bob &&
          ownerlessVenueRows.first['status'] == 'active',
      '$ownerlessVenueRows',
    );

    // --- the migration is declared reversible, and the rename is where a
    // rollback would lose data if it were wrong in that direction too --------
    await stopServer();
    final rollback = await rollbackOneMigration();
    a.check(
      'rename proof: 1790250200 rolls back',
      rollback == 0,
      'exit $rollback',
    );

    // The rolled-back database is read through the PRE-Phase-2 migration dir:
    // `serve` applies every pending migration in `--migrationsDir` at boot
    // (verified against 0.38.2 — `--automigrate=false` does not stop that), so
    // pointing the instance at the full directory would silently re-apply the
    // migration under test and there would be nothing old to observe. And no
    // hooks, because the Phase 2 hooks write fields this schema does not have.
    final rolledBackUp = await boot(preDir.path, noHooks.path);
    a.check('rename proof: the rolled-back instance boots', rolledBackUp);
    if (rolledBackUp) {
      final adminRolledBack = await call(
        'POST',
        '/api/collections/_superusers/auth-with-password',
        body: {
          'identity': PbHarness.defaultAdminEmail,
          'password': PbHarness.defaultAdminPassword,
        },
      );
      token = (adminRolledBack.body['token'] as String?) ?? '';

      final rolledBackVenue = await readRecord('venues', appVenueId);
      a.check(
        'the rollback restores ownerId with its value intact',
        rolledBackVenue['ownerId'] == alice &&
            rolledBackVenue.containsKey('createdBy') == false,
        '$rolledBackVenue',
      );

      final rolledBackMemberships = await memberships(
        'targetId="$appVenueId" && pendingEmail="rename.pending@agenda.test"',
      );
      a.check(
        'the rollback restores targetOwnerId and drops status',
        rolledBackMemberships.length == 1 &&
            rolledBackMemberships.first['targetOwnerId'] == alice &&
            rolledBackMemberships.first.containsKey('status') == false,
        '$rolledBackMemberships',
      );
    }

    // ... and forward again, on the same database: the points that matter are
    // that the value survived a second rename and that the migration can be
    // re-applied to a database it has already touched.
    await stopServer();
    final reApplied = await cli([
      'migrate',
      'up',
      '--dir=${dataDir.path}',
      '--migrationsDir=$root/pb_migrations',
    ]);
    a.check(
      'rename proof: the migration can be applied again after a rollback',
      reApplied == 0,
      'exit $reApplied',
    );

    final reAppliedUp = await boot('$root/pb_migrations', '$root/pb_hooks');
    a.check(
      'rename proof: the re-applied instance boots with the Phase 2 hooks',
      reAppliedUp,
    );
    if (reAppliedUp) {
      final adminReapplied = await call(
        'POST',
        '/api/collections/_superusers/auth-with-password',
        body: {
          'identity': PbHarness.defaultAdminEmail,
          'password': PbHarness.defaultAdminPassword,
        },
      );
      token = (adminReapplied.body['token'] as String?) ?? '';

      final reappliedVenue = await readRecord('venues', appVenueId);
      a.check(
        'createdBy still holds the same value after a down/up round trip',
        reappliedVenue['createdBy'] == alice &&
            reappliedVenue.containsKey('ownerId') == false,
        '$reappliedVenue',
      );
    }
  } finally {
    await stopServer();
    client.close();
    for (final dir in [dataDir, preDir, noHooks]) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // A leftover temp dir is not worth failing a run over.
      }
    }
  }

  if (a.failed.length > failuresBefore) {
    // Only on failure: the log spans two server boots and is useless otherwise.
    stdout.writeln('\n--- rename proof log ---\n$log');
  }
}
