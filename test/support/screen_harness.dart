import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:event_calendar/data/repositories.dart';
import 'package:event_calendar/data/session_store.dart';
import 'package:event_calendar/l10n/app_localizations.dart';
import 'package:event_calendar/services/pocketbase_service.dart';

import 'fake_pocketbase.dart';

/// Text of the harness's root route.
///
/// The screens under test are reached by pushing them on top of it, so a
/// screen that reports success and pops leaves this marker visible — which is
/// how these tests tell "navigated away" from "still stuck on the form"
/// without inspecting the router's state.
const String kHomeMarker = 'HARNESS HOME';

/// Text the harness's venue/performer edit routes render.
///
/// The "already mine → open it" path navigates to another record's edit route,
/// which the router under test has to be able to resolve or `pushReplacement`
/// lands on go_router's error page. These are stand-ins for the destination
/// screen — the id in the text is what tells one record's route from another's.
String venueEditMarker(String id) => 'HARNESS EDIT VENUE $id';
String performerEditMarker(String id) => 'HARNESS EDIT PERFORMER $id';

/// The client behind `PocketBaseService.shared` for the life of this test file.
///
/// The entity editor builds its spec with `PocketBaseService.shared` rather than
/// with an injected service (see `_EntitySpec` in `lib/screens/entity_edit.dart`),
/// so its venue/performer writes do not travel through any repository the test
/// can construct — and a fake that only served the repositories would leave
/// those writes going to a real socket. `PocketBaseService.shared` is a lazily
/// created `static final` that takes its client from `http.Client()`, and
/// `http.Client()` answers with the client of the enclosing `runWithClient`
/// zone, which is the one hook a test has. Binding it once to this delegator
/// and re-pointing [target] per test gives every test file's fake the app-wide
/// service's traffic.
class _SharedServiceClient extends http.BaseClient {
  _SharedServiceClient._();

  static final _SharedServiceClient instance = _SharedServiceClient._();

  /// The fake server the running test installed.
  http.Client? target;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final target = this.target;
    if (target == null) {
      throw StateError(
        'No fake server is installed for PocketBaseService.shared',
      );
    }
    return target.send(request);
  }
}

/// A signed-in app shell around one screen, backed by [FakePb].
///
/// Mirrors the real provider wiring (see `lib/main.dart`): the same controllers
/// and repositories, the same localization delegates, and a router so that a
/// screen's `context.pop(true)` after a successful write behaves as it does in
/// the app — but with no [RealtimeSync], because a widget test must not open a
/// socket.
class ScreenHarness {
  ScreenHarness();

  late FakePb pb;
  late PocketBaseService service;
  late SessionController session;
  late PerformerRepository performers;
  late VenueRepository venues;
  late MembershipRepository memberships;
  late AssignmentsController assignments;
  late EventRepository events;

  /// The signed-in account, as the server's `users` record describes it.
  static const String userId = 'u1';
  static const String userEmail = 'me@example.com';
  static const String userName = 'Me';

  /// Whether `PocketBaseService.shared` has been pointed at a fake yet; it is
  /// built once per test file (see [_SharedServiceClient]).
  static bool _sharedBound = false;

  /// Builds the fake, the session and every controller, and signs the user in.
  Future<void> boot() async {
    SharedPreferences.setMockInitialValues({});
    pb = FakePb();
    service = PocketBaseService(baseUrl: 'http://pb.test', client: pb.client());
    pb.authRecord = {'id': userId, 'email': userEmail, 'name': userName};

    session = SessionController(
      service: service,
      prefs: SharedPreferences.getInstance(),
      // The device keystore is a platform channel, and under `flutter test` a
      // call to it never completes — a Future that neither resolves nor throws,
      // which would hang the sign-in this harness performs on every boot. The
      // in-memory store is what the abstraction exists for.
      store: MemorySessionStore(),
    );
    performers = PerformerRepository(service: service);
    venues = VenueRepository(service: service);
    memberships = MembershipRepository(service: service);
    assignments = AssignmentsController(
      session: session,
      performers: performers,
      venues: venues,
      memberships: memberships,
    );
    events = EventRepository(
      service: service,
      prefs: SharedPreferences.getInstance(),
    );

    await _bindSharedService();
    await session.login(userEmail, 'pw');
  }

  /// Points the app-wide service at this test's fake (see [_SharedServiceClient]).
  Future<void> _bindSharedService() async {
    _SharedServiceClient.instance.target = pb.client();
    if (_sharedBound) return;
    // Must be the first read of `PocketBaseService.shared` in this file: the
    // static initialiser runs inside the zone and keeps the client it finds
    // there for good.
    http.runWithClient(
      () => PocketBaseService.shared,
      () => _SharedServiceClient.instance,
    );
    _sharedBound = true;

    // Proof that the binding took, rather than a silent 400 later: if the
    // app-wide service had already been built with a real client, the fake would
    // never see a write. The probe's own round-trip is dropped from the log so
    // it cannot be mistaken for a request the screen made.
    final observed = pb.log.length;
    try {
      await PocketBaseService.shared.getVenues();
    } catch (_) {
      // Reported by the assertion below.
    }
    if (pb.log.length == observed) {
      throw StateError(
        'PocketBaseService.shared is not serving this test\'s fake server',
      );
    }
    pb.log.removeRange(0, pb.log.length);
    pb.requests.clear();
  }

  /// Two venues and two performers, one of each this user manages.
  void seedEntities() {
    pb.records('venues')
      ..add({
        'id': 'v1',
        'name': 'My Hall',
        'address': '1 Main St',
        'capacity': 120,
      })
      ..add({'id': 'v2', 'name': 'Not Mine', 'address': '2 Other St'});
    pb.records('performers')
      ..add({'id': 'p1', 'name': 'My Band', 'type': 'band'})
      ..add({'id': 'p2', 'name': 'Someone Else', 'type': 'solo'});
    pb.records('memberships')
      ..add({
        'id': 'm1',
        'userId': userId,
        'targetId': 'v1',
        'targetType': 'venue',
        'role': 'manager',
        // Active and manager: the roster endpoint authorizes on exactly that
        // pair, so a seeded creator who was merely `member` (or pending) would
        // see no team section at all.
        'status': 'active',
        'targetOwnerId': userId,
      })
      ..add({
        'id': 'm2',
        'userId': userId,
        'targetId': 'p1',
        'targetType': 'performer',
        'role': 'manager',
        'status': 'active',
        'targetOwnerId': userId,
      });
  }

  /// Loads the collections the screens read (memberships, venues, performers).
  ///
  /// Worth doing before pumping: these loads notify their listeners
  /// synchronously when they start, and every screen here starts one from
  /// `initState`, which runs inside the mount build. Loading them from the test
  /// body — where the app's own dashboard would have loaded them — makes the
  /// screen's own call join a completed pass, so the mount only reads what is
  /// already there. [force] refetches, for a test that seeded more rows after
  /// the first load.
  Future<void> warm({bool force = false}) => assignments.refresh(force: force);

  /// Pumps [screen] on a route pushed above the marker route, so a test can
  /// assert navigation the same way a user sees it.
  ///
  /// [routes] are registered after the harness's own, for a screen whose
  /// destinations are neither of the two edit routes. A push to a location the
  /// router cannot match lands on go_router's error page, where "navigated"
  /// and "failed to navigate" look the same from the widget tree — so a test
  /// asserting *where* a tap went has to give that destination a route. It is
  /// the caller's marker, not the harness's, because only the caller knows
  /// which location it expects.
  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(1200, 2600),
    List<RouteBase> routes = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text(kHomeMarker))),
        ),
        GoRoute(path: '/screen', builder: (context, state) => screen),
        // Destinations of the duplicate dialog's "open it" action. Without them
        // go_router has no match and the push lands on an error page, which
        // would make "navigated to that record" indistinguishable from failure.
        GoRoute(
          path: '/venues/:id/edit',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text(venueEditMarker(state.pathParameters['id'] ?? '')),
            ),
          ),
        ),
        GoRoute(
          path: '/performers/:id/edit',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text(
                performerEditMarker(state.pathParameters['id'] ?? ''),
              ),
            ),
          ),
        ),
        ...routes,
      ],
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: assignments),
          ChangeNotifierProvider.value(value: performers),
          ChangeNotifierProvider.value(value: venues),
          ChangeNotifierProvider.value(value: memberships),
          ChangeNotifierProvider.value(value: events),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('pt'),
          localizationsDelegates: const [
            ...AppLocalizations.localizationsDelegates,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );

    router.push('/screen');
    await tester.pumpAndSettle();
  }

  /// Pumps [screen] with a forced memberships refresh already in flight.
  ///
  /// The team section starts a **forced** memberships load from its `initState`
  /// (see `_TeamSection`), and a forced pass notifies its listeners
  /// synchronously — so the notification lands inside the mount build and trips
  /// the framework's "markNeedsBuild during build" assertion. Starting that
  /// pass from the test body, where a notification is legal, makes the section's
  /// own call join the pass in flight instead of starting a second one: the
  /// mount is silent, the section still renders the rows already loaded, and the
  /// held round-trip is released as soon as the screen is up.
  Future<void> pumpEditing(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(1200, 2600),
  }) async {
    final hold = Completer<http.Response>();
    final previous = pb.intercept;
    pb.intercept = (request) {
      if (request.method == 'GET' &&
          request.url.path.contains('/memberships/')) {
        return hold.future;
      }
      return previous?.call(request) ?? Future<http.Response?>.value();
    };
    final inFlight = memberships.load(force: true);
    try {
      await pump(tester, screen, size: size);
    } finally {
      hold.complete(
        FakePb.json(200, {
          'page': 1,
          'perPage': 200,
          'totalItems': memberships.items.length,
          'totalPages': 1,
          'items': [
            for (final membership in memberships.items) membership.toJson(),
          ],
        }),
      );
      pb.intercept = previous;
    }
    await inFlight;
    await tester.pumpAndSettle();
  }
}

/// The production strings, for assertions about user-visible text.
///
/// Named for what it is rather than for a language: the app ships one locale, and
/// a getter called `en` would have to lie about it (it did, until Portuguese
/// became the only one). Tests comparing against this are comparing against what
/// a user sees.
AppLocalizations get strings => lookupAppLocalizations(const Locale('pt'));
