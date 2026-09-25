import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import 'package:acorde/models/membership.dart';
import 'package:acorde/screens/entity_browse.dart';

import 'support/screen_harness.dart';

/// The public venue/performer browse lists — the screen somebody who has been
/// added to nothing arrives at to find their own venue or act.
///
/// Which makes the per-row actions the whole feature: a row is either something
/// this account manages (book it, edit it), something they may ask to join, or
/// something they have already asked for and are waiting on. The three branches
/// are reached from state `AssignmentsController` derives, so every test seeds
/// the membership rows the state comes from and completes a load pass before
/// pumping — a screen whose assignments have not been computed renders all three
/// as "ask to join".
///
/// Both kinds are asserted. The screen is deliberately one implementation for
/// two collections, and a venue-only test would catch none of the performer
/// regressions that indirection can introduce — starting with the calendar
/// location: a performer routed as a venue silently opens the wrong list, which
/// only an assertion on the pushed location can see.
///
/// Actions are asserted through their tooltips, because an icon-only button's
/// tooltip is the only thing that tells a user which of two identical-looking
/// plus buttons they are about to press. (`IconButton` exposes its tooltip as
/// the semantics element's text, not as `aria-label`; `find.byTooltip` is the
/// matcher that reads it either way.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScreenHarness h;

  setUp(() async {
    h = ScreenHarness();
    await h.boot();
  });

  /// The harness's two-entity fixture — one of each kind this account manages,
  /// one it does not — with a completed load pass behind it (see
  /// [ScreenHarness.warm]).
  Future<void> seedBrowse() async {
    h.seedEntities();
    await h.warm();
  }

  /// Demotes this account's row on the entity it manages to a plain `member`.
  ///
  /// The two roles differ in exactly one way that matters here: the server lets
  /// a member book events (`events.guard.pb.js` accepts any active membership)
  /// but refuses a rename, a delete or a roster change unless the row is an
  /// active **manager** (`entities.guard.pb.js`). The row actions have to split
  /// the same way, or the screen offers a control whose only outcome is a 403.
  Future<void> demoteToMember(_Kind kind) async {
    for (final record in h.pb.records('memberships')) {
      if (record['targetId'] == kind.mineId) {
        record['role'] = 'member';
      }
    }
    await h.warm(force: true);
  }

  /// Adds a join request of this user's own that no manager has answered yet,
  /// plus a third entity nobody has asked for.
  ///
  /// The third row is what makes the pending assertion a branch rather than a
  /// screen-wide constant: "request is absent" is only meaningful next to a
  /// request button that is still there.
  Future<void> seedPendingRequest(_Kind kind) async {
    h.pb.records('memberships').add({
      'id': 'm-request',
      'userId': ScreenHarness.userId,
      'targetId': kind.otherId,
      'targetType': kind.wire,
      'role': 'member',
      'status': 'pending',
      'initiatedBy': 'request',
    });
    h.pb.records(kind.collection).add({
      'id': kind.thirdId,
      'name': kind.thirdName,
    });
    await h.warm(force: true);
  }

  /// Every request that hit the join route, in order.
  ///
  /// The route lives outside `/api/collections/...`, so the path is the handle.
  /// Asserting the received request is how these tests check the wire contract
  /// the hook is built against, rather than the client that built it.
  List<http.Request> joinRequests() => [
    for (final request in h.pb.requests)
      if (request.url.path == '/api/agenda/join') request,
  ];

  for (final kind in _kinds) {
    group('${kind.wire} browse', () {
      testWidgets(
        'an unmanaged entity offers to request access, and nothing else',
        (tester) async {
          await seedBrowse();

          await h.pump(tester, kind.page);

          expect(
            _inRowOf(kind.otherName, find.byTooltip(strings.requestAccess)),
            findsOneWidget,
          );
          expect(
            _inRowOf(kind.otherName, find.byTooltip(kind.manageTooltip)),
            findsNothing,
          );
          expect(
            _inRowOf(kind.otherName, find.byTooltip(kind.eventTooltip)),
            findsNothing,
          );
        },
      );

      testWidgets('a managed entity offers to book and to manage, not to request', (
        tester,
      ) async {
        await seedBrowse();

        await h.pump(tester, kind.page);

        expect(
          _inRowOf(kind.mineName, find.byTooltip(kind.manageTooltip)),
          findsOneWidget,
        );
        expect(
          _inRowOf(kind.mineName, find.byTooltip(kind.eventTooltip)),
          findsOneWidget,
        );
        expect(
          _inRowOf(kind.mineName, find.byTooltip(strings.requestAccess)),
          findsNothing,
        );
        // The fixture's other row is unmanaged, so these are a comparison of two
        // rows in one state each — not a screen that shows the same action twice.
        expect(
          _inRowOf(kind.otherName, find.byTooltip(kind.manageTooltip)),
          findsNothing,
        );
      });

      testWidgets('a membership lets this account book, but not manage', (
        tester,
      ) async {
        await seedBrowse();
        await demoteToMember(kind);

        await h.pump(tester, kind.page);

        // Booking stays: any active membership may write events for the entity.
        expect(
          _inRowOf(kind.mineName, find.byTooltip(kind.eventTooltip)),
          findsOneWidget,
        );
        // Managing goes: the server refuses it for a plain member, so the row
        // must not offer it. This is the regression guard for a `member` being
        // handed an edit button that could only ever return 403.
        expect(
          _inRowOf(kind.mineName, find.byTooltip(kind.manageTooltip)),
          findsNothing,
        );
        // And it must not fall through to "ask to join" either — they already
        // have access, so offering to request it would be nonsense.
        expect(
          _inRowOf(kind.mineName, find.byTooltip(strings.requestAccess)),
          findsNothing,
        );
      });

      testWidgets("an unanswered request of one's own shows as pending", (
        tester,
      ) async {
        await seedBrowse();
        await seedPendingRequest(kind);

        await h.pump(tester, kind.page);

        // Asking twice is refused by the server, so the row must not offer it
        // again — the waiting state stands in for the button.
        expect(
          _inRowOf(kind.otherName, find.byTooltip(strings.requestPending)),
          findsOneWidget,
        );
        expect(
          _inRowOf(kind.otherName, find.byTooltip(strings.requestAccess)),
          findsNothing,
        );
        expect(
          _inRowOf(kind.thirdName, find.byTooltip(strings.requestPending)),
          findsNothing,
        );
        expect(
          _inRowOf(kind.thirdName, find.byTooltip(strings.requestAccess)),
          findsOneWidget,
        );
      });

      testWidgets("tapping a row opens that entity's own calendar", (
        tester,
      ) async {
        await seedBrowse();

        await h.pump(tester, kind.page, routes: _destinationRoutes);

        await tester.tap(find.text(kind.otherName));
        await tester.pumpAndSettle();

        expect(find.text('AT ${kind.calendarLocation}'), findsOneWidget);
      });

      testWidgets(
        "requesting access posts the row's own target and reports it sent",
        (tester) async {
          await seedBrowse();

          await h.pump(tester, kind.page);

          await tester.tap(find.byTooltip(strings.requestAccess));
          await tester.pumpAndSettle();

          final posted = joinRequests();
          expect(posted, hasLength(1));
          expect(jsonDecode(posted.single.body), {
            'targetType': kind.wire,
            'targetId': kind.otherId,
            'role': 'member',
          });
          expect(find.text(strings.requestSent), findsOneWidget);
          // The read the screen makes after asking is what turns the button into
          // the waiting state, which is the whole reason the request is offered
          // here rather than by a form.
          expect(
            _inRowOf(kind.otherName, find.byTooltip(strings.requestPending)),
            findsOneWidget,
          );
          expect(
            _inRowOf(kind.otherName, find.byTooltip(strings.requestAccess)),
            findsNothing,
          );
        },
      );

      testWidgets('the app bar links to the other kind', (tester) async {
        await seedBrowse();

        await h.pump(tester, kind.page, routes: _destinationRoutes);

        await tester.tap(find.byTooltip(kind.siblingTooltip));
        await tester.pumpAndSettle();

        expect(find.text('AT ${kind.siblingLocation}'), findsOneWidget);
      });

      testWidgets("a managed row's manage action opens its editor", (
        tester,
      ) async {
        await seedBrowse();

        await h.pump(tester, kind.page, routes: _destinationRoutes);

        await tester.tap(find.byTooltip(kind.manageTooltip));
        await tester.pumpAndSettle();

        expect(find.text(kind.editMarker(kind.mineId)), findsOneWidget);
      });

      testWidgets(
        "a managed row's booking action opens a form prefilled for it",
        (tester) async {
          await seedBrowse();

          await h.pump(tester, kind.page, routes: _destinationRoutes);

          await tester.tap(find.byTooltip(kind.eventTooltip));
          await tester.pumpAndSettle();

          expect(find.text('AT ${kind.newEventLocation}'), findsOneWidget);
        },
      );

      testWidgets('an empty list still offers the way forward', (tester) async {
        // Nothing seeded at all: the list a brand-new account sees.
        await h.warm();

        await h.pump(tester, kind.page, routes: _destinationRoutes);

        expect(find.text(kind.emptyMessage), findsOneWidget);

        await tester.tap(find.byTooltip(kind.addLabel));
        await tester.pumpAndSettle();

        expect(find.text('AT ${kind.newLocation}'), findsOneWidget);
      });
    });
  }
}

/// The action widgets [matching] in the row titled [name].
///
/// Scoping is what makes these assertions about the entity they name: every row
/// renders its trailing action from the same branch, so a screen-wide "the
/// request button is gone" would also pass on a screen that had moved it to the
/// wrong row. A row is located by its title, the only handle a user has on it.
Finder _inRowOf(String name, Finder matching) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
  matching: matching,
);

/// Route markers for the locations the browse lists push to.
///
/// The harness registers only the two edit routes; a push to a location the
/// router cannot match lands on go_router's error page, where "navigated" and
/// "failed to navigate" look the same from the widget tree. Each marker renders
/// the location the router resolved for it, so a test can assert *where* a tap
/// went — and the two kinds differ there, which is the point.
Widget _locationMarker(GoRouterState state) =>
    Scaffold(body: Center(child: Text('AT ${state.uri}')));

final List<RouteBase> _destinationRoutes = [
  GoRoute(
    path: '/calendar/:type/:id',
    builder: (context, state) => _locationMarker(state),
  ),
  GoRoute(path: '/venues', builder: (context, state) => _locationMarker(state)),
  GoRoute(
    path: '/performers',
    builder: (context, state) => _locationMarker(state),
  ),
  GoRoute(
    path: '/venues/new',
    builder: (context, state) => _locationMarker(state),
  ),
  GoRoute(
    path: '/performers/new',
    builder: (context, state) => _locationMarker(state),
  ),
  GoRoute(
    path: '/events/new',
    builder: (context, state) => _locationMarker(state),
  ),
];

/// One browse list's worth of ids, labels and destinations.
///
/// Literal locations rather than [entityCalendarPath] and friends: an assertion
/// built from the same builder the screen uses would agree with a wrong builder,
/// and the URL is the contract here.
class _Kind {
  const _Kind({
    required this.wire,
    required this.collection,
    required this.page,
    required this.mineId,
    required this.mineName,
    required this.otherId,
    required this.otherName,
    required this.thirdId,
    required this.thirdName,
    required this.manageTooltip,
    required this.eventTooltip,
    required this.addLabel,
    required this.emptyMessage,
    required this.siblingTooltip,
    required this.siblingLocation,
    required this.calendarLocation,
    required this.newLocation,
    required this.newEventLocation,
    required this.editMarker,
  });

  final String wire;
  final String collection;
  final Widget page;
  final String mineId;
  final String mineName;
  final String otherId;
  final String otherName;
  final String thirdId;
  final String thirdName;
  final String manageTooltip;
  final String eventTooltip;
  final String addLabel;
  final String emptyMessage;
  final String siblingTooltip;
  final String siblingLocation;
  final String calendarLocation;
  final String newLocation;
  final String newEventLocation;
  final String Function(String id) editMarker;
}

final List<_Kind> _kinds = [
  _Kind(
    wire: 'venue',
    collection: 'venues',
    page: const EntityBrowsePage(targetType: TargetType.venue),
    mineId: 'v1',
    mineName: 'My Hall',
    otherId: 'v2',
    otherName: 'Not Mine',
    thirdId: 'v3',
    thirdName: 'Third Hall',
    manageTooltip: strings.manageVenue,
    eventTooltip: strings.newEventForVenue,
    addLabel: strings.addVenue,
    emptyMessage: strings.noVenuesFound,
    siblingTooltip: strings.browsePerformers,
    siblingLocation: '/performers',
    calendarLocation: '/calendar/venue/v2',
    newLocation: '/venues/new',
    // Locked to the venue it was booked from, and named so the form can show it
    // without a second read.
    newEventLocation: '/events/new?venueId=v1&venueName=My+Hall&lockVenue=1',
    editMarker: venueEditMarker,
  ),
  _Kind(
    wire: 'performer',
    collection: 'performers',
    page: const EntityBrowsePage(targetType: TargetType.performer),
    mineId: 'p1',
    mineName: 'My Band',
    otherId: 'p2',
    otherName: 'Someone Else',
    thirdId: 'p3',
    thirdName: 'Third Act',
    manageTooltip: strings.managePerformer,
    eventTooltip: strings.newEventForPerformer,
    addLabel: strings.addPerformer,
    emptyMessage: strings.noPerformersFound,
    siblingTooltip: strings.browseVenues,
    siblingLocation: '/venues',
    calendarLocation: '/calendar/performer/p2',
    newLocation: '/performers/new',
    // Not locked to a venue: an act plays wherever it is booked.
    newEventLocation: '/events/new?performerId=p1',
    editMarker: performerEditMarker,
  ),
];
