import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:acorde/models/event.dart';
import 'package:acorde/screens/upcoming.dart';
import 'package:acorde/screens/user_dashboard.dart';
import 'package:acorde/utils/calendar_math.dart';

import 'support/screen_harness.dart';

/// The upcoming list: what is next, for this account.
///
/// Two things are worth pinning here. The first is the question it answers — an
/// event that has already finished must not appear, and one that is happening
/// right now must, because "what's on" includes what is currently on. The
/// server filter says `end > now` for exactly that reason, and these tests hold
/// the client to the same line rather than trusting the server to have done it.
///
/// The second is deletion, which is the only destructive action in the app: a
/// repeating booking must be asked about, since deleting a whole series by
/// accident cannot be undone.
///
/// The list is also *scoped* — it shows the events that touch one of this
/// account's assignments, not every event on the server. That is covered by
/// `event_scoping_test.dart`, which holds it and the calendar to the same
/// answer; the fixtures here are in scope so that what they assert is about
/// time and deletion rather than about scoping.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  /// A booking `days` from now, at a fixed hour so the grouping is predictable.
  Map<String, dynamic> booking(
    String id, {
    required int days,
    String title = 'Gig',
    String? venueId,
    List<String> performers = const [],
    String? seriesId,
    String? createdBy,
  }) {
    final start = DateTime.now().add(Duration(days: days));
    final at = DateTime(start.year, start.month, start.day, 20);
    return {
      'id': id,
      'title': title,
      'start': at.toUtc().toIso8601String(),
      'end': at.add(const Duration(hours: 2)).toUtc().toIso8601String(),
      'venueId': ?venueId,
      'performers': performers,
      'createdBy': createdBy ?? ScreenHarness.userId,
      'created': '2026-01-01T00:00:00.000Z',
      'seriesId': ?seriesId,
    };
  }

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
    h.seedEntities();
    await h.warm();
  });

  Future<void> pumpUpcoming(WidgetTester tester) async {
    await h.pump(tester, const UpcomingPage());
    // The page starts its own query; let it land.
    await h.events.upcoming(force: true);
    await tester.pumpAndSettle();
  }

  group('what it shows', () {
    testWidgets('lists a booking that is still to come', (tester) async {
      h.pb
          .records('events')
          .add(
            booking(
              'e-soon',
              days: 3,
              title: 'Later Tonight',
              performers: const ['p1'],
            ),
          );
      await pumpUpcoming(tester);

      expect(find.text('Later Tonight'), findsOneWidget);
      // The act resolves to a name, not an id.
      expect(find.textContaining('My Band'), findsOneWidget);
    });

    testWidgets('shows events in date order', (tester) async {
      // All three are booked for the act this account belongs to, which is what
      // puts them in scope — an event touching no assignment is not this
      // account's and is not listed (see the scoping group below).
      h.pb.records('events')
        ..add(
          booking(
            'e-late',
            days: 30,
            title: 'Far Off',
            performers: const ['p1'],
          ),
        )
        ..add(
          booking(
            'e-next',
            days: 1,
            title: 'Tomorrow',
            performers: const ['p1'],
          ),
        )
        ..add(
          booking(
            'e-mid',
            days: 7,
            title: 'Next Week',
            performers: const ['p1'],
          ),
        );
      await pumpUpcoming(tester);

      final titles = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => d == 'Tomorrow' || d == 'Next Week' || d == 'Far Off')
          .toList();
      expect(titles, ['Tomorrow', 'Next Week', 'Far Off']);
    });

    testWidgets('leaves out a booking that has already finished', (
      tester,
    ) async {
      h.pb.records('events')
        ..add(
          booking(
            'e-past',
            days: -5,
            title: 'Long Gone',
            performers: const ['p1'],
          ),
        )
        ..add(
          booking(
            'e-future',
            days: 2,
            title: 'Still To Come',
            performers: const ['p1'],
          ),
        );
      await pumpUpcoming(tester);

      expect(find.text('Still To Come'), findsOneWidget);
      expect(find.text('Long Gone'), findsNothing);
    });

    /// A booking that started an hour ago and runs for another hour is the most
    /// immediate thing on the schedule, so "upcoming" has to include it — that
    /// is why the query bounds on `end` rather than `start`.
    testWidgets('includes a booking that is happening right now', (
      tester,
    ) async {
      final now = DateTime.now();
      h.pb.records('events').add({
        'id': 'e-now',
        'title': 'On Right Now',
        'start': now
            .subtract(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
        'end': now.add(const Duration(hours: 1)).toUtc().toIso8601String(),
        'performers': const ['p1'],
        'createdBy': ScreenHarness.userId,
        'created': '2026-01-01T00:00:00.000Z',
      });
      await pumpUpcoming(tester);

      expect(find.text('On Right Now'), findsOneWidget);
    });

    testWidgets('says so when there is nothing coming up', (tester) async {
      await pumpUpcoming(tester);
      expect(find.text(strings.noUpcoming), findsOneWidget);
    });
  });

  group('the dashboard preview', () {
    /// The wiring bug this guards: the card renders nothing until the query has
    /// answered, so a dashboard that never *asks* would show no preview at all on
    /// a fresh session — the case it exists for.
    testWidgets('shows what is next without opening the list', (tester) async {
      h.pb
          .records('events')
          .add(
            booking(
              'e-soon',
              days: 4,
              title: 'Rehearsal',
              performers: const ['p1'],
            ),
          );
      await h.pump(tester, const UserDashboardPage());
      await tester.pumpAndSettle();

      expect(find.text(strings.upcomingEvents), findsOneWidget);
      expect(find.text('Rehearsal'), findsOneWidget);
      expect(find.text(strings.upcomingSeeAll), findsOneWidget);
    });

    testWidgets('says there is nothing when there is nothing', (tester) async {
      await h.pump(tester, const UserDashboardPage());
      await tester.pumpAndSettle();

      expect(find.text(strings.upcomingEvents), findsOneWidget);
      expect(find.text(strings.noUpcoming), findsOneWidget);
    });
  });

  group('deleting', () {
    testWidgets('is offered on a booking this account may change', (
      tester,
    ) async {
      h.pb
          .records('events')
          .add(booking('e-mine', days: 2, performers: const ['p1']));
      await pumpUpcoming(tester);

      expect(find.byTooltip(strings.deleteEvent), findsOneWidget);
    });

    /// The server allows a write for a venue this account manages, an act it
    /// The withholding this screen used to do is now structural.
    ///
    /// The list is scoped to this account's assignments, and the server's write
    /// rule is the *same* disjunction — a venue you manage, an act you belong
    /// to, or an event you created. So a booking that survives the scope filter
    /// is one the guard would accept a write to, and the "may not change" case
    /// is no longer reachable from this screen: it is filtered out before it can
    /// be drawn, which is the assertion below. (The rule is not deleted from the
    /// row — it mirrors the server, and the two must keep agreeing — but this
    /// screen can no longer produce a counter-example to it.)
    testWidgets('is not listed when it touches no assignment', (tester) async {
      h.pb
          .records('events')
          .add(
            booking(
              'e-theirs',
              days: 2,
              title: 'Not Mine',
              performers: const ['p2'],
              venueId: 'v2',
              createdBy: 'someone-else',
            ),
          );
      await pumpUpcoming(tester);

      expect(
        find.text('Not Mine'),
        findsNothing,
        reason: 'a booking touching nothing of this account was listed',
      );
    });

    testWidgets('asks first, and backing out deletes nothing', (tester) async {
      h.pb
          .records('events')
          .add(booking('e-mine', days: 2, performers: const ['p1']));
      await pumpUpcoming(tester);

      await tester.tap(find.byTooltip(strings.deleteEvent));
      await tester.pumpAndSettle();
      expect(find.text(strings.confirmDeleteBody), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, strings.cancel));
      await tester.pumpAndSettle();
      expect(h.pb.count('DELETE events'), 0);
      expect(find.text('Gig'), findsOneWidget);
    });

    testWidgets('confirming deletes it and it leaves the list', (tester) async {
      h.pb
          .records('events')
          .add(booking('e-mine', days: 2, performers: const ['p1']));
      await pumpUpcoming(tester);

      await tester.tap(find.byTooltip(strings.deleteEvent));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, strings.delete));
      await tester.pumpAndSettle();

      expect(h.pb.count('DELETE events'), 1);
      expect(h.pb.records('events'), isEmpty);
      expect(find.text('Gig'), findsNothing);
      expect(find.text(strings.noUpcoming), findsOneWidget);
    });
  });

  group('a repeating booking', () {
    /// The case the extra question exists for: "delete the event" on one night of
    /// a weekly series is almost never what is meant, and the reverse mistake
    /// cannot be undone.
    testWidgets(
      'asks whether one or the whole series, and can delete just one',
      (tester) async {
        h.pb.records('events')
          ..add(
            booking(
              'e-1',
              days: 2,
              title: 'Weekly',
              performers: const ['p1'],
              seriesId: 's1',
            ),
          )
          ..add(
            booking(
              'e-2',
              days: 9,
              title: 'Weekly',
              performers: const ['p1'],
              seriesId: 's1',
            ),
          )
          ..add(
            booking(
              'e-3',
              days: 16,
              title: 'Weekly',
              performers: const ['p1'],
              seriesId: 's1',
            ),
          );
        await pumpUpcoming(tester);

        // Three instances, so three delete buttons; take the first.
        await tester.tap(find.byTooltip(strings.deleteEvent).first);
        await tester.pumpAndSettle();

        expect(find.text(strings.deleteSeriesTitle), findsOneWidget);
        // The count comes from the server's own instances, not from a local
        // recomputation of the rule.
        expect(find.text(strings.deleteSeriesAll(3)), findsOneWidget);

        await tester.tap(
          find.widgetWithText(TextButton, strings.deleteSeriesOne),
        );
        await tester.pumpAndSettle();

        expect(h.pb.count('DELETE events'), 1);
        expect(h.pb.records('events').length, 2);
      },
    );

    testWidgets('deleting the whole series removes every instance', (
      tester,
    ) async {
      h.pb.records('events')
        ..add(
          booking(
            'e-1',
            days: 2,
            title: 'Weekly',
            performers: const ['p1'],
            seriesId: 's1',
          ),
        )
        ..add(
          booking(
            'e-2',
            days: 9,
            title: 'Weekly',
            performers: const ['p1'],
            seriesId: 's1',
          ),
        )
        ..add(
          booking(
            'e-3',
            days: 16,
            title: 'Weekly',
            performers: const ['p1'],
            seriesId: 's1',
          ),
        );
      await pumpUpcoming(tester);

      await tester.tap(find.byTooltip(strings.deleteEvent).first);
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, strings.deleteSeriesAll(3)),
      );
      await tester.pumpAndSettle();

      expect(h.pb.count('DELETE events'), 3);
      expect(h.pb.records('events'), isEmpty);
      expect(find.text(strings.noUpcoming), findsOneWidget);
    });
  });

  group('naming', () {
    /// The rule the shared helper exists to enforce: an id that no longer
    /// resolves must never be shown raw. Two screens render events (this list and
    /// the calendar's day sheet) and both read it from here, so this is where the
    /// guarantee belongs.
    testWidgets('a dangling venue id is labelled, not printed', (tester) async {
      h.pb
          .records('events')
          .add(
            booking(
              'e-x',
              days: 3,
              title: 'Orphaned',
              // In scope through its act, so the row is listed and the dangling
              // VENUE is what this test is about. A booking with no assignment
              // at all would be filtered out before naming ever ran.
              performers: const ['p1'],
              venueId: 'gone-venue',
            ),
          );
      await pumpUpcoming(tester);

      expect(find.text('Orphaned'), findsOneWidget);
      expect(find.textContaining('gone-venue'), findsNothing);
      expect(find.textContaining(strings.eventVenueMissing), findsOneWidget);
    });

    testWidgets('a booking with no venue shows no venue line', (tester) async {
      h.pb
          .records('events')
          .add(
            booking(
              'e-y',
              days: 3,
              title: 'Act Only',
              performers: const ['p1'],
            ),
          );
      await pumpUpcoming(tester);

      // Not "no longer exists": an act's booking does not have to name a room,
      // which is a different fact from a room that vanished.
      expect(find.textContaining(strings.eventVenueMissing), findsNothing);
      expect(find.textContaining('My Band'), findsOneWidget);
    });
  });

  group('the repository', () {
    test('drops the whole upcoming state on sign-out', () async {
      h.pb
          .records('events')
          .add(booking('e-1', days: 2, performers: const ['p1']));
      await h.events.upcoming(force: true);
      expect(h.events.upcomingEvents, isNotEmpty);

      h.events.reset();

      // The next account must not inherit the previous one's schedule, which is
      // exactly what a surviving list would show.
      expect(h.events.upcomingEvents, isNull);
      expect(h.events.upcomingStale, isFalse);
    });

    test(
      'keeps the last answer and flags it stale when the server is gone',
      () async {
        h.pb
            .records('events')
            .add(booking('e-1', days: 2, performers: const ['p1']));
        await h.events.upcoming(force: true);
        final before = h.events.upcomingEvents;
        expect(before, isNotEmpty);

        // A transport failure rather than an HTTP error: that is what "offline"
        // looks like to the client.
        h.pb.intercept = (request) async {
          if (request.method == 'GET' &&
              request.url.path.contains('/events/')) {
            throw Exception('offline');
          }
          return null;
        };

        final after = await h.events.upcoming(force: true);

        expect(h.events.upcomingStale, isTrue);
        expect(
          after.length,
          before!.length,
          reason: 'the previous schedule is still worth showing',
        );
      },
    );

    test('an event that finished is not upcoming', () async {
      h.pb.records('events')
        ..add(booking('e-past', days: -3, title: 'Past'))
        ..add(booking('e-future', days: 3, title: 'Future'));
      final items = await h.events.upcoming(force: true);

      final titles = [for (final Event e in items) e.title];
      expect(titles, contains('Future'));
      expect(titles, isNot(contains('Past')));
    });
  });

  /// Grouping by month, and the way out of the list into the calendar.
  ///
  /// The day headers alone were ambiguous in a long list: "sexta-feira, 25 de
  /// setembro" followed eventually by "sábado, 7 de novembro" says nothing about
  /// the month having turned, which is exactly what somebody scanning for "how
  /// far out does this go" is trying to find out. So a month heading is drawn
  /// above the first day of each month, and it has to be *above* — a marker that
  /// appears after its own days is not a marker.
  ///
  /// The second half is the handoff: tapping a day header opens the calendar on
  /// that day's month. It is asserted through the control the user presses and
  /// against the month that arrives in the route, because "the tap does
  /// something" and "it lands on the right month" are separate claims.
  group('month grouping and the calendar handoff', () {
    /// The last moment of the current month. Paired with the first of the next
    /// month it is the one boundary that exists whenever these tests run, so the
    /// assertions do not depend on which month it happens to be.
    DateTime endOfThisMonth() {
      final now = DateTime.now();
      return DateTime(now.year, now.month + 1, 0, 20);
    }

    Map<String, dynamic> at(DateTime local, String id, String title) => {
      'id': id,
      'title': title,
      'start': local.toUtc().toIso8601String(),
      'end': local.add(const Duration(hours: 2)).toUtc().toIso8601String(),
      'venueId': null,
      'performers': const ['p1'],
      'createdBy': ScreenHarness.userId,
      'created': '2026-01-01T00:00:00.000Z',
    };

    testWidgets('heads each new month, above that month\'s days', (
      tester,
    ) async {
      final lastDay = endOfThisMonth();
      final firstNext = DateTime(lastDay.year, lastDay.month + 1, 1, 20);
      h.pb.records('events')
        ..add(at(lastDay, 'e-m1', 'Boundary Night'))
        ..add(at(firstNext, 'e-m2', 'New Month Night'));
      await pumpUpcoming(tester);

      final thisMonth = monthLabel('pt', lastDay);
      final nextMonth = monthLabel('pt', firstNext);
      expect(monthLabel('pt', lastDay), isNot(nextMonth));
      expect(find.text(thisMonth), findsOneWidget);
      expect(find.text(nextMonth), findsOneWidget);

      // The heading precedes the day header it belongs to, measured rather than
      // assumed: both are Texts, so only their positions say which is which.
      final monthHeader = tester.getTopLeft(find.text(thisMonth)).dy;
      final dayHeader = tester
          .getTopLeft(find.text(formatFullDate('pt', lastDay)))
          .dy;
      expect(
        monthHeader,
        lessThan(dayHeader),
        reason: 'the month heading is not above its own day header',
      );
      // And the second month's heading sits below the first month's day.
      expect(
        tester.getTopLeft(find.text(nextMonth)).dy,
        greaterThan(dayHeader),
      );
    });

    testWidgets('tapping a day header opens the calendar on that month', (
      tester,
    ) async {
      final lastDay = endOfThisMonth();
      h.pb.records('events').add(at(lastDay, 'e-m1', 'Boundary Night'));

      // The harness's router has no `/calendar`, and a push to an unmatched
      // location lands on go_router's error page — where "navigated" and
      // "failed to navigate" look identical. So the destination gets a route
      // that reports the month it was handed.
      await h.pump(
        tester,
        const UpcomingPage(),
        routes: [
          GoRoute(
            path: '/calendar',
            builder: (context, state) => Scaffold(
              body: Center(
                child: Text(
                  'CALENDAR ${state.uri.queryParameters['month'] ?? 'none'}',
                ),
              ),
            ),
          ),
        ],
      );
      await h.events.upcoming(force: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(strings.openInCalendar));
      await tester.pumpAndSettle();

      final expected =
          '${lastDay.year}-${lastDay.month.toString().padLeft(2, '0')}';
      expect(
        find.text('CALENDAR $expected'),
        findsOneWidget,
        reason: 'the day header did not hand the calendar the right month',
      );
    });
  });
}
