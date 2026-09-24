import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:event_calendar/models/event.dart';
import 'package:event_calendar/screens/create_event.dart';
import 'package:event_calendar/utils/calendar_math.dart';

import 'support/fake_pocketbase.dart';
import 'support/screen_harness.dart';

/// The event form, driven the way a user drives it: type, pick, press Create.
///
/// Writes are the part of this screen that can corrupt data, so every test here
/// asserts what the fake server actually received — the wire payload *is* the
/// behaviour — or what the user is told about it. Nothing reaches into the
/// screen's own state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('pt'));

  late ScreenHarness h;
  late DateTime day;
  late DateTime start;
  late DateTime end;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
    // `initialDate` seeds 19:00 local with an hour for the end, so these are
    // the instants the form is showing.
    day = DateTime(2026, 5, 4);
    start = DateTime(2026, 5, 4, 19);
    end = DateTime(2026, 5, 4, 20);
  });

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder createButton() =>
      find.widgetWithText(ElevatedButton, strings.createEvent);
  Finder saveButton() => find.widgetWithText(ElevatedButton, strings.save);

  Future<void> openCreate(
    WidgetTester tester, {
    Event? event,
    bool lockedVenue = false,
  }) => h.pump(
    tester,
    CreateEventPage(
      event: event,
      initialDate: event == null ? day : null,
      prefillVenueId: lockedVenue ? 'v1' : null,
      prefillVenueName: lockedVenue ? 'My Hall' : null,
      lockVenue: lockedVenue,
    ),
  );

  /// Picks weekly repetition ending after [count] occurrences.
  ///
  /// The dropdowns are private enums, so both are chosen by the label the user
  /// reads; the menu entry is the last match once the menu is open.
  Future<void> repeatWeekly(WidgetTester tester, int count) async {
    await tester.tap(find.text(strings.repeatNone));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.repeatWeekly).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.repeatEndsNever).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.repeatEndsCount).last);
    await tester.pumpAndSettle();
    await tester.enterText(field(strings.repeatCountLabel), '$count');
    await tester.pumpAndSettle();
  }

  testWidgets(
    'submitting without a title shows the field error and sends nothing',
    (tester) async {
      await openCreate(tester);

      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(find.text(strings.titleRequired), findsOneWidget);
      expect(h.pb.requestsTo('events'), isEmpty);
      // Still on the form: nothing was saved, so nothing was popped.
      expect(find.text(kHomeMarker), findsNothing);
    },
  );

  testWidgets('an end equal to the start is refused before anything is sent', (
    tester,
  ) async {
    await openCreate(
      tester,
      event: Event(id: 'e1', title: 'Rehearsal', start: start, end: start),
    );

    // The premise, in the form the user sees it.
    expect(find.text(formatDateTime('pt', start)), findsNWidgets(2));

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.text(strings.endMustBeAfterStart), findsOneWidget);
    expect(h.pb.requestsTo('events'), isEmpty);
    expect(find.text(kHomeMarker), findsNothing);
  });

  testWidgets(
    'a valid one-off event is POSTed as UTC instants and a performer array',
    (tester) async {
      await openCreate(tester);
      await tester.enterText(field(strings.titleLabel), 'CD Release');
      await tester.tap(find.text('My Band'));
      await tester.pumpAndSettle();

      await tester.tap(createButton());
      await tester.pumpAndSettle();

      final request = h.pb.requestsTo('events').single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/collections/events/records');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['title'], 'CD Release');
      // Explicit UTC instants: the month queries and the server's overlap guard
      // compare these strings, so a naive local time would misalign.
      expect(body['start'], start.toUtc().toIso8601String());
      expect(body['end'], end.toUtc().toIso8601String());
      expect(body['start'], endsWith('Z'));
      expect(body['end'], endsWith('Z'));
      // A real JSON array, not a stringified list.
      expect(body['performers'], isA<List<dynamic>>());
      expect(body['performers'], contains('p1'));

      expect(find.text(strings.eventCreated), findsOneWidget);
      expect(find.text(kHomeMarker), findsOneWidget);
    },
  );

  testWidgets(
    "a rejected booking shows the server's wording and claims no success",
    (tester) async {
      const conflict =
          'Schedule conflict: venue already booked in this time range.';
      h.pb.intercept = (request) async {
        if (request.method == 'POST' &&
            request.url.path == '/api/collections/events/records') {
          return FakePb.json(400, {'message': conflict, 'status': 400});
        }
        return null;
      };

      await openCreate(tester);
      await tester.enterText(field(strings.titleLabel), 'Clashing Gig');
      await tester.tap(createButton());
      await tester.pumpAndSettle();

      expect(find.text(strings.errorWithMessage(conflict)), findsOneWidget);
      expect(find.text(strings.eventCreated), findsNothing);
      expect(find.text(kHomeMarker), findsNothing);
    },
  );

  testWidgets('editing prefills the event and PATCHes that record', (
    tester,
  ) async {
    final existing = Event(
      id: 'e7',
      title: 'Existing Gig',
      description: 'Doors 20:00',
      start: start,
      end: end,
    );
    // The event as the server holds it: a PATCH that named a record it does not
    // have would answer 404 and the test would fail on the snack bar instead of
    // on the assertion it is making.
    h.pb.records('events').add({
      'id': 'e7',
      'title': 'Existing Gig',
      'description': 'Doors 20:00',
      'start': start.toUtc().toIso8601String(),
      'end': end.toUtc().toIso8601String(),
      'venueId': 'v1',
      'performers': <String>[],
      'createdBy': ScreenHarness.userId,
    });
    await openCreate(tester, event: existing);

    expect(find.text('Existing Gig'), findsOneWidget);
    expect(find.text('Doors 20:00'), findsOneWidget);
    expect(find.text(formatDateTime('pt', start)), findsOneWidget);
    // One instance of a series has no repeat controls: saving must not rewrite
    // the rule the other occurrences were created from.
    expect(find.text(strings.repeatLabel), findsNothing);

    await tester.enterText(field(strings.titleLabel), 'Renamed Gig');
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    final request = h.pb.requestsTo('events').single;
    expect(request.method, 'PATCH');
    expect(request.url.path, '/api/collections/events/records/e7');
    expect(jsonDecode(request.body)['title'], 'Renamed Gig');
    expect(
      h.pb
          .records('events')
          .firstWhere((record) => record['id'] == 'e7')['title'],
      'Renamed Gig',
    );

    expect(find.text(strings.eventUpdated), findsOneWidget);
    expect(find.text(kHomeMarker), findsOneWidget);
  });

  testWidgets(
    'a weekly series posts one request per occurrence and reports the count',
    (tester) async {
      await openCreate(tester);
      await tester.enterText(field(strings.titleLabel), 'Residency');
      await repeatWeekly(tester, 3);

      expect(find.text(strings.occurrenceCountLabel(3)), findsOneWidget);

      await tester.tap(createButton());
      await tester.pumpAndSettle();

      final posts = h.pb.requestsTo('events');
      expect(posts, hasLength(3));
      expect(
        [
          for (final post in posts)
            (jsonDecode(post.body) as Map<String, dynamic>)['start'],
        ],
        [
          start.toUtc().toIso8601String(),
          DateTime(2026, 5, 11, 19).toUtc().toIso8601String(),
          DateTime(2026, 5, 18, 19).toUtc().toIso8601String(),
        ],
      );
      // One series, so a later edit knows which instances belong together.
      final seriesIds = {
        for (final post in posts)
          (jsonDecode(post.body) as Map<String, dynamic>)['seriesId'],
      };
      expect(seriesIds, hasLength(1));
      expect(seriesIds.single, isNotNull);

      expect(find.text(strings.seriesCreated(3)), findsOneWidget);
      expect(find.text(kHomeMarker), findsOneWidget);
    },
  );

  testWidgets('a partly refused series names the dates that failed', (
    tester,
  ) async {
    const conflict =
        'Schedule conflict: venue already booked in this time range.';
    var posted = 0;
    h.pb.intercept = (request) async {
      if (request.method == 'POST' &&
          request.url.path == '/api/collections/events/records') {
        posted++;
        if (posted == 2) {
          return FakePb.json(400, {'message': conflict, 'status': 400});
        }
      }
      return null;
    };

    await openCreate(tester);
    await tester.enterText(field(strings.titleLabel), 'Residency');
    await repeatWeekly(tester, 3);
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    // Every occurrence is still attempted; the server decided which one it took.
    expect(h.pb.count('POST events'), 3);

    final rejected = DateTime(2026, 5, 11, 19);
    expect(
      find.text(
        '${strings.seriesPartial(2, 1)} ${strings.seriesPartialDetail('${_stamp(rejected)} — $conflict')}',
      ),
      findsOneWidget,
    );
    expect(find.text(strings.seriesCreated(3)), findsNothing);
    expect(find.text(strings.eventCreated), findsNothing);
  });

  testWidgets('a locked venue is shown as fixed and offered no picker', (
    tester,
  ) async {
    await openCreate(tester, lockedVenue: true);

    expect(find.text(strings.venueWithName('My Hall')), findsOneWidget);
    expect(find.text(strings.searchVenues), findsNothing);

    await tester.enterText(field(strings.titleLabel), 'Locked Gig');
    await tester.tap(createButton());
    await tester.pumpAndSettle();

    expect(
      (jsonDecode(h.pb.requestsTo('events').single.body)
          as Map<String, dynamic>)['venueId'],
      'v1',
    );
    expect(find.text(strings.eventCreated), findsOneWidget);
  });
}

/// `YYYY-MM-DD HH:MM` local stamp, the shape the series report prefixes each
/// failed occurrence with.
String _stamp(DateTime instant) {
  String two(int value) => value.toString().padLeft(2, '0');
  final local = instant.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
