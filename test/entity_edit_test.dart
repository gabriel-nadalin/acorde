import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:acorde/screens/entity_edit.dart';

import 'support/fake_pocketbase.dart';
import 'support/screen_harness.dart';

/// Create/edit/delete for venues and performers, plus the invitation form.
///
/// The records this screen writes are the ones an account's ownership hangs
/// off, so the payloads asserted here are the ones that decide who may later
/// edit the record: `ownerId` is server-set, and an invitation carries an email
/// rather than a user id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
  });

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder saveButton() => find.widgetWithText(ElevatedButton, strings.save);
  Finder deleteButton() => find.widgetWithText(OutlinedButton, strings.delete);

  Map<String, dynamic> bodyOfPost(WidgetTester tester, String collection) {
    final request = h.pb
        .requestsTo(collection)
        .singleWhere((request) => request.method == 'POST');
    expect(request.url.path, '/api/collections/$collection/records');
    return jsonDecode(request.body) as Map<String, dynamic>;
  }

  /// Every request that hit the claim route, in order.
  ///
  /// The route lives outside `/api/collections/...`, so [FakePb.requestsTo]
  /// cannot select it; the path is the only handle. Asserting the received
  /// request is how these tests check the wire contract the hook is built
  /// against without reaching into the client that sent it.
  List<http.Request> claimRequests() => [
    for (final request in h.pb.requests)
      if (request.url.path == '/api/agenda/claim') request,
  ];

  /// Adds a venue someone else owns (no membership row for this user) and loads
  /// it, so the duplicate check has a record to compare against.
  Future<void> seedVenue({
    String id = 'v3',
    String name = 'Harbor Hall',
  }) async {
    h.pb.records('venues').add({'id': id, 'name': name});
    await h.warm(force: true);
  }

  /// The performer counterpart of [seedVenue].
  Future<void> seedPerformer({
    String id = 'p3',
    String name = 'Harbor Band',
  }) async {
    h.pb.records('performers').add({'id': id, 'name': name, 'type': 'band'});
    await h.warm(force: true);
  }

  /// Fills the name field and taps Save, leaving the screen settled.
  Future<void> submitName(
    WidgetTester tester,
    Finder nameField,
    String name,
  ) async {
    await tester.enterText(nameField, name);
    await tester.tap(saveButton());
    await tester.pumpAndSettle();
  }

  /// Settles a screen whose work cannot finish inside the fake-async zone.
  ///
  /// A cold repository that fails to load falls back to the persisted mirror,
  /// and the `shared_preferences` read behind that only completes when the real
  /// event loop turns. [WidgetTester.runAsync] is the one way to give it that
  /// turn; the loop then pumps the frames the resumed work schedules. Bounded on
  /// purpose so a genuinely stuck screen fails the assertion that follows rather
  /// than hanging the suite.
  Future<void> settleAcrossRealAsync(WidgetTester tester) async {
    for (var round = 0; round < 10; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }
  }

  testWidgets('creating a venue posts the form without an ownerId', (
    tester,
  ) async {
    await h.pump(tester, const VenueEditPage());

    await tester.enterText(field(strings.venueNameLabel), 'New Hall');
    await tester.enterText(field(strings.addressLabel), '5 Side St');
    await tester.enterText(field(strings.capacityLabel), '250');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    final body = bodyOfPost(tester, 'venues');
    expect(body['name'], 'New Hall');
    expect(body['address'], '5 Side St');
    expect(body['capacity'], 250);
    // Ownership is granted by the server from the authenticated account; a
    // client that sent its own id would be assigning itself the record.
    expect(body.containsKey('ownerId'), isFalse);

    expect(find.text(strings.entityCreated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('creating a performer posts the form without an ownerId', (
    tester,
  ) async {
    await h.pump(tester, const PerformerEditPage());

    await tester.enterText(field(strings.performerNameLabel), 'New Act');
    await tester.enterText(field(strings.typeLabel), 'band');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    final body = bodyOfPost(tester, 'performers');
    expect(body['name'], 'New Act');
    expect(body['type'], 'band');
    expect(body.containsKey('ownerId'), isFalse);

    expect(find.text(strings.entityCreated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('editing loads the record and PATCHes that record', (
    tester,
  ) async {
    await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

    expect(find.text('My Hall'), findsOneWidget);
    expect(find.text('1 Main St'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);

    await tester.enterText(field(strings.venueNameLabel), 'My Hall Renamed');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    final request = h.pb
        .requestsTo('venues')
        .singleWhere((request) => request.method == 'PATCH');
    expect(request.url.path, '/api/collections/venues/records/v1');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['name'], 'My Hall Renamed');
    expect(body.containsKey('ownerId'), isFalse);
    expect(
      h.pb
          .records('venues')
          .firstWhere((record) => record['id'] == 'v1')['name'],
      'My Hall Renamed',
    );

    expect(h.pb.count('POST venues'), 0);
    expect(find.text(strings.entityUpdated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('deleting asks first, and only a confirmation deletes', (
    tester,
  ) async {
    await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();

    expect(find.text(strings.confirmDeleteTitle('My Hall')), findsOneWidget);
    expect(find.text(strings.confirmDeleteBody), findsOneWidget);
    expect(h.pb.count('DELETE venues'), 0);

    await tester.tap(find.widgetWithText(TextButton, strings.cancel));
    await tester.pumpAndSettle();
    expect(h.pb.count('DELETE venues'), 0);

    await tester.tap(deleteButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, strings.delete));
    await tester.pumpAndSettle();

    expect(h.pb.count('DELETE venues'), 1);
    expect(
      h.pb.records('venues').map((record) => record['id']),
      isNot(contains('v1')),
    );
    expect(find.text(strings.entityDeleted), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets(
    "a refused delete shows the server's wording and claims no success",
    (tester) async {
      const refusal = 'Venue still has events. Remove or reassign them first.';
      h.pb.intercept = (request) async {
        if (request.method == 'DELETE' &&
            request.url.path.contains('/venues/')) {
          return FakePb.json(400, {'message': refusal, 'status': 400});
        }
        return null;
      };

      await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));
      await tester.tap(deleteButton());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, strings.delete));
      await tester.pumpAndSettle();

      expect(find.text(refusal), findsOneWidget);
      expect(find.text(strings.entityDeleted), findsNothing);
      expect(find.text(kHomeMarker), findsNothing);
      expect(
        h.pb.records('venues').map((record) => record['id']),
        contains('v1'),
      );
    },
  );

  testWidgets('inviting by email posts a pending membership and confirms it', (
    tester,
  ) async {
    await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

    await tester.enterText(
      field(strings.inviteEmailLabel),
      'guest@example.com',
    );
    await tester.tap(find.widgetWithText(FilledButton, strings.addManager));
    await tester.pumpAndSettle();

    final body = bodyOfPost(tester, 'memberships');
    expect(body['targetId'], 'v1');
    expect(body['targetType'], 'venue');
    expect(body['pendingEmail'], 'guest@example.com');
    expect(body['role'], 'manager');
    // The invitee has no account id yet: sending one would claim the row for a
    // user that may never sign in, and the server resolves the email instead.
    expect(body.containsKey('userId'), isFalse);

    expect(find.text(strings.inviteSent('guest@example.com')), findsOneWidget);
  });

  testWidgets('an invalid email is refused without sending anything', (
    tester,
  ) async {
    await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

    await tester.enterText(field(strings.inviteEmailLabel), 'not-an-address');
    await tester.tap(find.widgetWithText(FilledButton, strings.addManager));
    await tester.pumpAndSettle();

    expect(find.text(strings.emailInvalid), findsOneWidget);
    expect(
      h.pb
          .requestsTo('memberships')
          .where((request) => request.method == 'POST'),
      isEmpty,
    );
  });

  testWidgets(
    'inviting a performer sends the performer target and member role',
    (tester) async {
      await h.pumpEditing(tester, const PerformerEditPage(performerId: 'p1'));

      await tester.enterText(
        field(strings.inviteEmailLabel),
        'bandmate@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, strings.addMember));
      await tester.pumpAndSettle();

      final body = bodyOfPost(tester, 'memberships');
      expect(body['targetId'], 'p1');
      expect(body['targetType'], 'performer');
      expect(body['role'], 'member');
      expect(body.containsKey('userId'), isFalse);

      expect(
        find.text(strings.inviteSent('bandmate@example.com')),
        findsOneWidget,
      );
    },
  );

  testWidgets('an unclaimed invitation renders as pending, next to the roster', (
    tester,
  ) async {
    h.pb.records('memberships').add({
      'id': 'm9',
      'userId': '',
      'pendingEmail': 'guest@example.com',
      'targetId': 'v1',
      'targetType': 'venue',
      'role': 'manager',
      // An invitation now waits for the invitee to accept it, so it is pending
      // until they do — the roster shows it as owed consent, not as granted.
      'status': 'pending',
      'targetOwnerId': ScreenHarness.userId,
    });
    await h.warm(force: true);

    await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

    // The manager who owns the record lists their own roster — the row they
    // invited is visible to them, unclaimed or not.
    expect(find.text(strings.managerSectionTitle), findsOneWidget);
    expect(find.text(strings.listEmpty), findsNothing);
    // The caller's own row is labelled with the account's name and marked as
    // theirs; the invitee is identified by the address it was sent to.
    expect(
      find.text('${ScreenHarness.userName} (${strings.rosterYou})'),
      findsOneWidget,
    );
    expect(find.text('guest@example.com'), findsOneWidget);
    expect(find.textContaining(strings.awaitingAcceptance), findsOneWidget);
  });

  // ------------------------------------------------------------------ duplicates
  //
  // Creating a second record for the same entity is the bug the prompt exists
  // to prevent: the two records share no id, so the server's double-booking
  // check — which compares `venueId` — never sees the collision. These tests
  // assert the three outcomes a person can choose (claim, create anyway,
  // cancel) by what the fake server actually received.

  testWidgets('a venue name that matches nothing is created without a prompt', (
    tester,
  ) async {
    await h.pump(tester, const VenueEditPage());

    await submitName(tester, field(strings.venueNameLabel), 'Solo Arena');

    expect(find.byType(AlertDialog), findsNothing);
    expect(h.pb.count('POST venues'), 1);
    expect(claimRequests(), isEmpty);
    expect(find.text(strings.entityCreated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('a same-name venue prompts and writes nothing yet', (
    tester,
  ) async {
    await seedVenue(name: 'Harbor Hall');
    await h.pump(tester, const VenueEditPage());

    // Case, spacing and punctuation differ — and the name the user typed is not
    // even a substring of the stored one. That is the case a name-query
    // prefilter reports as "no duplicate", so this spelling is deliberate: it is
    // the regression guard for a lookup that second-guessed `sameEntityName`.
    await submitName(tester, field(strings.venueNameLabel), 'harbor  hall!');

    expect(
      find.text(strings.duplicateExistsTitle(strings.venue, 'Harbor Hall')),
      findsOneWidget,
    );
    expect(find.text(strings.duplicateClaimBody), findsOneWidget);
    // The whole point of the prompt: the create has not happened.
    expect(h.pb.count('POST venues'), 0);
    expect(claimRequests(), isEmpty);

    // Cancelling is part of the same claim: it must leave the record unwritten
    // and the form in place, not just dismiss the dialog.
    await tester.tap(find.widgetWithText(TextButton, strings.cancel));
    await tester.pumpAndSettle();

    expect(h.pb.count('POST venues'), 0);
    expect(claimRequests(), isEmpty);
    expect(find.byType(VenueEditPage), findsOneWidget);
  });

  testWidgets('claiming the duplicate adopts it and reports success', (
    tester,
  ) async {
    await seedVenue(id: 'v3', name: 'Harbor Hall');
    await h.pump(tester, const VenueEditPage());

    await submitName(tester, field(strings.venueNameLabel), 'harbor  hall!');
    await tester.tap(
      find.widgetWithText(FilledButton, strings.claimEntityAction),
    );
    await tester.pumpAndSettle();

    final claim = claimRequests().single;
    expect(jsonDecode(claim.body), {'targetType': 'venue', 'targetId': 'v3'});
    // Claiming adopts the existing record; it must not also create a new one.
    expect(h.pb.count('POST venues'), 0);
    expect(find.text(strings.claimSucceeded('Harbor Hall')), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('create anyway writes a new venue and never claims', (
    tester,
  ) async {
    await seedVenue(id: 'v3', name: 'Harbor Hall');
    await h.pump(tester, const VenueEditPage());

    await submitName(tester, field(strings.venueNameLabel), 'harbor  hall!');
    await tester.tap(
      find.widgetWithText(TextButton, strings.createAnywayAction),
    );
    await tester.pumpAndSettle();

    expect(h.pb.count('POST venues'), 1);
    expect(claimRequests(), isEmpty);
    expect(find.text(strings.entityCreated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets('cancelling the prompt writes nothing and stays on the form', (
    tester,
  ) async {
    await seedVenue(id: 'v3', name: 'Harbor Hall');
    await h.pump(tester, const VenueEditPage());

    await submitName(tester, field(strings.venueNameLabel), 'harbor  hall!');
    await tester.tap(find.widgetWithText(TextButton, strings.cancel));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(h.pb.count('POST venues'), 0);
    expect(claimRequests(), isEmpty);
    // Not popped: cancelling is not a decision to leave.
    expect(saveButton(), findsOneWidget);
    expect(find.text(kHomeMarker), findsNothing);
  });

  testWidgets(
    'a duplicate I already manage offers to open it rather than claim',
    (tester) async {
      h.pb.records('venues').add({'id': 'v3', 'name': 'Harbor Hall'});
      h.pb.records('memberships').add({
        'id': 'm3',
        'userId': ScreenHarness.userId,
        'targetId': 'v3',
        'targetType': 'venue',
        'role': 'manager',
        // Active, or the row would parse as a pending invite and this record
        // would not count as mine.
        'status': 'active',
        'targetOwnerId': ScreenHarness.userId,
      });
      await h.warm(force: true);

      await h.pump(tester, const VenueEditPage());
      await submitName(tester, field(strings.venueNameLabel), 'Harbor Hall');

      // The wording and the verb both change: this one is not theirs to claim.
      expect(find.text(strings.duplicateAlreadyMineBody), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, strings.openEntityAction),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, strings.claimEntityAction),
        findsNothing,
      );

      await tester.tap(
        find.widgetWithText(FilledButton, strings.openEntityAction),
      );
      await tester.pumpAndSettle();

      expect(find.text(venueEditMarker('v3')), findsOneWidget);
      expect(h.pb.count('POST venues'), 0);
      expect(claimRequests(), isEmpty);
    },
  );

  testWidgets(
    'a claim refused by its current manager shows the server wording, not success',
    (tester) async {
      await seedVenue(id: 'v3', name: 'Harbor Hall');
      const refusal = 'This venue already has a manager.';
      h.pb.intercept = (request) async {
        if (request.method == 'POST' &&
            request.url.path == '/api/agenda/claim') {
          return FakePb.json(409, {'message': refusal, 'status': 409});
        }
        return null;
      };
      await h.pump(tester, const VenueEditPage());

      await submitName(tester, field(strings.venueNameLabel), 'harbor  hall!');
      await tester.tap(
        find.widgetWithText(FilledButton, strings.claimEntityAction),
      );
      await tester.pumpAndSettle();

      expect(claimRequests(), hasLength(1));
      expect(find.text(refusal), findsOneWidget);
      expect(find.text(strings.claimSucceeded('Harbor Hall')), findsNothing);
      expect(h.pb.count('POST venues'), 0);
      // Somebody got there first; the user is left on the form, not popped as if
      // the claim had worked.
      expect(saveButton(), findsOneWidget);
      expect(find.text(kHomeMarker), findsNothing);
    },
  );

  testWidgets('a failed duplicate lookup does not block creating', (
    tester,
  ) async {
    // Make the lookup genuinely fail, not merely miss: the cache is dropped and
    // the offline mirror along with it, so the load cannot answer from memory.
    // A cold repository that fails to load reaches for the persisted mirror,
    // which is the one part of this path a widget test's fake-async zone cannot
    // resolve (it is a shared_preferences call that needs the real event loop),
    // hence the real-async settle below. The failure is a non-retryable 4xx so
    // the await does not sit in the service's 5xx backoff either.
    await (await SharedPreferences.getInstance()).remove('venues_cache');
    h.venues.reset();
    var failedLookup = false;
    h.pb.intercept = (request) async {
      // Only the lookup fails; the refresh that follows a successful create
      // still needs to reach the fake, or the screen would never finish.
      if (!failedLookup &&
          request.method == 'GET' &&
          request.url.path.contains('/venues/records')) {
        failedLookup = true;
        return FakePb.json(400, {
          'message': 'lookup unavailable',
          'status': 400,
        });
      }
      return null;
    };
    await h.pump(tester, const VenueEditPage());

    await tester.enterText(field(strings.venueNameLabel), 'Harbor Hall');
    await tester.tap(saveButton());
    await settleAcrossRealAsync(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(h.pb.count('POST venues'), 1);
    expect(find.text(strings.entityCreated), findsOneWidget);
  });

  testWidgets(
    'performers get the same duplicate check and claim, with the performer target',
    (tester) async {
      await seedPerformer(id: 'p3', name: 'Harbor Band');
      await h.pump(tester, const PerformerEditPage());

      await submitName(
        tester,
        field(strings.performerNameLabel),
        'harbor  band',
      );

      expect(
        find.text(
          strings.duplicateExistsTitle(strings.performer, 'Harbor Band'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.widgetWithText(FilledButton, strings.claimEntityAction),
      );
      await tester.pumpAndSettle();

      final claim = claimRequests().single;
      expect(jsonDecode(claim.body), {
        'targetType': 'performer',
        'targetId': 'p3',
      });
      expect(h.pb.count('POST performers'), 0);
      expect(find.text(strings.claimSucceeded('Harbor Band')), findsOneWidget);
    },
  );

  testWidgets(
    'editing an existing record never prompts, even onto a duplicate name',
    (tester) async {
      await seedVenue(id: 'v3', name: 'Harbor Hall');
      await h.pumpEditing(tester, const VenueEditPage(venueId: 'v1'));

      // Renaming to a name another record already holds is still an edit, not a
      // create: there is nothing to resolve and no prompt to answer.
      await submitName(tester, field(strings.venueNameLabel), 'Harbor Hall');

      expect(find.byType(AlertDialog), findsNothing);
      expect(claimRequests(), isEmpty);
      expect(h.pb.count('POST venues'), 0);
      final patched = h.pb
          .requestsTo('venues')
          .singleWhere((request) => request.method == 'PATCH');
      expect(patched.url.path, '/api/collections/venues/records/v1');
      expect(find.text(strings.entityUpdated), findsOneWidget);
    },
  );
}
