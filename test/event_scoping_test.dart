import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:acorde/screens/events_list.dart';
import 'package:acorde/screens/upcoming.dart';
import 'package:acorde/screens/user_dashboard.dart';
import 'package:acorde/widgets/calendar_grid.dart';

import 'support/screen_harness.dart';

/// Both screens that show an account its schedule agree about what is in it.
///
/// This is the regression suite for a real bug: a booking that touched none of
/// the account's assignments appeared in Próximos, and the calendar's Combinado
/// tab — which is where tapping a day took you — did not contain it. The row was
/// in the list, and the day it named was empty in the destination of the tap.
///
/// The cause was not one screen being wrong: they were *both* reasonable and
/// they disagreed. `events_list.dart` used its copy of "is this event mine" to
/// filter, and `upcoming.dart` used its copy only to choose a colour. Two
/// functions that happened to share a name and nothing else. They now share one
/// implementation (`lib/utils/event_scope.dart`), and these tests hold the two
/// screens to the same answer.
///
/// The assertions read the event list each screen resolved rather than pixel
/// state: "which bookings did this screen decide are this account's" is the
/// decision under test, and it is the same question on both screens. What is
/// drawn from that list is covered by each screen's own suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
  });

  Map<String, dynamic> at(
    DateTime local,
    String id,
    String title, {
    String? venueId,
    List<String> performers = const [],
  }) => {
    'id': id,
    'title': title,
    'start': local.toUtc().toIso8601String(),
    'end': local.add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'venueId': venueId,
    'performers': performers,
    'createdBy': ScreenHarness.userId,
    'created': '2026-01-01T00:00:00.000Z',
  };

  /// A moment both screens can see: tomorrow evening.
  ///
  /// It has to be in the future for the upcoming list (`end > now`) and inside a
  /// month the calendar is showing. Tomorrow satisfies the first by
  /// construction; the second is handled by giving the calendar that month
  /// explicitly rather than assuming today's, which would break on the last day
  /// of a month.
  DateTime fixtureMoment() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1, 20);
  }

  /// The month [fixtureMoment] falls in, as the calendar wants it.
  DateTime fixtureMonth() {
    final m = fixtureMoment();
    return DateTime(m.year, m.month);
  }

  /// One booking of each kind. `viaAct` and `viaVenue` and `both` are this
  /// account's by three different routes; `theirs` touches nothing of its.
  void seedMixed() {
    final d = fixtureMoment();
    h.pb.records('events')
      ..add(at(d, 'e-act', 'Via Act', performers: const ['p1']))
      ..add(at(d, 'e-venue', 'Via Venue', venueId: 'v1'))
      ..add(
        at(d, 'e-both', 'Via Both', venueId: 'v1', performers: const ['p1']),
      )
      ..add(
        at(d, 'e-theirs', 'Theirs', venueId: 'v2', performers: const ['p2']),
      );
  }

  /// Titles on the upcoming screen, in order.
  Future<List<String>> upcomingTitles(WidgetTester tester) async {
    await h.pump(tester, const UpcomingPage());
    await h.events.upcoming(force: true);
    await tester.pumpAndSettle();
    final shown = <String>{'Via Act', 'Via Venue', 'Via Both', 'Theirs'};
    return tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where(shown.contains)
        .toList();
  }

  /// Ids of the events the calendar resolved for its focused month, read off the
  /// grid it built.
  Future<Set<String>> calendarIds(WidgetTester tester) async {
    await h.pump(
      tester,
      EventsListPage(
        combinedMode: true,
        myPerformerIds: const ['p1'],
        myVenueIds: const ['v1'],
        // Pinned to the fixture's month rather than the current one, so this
        // holds whatever day of the month the suite happens to run on.
        initialMonth: fixtureMonth(),
      ),
    );
    await tester.pumpAndSettle();
    final grid = tester.widget<CalendarGrid>(find.byType(CalendarGrid));
    return {
      for (final e in grid.events)
        if (e.id != null) e.id!,
    };
  }

  testWidgets('the upcoming list hides a booking that touches no assignment', (
    tester,
  ) async {
    seedMixed();
    final titles = await upcomingTitles(tester);

    expect(titles, containsAll(['Via Act', 'Via Venue', 'Via Both']));
    expect(
      titles,
      isNot(contains('Theirs')),
      reason: 'a booking touching nothing of this account was listed',
    );
  });

  testWidgets('the calendar resolves exactly the same set', (tester) async {
    seedMixed();
    final ids = await calendarIds(tester);

    expect(ids, containsAll(['e-act', 'e-venue', 'e-both']));
    expect(
      ids,
      isNot(contains('e-theirs')),
      reason: 'the calendar resolved a booking that touches no assignment',
    );
  });

  /// The bug, stated as one assertion: no booking is visible in one screen and
  /// absent from the other. Written against the two screens rather than against
  /// the predicate, because the predicate agreeing with itself is not the thing
  /// that broke — the two SCREENS disagreeing was.
  testWidgets('the two screens agree, booking for booking', (tester) async {
    seedMixed();

    final listed = await upcomingTitles(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    final marked = await calendarIds(tester);

    // Map titles back to the ids the calendar deals in.
    const byTitle = {
      'Via Act': 'e-act',
      'Via Venue': 'e-venue',
      'Via Both': 'e-both',
      'Theirs': 'e-theirs',
    };
    final fromList = {for (final t in listed) byTitle[t]!};

    expect(
      fromList,
      marked,
      reason:
          'Próximos and the calendar disagree: '
          'listed=${fromList.difference(marked)} '
          'calendar-only=${marked.difference(fromList)}',
    );
  });

  /// The dashboard's preview is the third consumer of the same list, and it
  /// framed itself as "what is next for you" too.
  testWidgets('the dashboard preview scopes the same way', (tester) async {
    seedMixed();
    await h.pump(tester, const UserDashboardPage());
    await h.events.upcoming(force: true);
    await tester.pumpAndSettle();

    expect(find.text('Via Act'), findsOneWidget);
    expect(
      find.text('Theirs'),
      findsNothing,
      reason: 'the dashboard preview showed somebody else\'s booking',
    );
  });
}
