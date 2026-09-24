import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:event_calendar/screens/events_list.dart';
import 'package:event_calendar/screens/user_calendar_tabs.dart';

import 'support/screen_harness.dart';

/// Starting an event from a calendar, in every view that offers it.
///
/// Tapping a day used to reach the create form on a venue calendar and do
/// nothing at all on a performer or combined one, because each view gated the
/// day cell on its own condition. These tests pin the behaviour per view — what
/// the push is seeded with, and, just as importantly, which views deliberately
/// stay read-only.
///
/// The push is asserted through the route it lands on, because that location
/// (its query included) *is* the seed: `lockVenue=1` and `performerId=p1` are
/// what the form reads to decide what the user has to fill in.
const String newEventMarker = 'HARNESS NEW EVENT';
const String editEventMarker = 'HARNESS EDIT EVENT';

Map<String, dynamic> eventRecord(
  String id, {
  required DateTime start,
  required DateTime end,
  String title = 'Gig',
  String? venueId,
  List<String> performers = const [],
}) => {
  'id': id,
  'title': title,
  'start': start.toUtc().toIso8601String(),
  'end': end.toUtc().toIso8601String(),
  'venueId': ?venueId,
  'performers': performers,
  'createdBy': 'u1',
  'created': '2026-01-01T00:00:00.000Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  // The page opens on the current month, so the fixtures have to live in it.
  // Day 15 exists in every month, and never collides with the "today" cell the
  // grid starts its keyboard ring on.
  final now = DateTime.now();
  String dayKey(int day) =>
      '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
  });

  /// Pumps a calendar with the create/edit destinations the page pushes to,
  /// each rendered as text carrying the location it was given.
  Future<void> pumpCalendar(WidgetTester tester, Widget page) => h.pump(
    tester,
    page,
    routes: [
      GoRoute(
        path: '/events/new',
        builder: (context, state) =>
            Scaffold(body: Center(child: Text('$newEventMarker ${state.uri}'))),
      ),
      GoRoute(
        path: '/events/:id/edit',
        builder: (context, state) => Scaffold(
          body: Center(child: Text('$editEventMarker ${state.uri}')),
        ),
      ),
    ],
  );

  /// The location the app asked to open, or null when it opened nothing.
  String? pushed(WidgetTester tester, String marker) {
    final found = find.textContaining(marker);
    if (found.evaluate().isEmpty) return null;
    return tester.widget<Text>(found.first).data;
  }

  /// Taps a day cell in the grid.
  Future<void> tapDay(WidgetTester tester, int day) async {
    await tester.tap(find.text('$day'));
    await tester.pumpAndSettle();
  }

  group('a venue calendar', () {
    testWidgets('an empty day starts a new event locked to the venue', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        const EventsListPage(
          venueMode: true,
          venueId: 'v1',
          venueName: 'My Hall',
        ),
      );
      await tapDay(tester, 10);

      final location = pushed(tester, newEventMarker);
      expect(
        location,
        isNotNull,
        reason: 'tapping an empty day opened nothing',
      );
      expect(location, contains('venueId=v1'));
      expect(location, contains('lockVenue=1'));
      expect(location, contains('date=${dayKey(10)}'));
    });

    testWidgets('a venue this account does not manage stays read-only', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        const EventsListPage(
          venueMode: true,
          venueId: 'v2',
          venueName: 'Not Mine',
        ),
      );

      // The server refuses such a write, so the button must not exist rather
      // than fail when pressed.
      expect(find.byType(FloatingActionButton), findsNothing);
      await tapDay(tester, 10);
      expect(pushed(tester, newEventMarker), isNull);
    });
  });

  group('a performer calendar', () {
    testWidgets('an empty day starts a new event seeded with the act', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        const EventsListPage(myPerformerIds: ['p1'], performerName: 'My Band'),
      );
      await tapDay(tester, 10);

      final location = pushed(tester, newEventMarker);
      expect(
        location,
        isNotNull,
        reason: 'tapping an empty day opened nothing',
      );
      expect(location, contains('performerId=p1'));
      expect(location, contains('date=${dayKey(10)}'));
      // An act plays wherever it is booked, so the venue stays a choice.
      expect(location, isNot(contains('lockVenue')));
    });

    testWidgets('somebody else\'s act stays read-only', (tester) async {
      await pumpCalendar(
        tester,
        const EventsListPage(
          myPerformerIds: ['p2'],
          performerName: 'Someone Else',
        ),
      );

      expect(find.byType(FloatingActionButton), findsNothing);
      await tapDay(tester, 10);
      expect(pushed(tester, newEventMarker), isNull);
    });

    testWidgets('a booked day opens the sheet, which can add and edit', (
      tester,
    ) async {
      h.pb
          .records('events')
          .add(
            eventRecord(
              'e15',
              start: DateTime(now.year, now.month, 15, 20),
              end: DateTime(now.year, now.month, 15, 22),
              performers: const ['p1'],
            ),
          );
      await pumpCalendar(
        tester,
        const EventsListPage(myPerformerIds: ['p1'], performerName: 'My Band'),
      );
      await tapDay(tester, 15);

      // A booked day lists its events and still offers to add one.
      expect(find.text('Gig'), findsOneWidget);
      expect(find.text(strings.addEvent), findsOneWidget);

      await tester.tap(find.text('Gig'));
      await tester.pumpAndSettle();
      expect(pushed(tester, editEventMarker), contains('/events/e15/edit'));
    });
  });

  group('the combined calendar', () {
    testWidgets('asks which assignment a new event is for, then seeds it', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        const EventsListPage(
          combinedMode: true,
          myPerformerIds: ['p1'],
          myVenueIds: ['v1'],
        ),
      );
      await tapDay(tester, 10);

      // It covers several assignments, so it asks instead of guessing one.
      expect(find.text(strings.createForPerformer), findsOneWidget);
      expect(find.text(strings.createForVenue), findsOneWidget);
      expect(
        pushed(tester, newEventMarker),
        isNull,
        reason: 'it must not open the form before knowing the owner',
      );

      await tester.tap(find.text('My Hall').last);
      await tester.pumpAndSettle();

      final location = pushed(tester, newEventMarker);
      expect(location, contains('venueId=v1'));
      expect(location, contains('lockVenue=1'));
      expect(location, contains('date=${dayKey(10)}'));
    });

    testWidgets('with nothing assigned it offers no create at all', (
      tester,
    ) async {
      // The combined calendar of an account with no assignment has nothing the
      // server would authorize a write against.
      h.pb.records('memberships').clear();
      await h.warm(force: true);

      await pumpCalendar(tester, const EventsListPage(combinedMode: true));
      expect(find.byType(FloatingActionButton), findsNothing);
      await tapDay(tester, 10);
      expect(pushed(tester, newEventMarker), isNull);
    });
  });

  group('the create button', () {
    testWidgets('names what the event will be for, per view', (tester) async {
      await pumpCalendar(
        tester,
        const EventsListPage(
          venueMode: true,
          venueId: 'v1',
          venueName: 'My Hall',
        ),
      );
      expect(find.byTooltip(strings.newEventForVenue), findsOneWidget);

      await pumpCalendar(
        tester,
        const EventsListPage(myPerformerIds: ['p1'], performerName: 'My Band'),
      );
      expect(find.byTooltip(strings.newEventForPerformer), findsOneWidget);

      await pumpCalendar(
        tester,
        const EventsListPage(
          combinedMode: true,
          myPerformerIds: ['p1'],
          myVenueIds: ['v1'],
        ),
      );
      expect(find.byTooltip(strings.newEvent), findsOneWidget);
    });

    testWidgets('exists exactly once on a calendar tab', (tester) async {
      // The tab screen used to add a button of its own on top of the one its
      // pages already had: for a venue tab that was two buttons in one place.
      await h.pump(tester, const UserCalendarTabs());
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.tap(find.text('My Hall'));
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });
  });
}
