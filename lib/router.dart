import 'package:go_router/go_router.dart';

import 'data/repositories.dart';
import 'models/event.dart';
import 'models/membership.dart';
import 'nav/destinations.dart';
import 'router_paths.dart';
import 'screens/create_event.dart';
import 'screens/entity_browse.dart';
import 'screens/entity_edit.dart';
import 'screens/events_list.dart';
import 'screens/password_reset.dart';
import 'screens/sign_up.dart';
import 'screens/upcoming.dart';
import 'screens/user_calendar_tabs.dart';
import 'screens/user_dashboard.dart';
import 'screens/user_select.dart';

/// App route table.
///
/// Routes:
///   /                     sign-in
///   /signup               create account
///   /venues               browse all venues
///   /performers           browse all performers
///   /venues/new           create a venue
///   /venues/:id/edit      edit a venue and manage its managers
///   /performers/new       create a performer
///   /performers/:id/edit  edit a performer and manage its members
///   /dashboard            current user's entity list (the app's home)
///   /upcoming             what is next, across every assignment
///   /calendar             current user's tabbed calendar
///   /calendar/:type/:id   single-entity calendar browse (type = venue|performer)
///   /events/new           create event (?venueId=&venueName=&performerId=&date=&lockVenue=1)
///   /events/:id/edit      edit event (pass the Event via `extra`)
///   /forgot-password      request a reset link (?email= to prefill)
///   /reset-password       set a new password (?token= from the reset email)
///
/// Route builders stay free of repository lookups: they forward ids and let
/// the page resolve display names from the providers it already reads.
///
/// Where a signed-in user lands: home, for every account.
///
/// Defined once and used by both the [redirect] and the sign-in page, because
/// they used to decide it separately and promptly disagreed — the redirect sent
/// a new user to the calendar while the sign-in form sent them to the venue
/// list, and which one won depended on which ran last.
///
/// The dashboard is the right home because it is meaningful before any
/// assignment exists: an empty one says "nothing yet, add something or ask to
/// join", whereas an empty calendar just looks broken.
const String kHomeLocation = '/dashboard';

/// Access control lives in [redirect] rather than in each page. Without it the
/// authenticated routes were reachable logged-out and rendered as empty shells
/// (a dashboard showing zero entities, a calendar with no data) instead of
/// asking the user to sign in.
GoRouter createRouter({
  required SessionController session,
  required AssignmentsController assignments,
}) {
  return GoRouter(
    initialLocation: '/',
    // Re-runs the redirect on login, logout and session expiry.
    refreshListenable: session,
    redirect: (context, state) {
      final location = state.uri.path;
      // Reachable with or without a session, and never redirected:
      //
      //   * the reset and forgot-password screens. The reset link arrives from a
      //     mail client rather than from inside the app, so the user may be
      //     signed out (the usual case) or already signed in on that device —
      //     and mid-reset is the wrong moment to be sent to the dashboard.
      //     Without this, a signed-out visitor following their own reset link
      //     was bounced to the sign-in screen they could not get past, which is
      //     the whole reason the link exists.
      //   * every destination that does not require a session, which is today
      //     the venue and performer lists. Taken from the registry rather than
      //     listed here: this was a hand-written pair of paths, so marking a
      //     list public in [Destinations] left it unreachable and the two
      //     silently disagreed. That is exactly the bug this replaces — the
      //     route comment below claimed the lists were public while this
      //     function sent visitors back to the sign-in screen.
      if (location == '/reset-password' ||
          location == '/forgot-password' ||
          Destinations.public.any((d) => d.location == location)) {
        return null;
      }
      final isAuthRoute = location == '/' || location == '/signup';
      if (!session.isLoggedIn) return isAuthRoute ? null : '/';
      if (!isAuthRoute) return null;
      // Signed in and sitting on an auth route: land on the dashboard. See
      // [kHomeLocation].
      return kHomeLocation;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const UserSelectPage()),
      // Public, and outside the signed-in redirect: the user who cannot sign in
      // is exactly who needs these, so they must not bounce to the dashboard.
      // The redirect above derives that from [Destinations.public], and
      // `pb_migrations/1790400000_public_entity_lists.js` opens the collections
      // to match — without it the page renders and the list request 401s.
      //
      // The address travels in the query rather than as a typed `extra`, because
      // the reset link arrives from outside the app — a mail client, a pasted
      // URL — where there is no `extra` and no navigation stack.
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          return ForgotPasswordPage(
            prefillEmail: (email != null && email.isNotEmpty) ? email : null,
          );
        },
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) =>
            ResetPasswordPage(token: state.uri.queryParameters['token']),
      ),
      GoRoute(path: '/signup', builder: (context, state) => const SignUpPage()),
      GoRoute(
        path: '/venues',
        builder: (context, state) =>
            const EntityBrowsePage(targetType: TargetType.venue),
      ),
      GoRoute(
        path: '/performers',
        builder: (context, state) =>
            const EntityBrowsePage(targetType: TargetType.performer),
      ),
      GoRoute(
        path: '/venues/new',
        builder: (context, state) => const VenueEditPage(),
      ),
      GoRoute(
        path: '/venues/:id/edit',
        builder: (context, state) =>
            VenueEditPage(venueId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/performers/new',
        builder: (context, state) => const PerformerEditPage(),
      ),
      GoRoute(
        path: '/performers/:id/edit',
        builder: (context, state) =>
            PerformerEditPage(performerId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const UserDashboardPage(),
      ),
      GoRoute(
        path: '/upcoming',
        builder: (context, state) => const UpcomingPage(),
      ),
      GoRoute(
        path: '/calendar',
        builder: (context, state) => UserCalendarTabs(
          // `?month=YYYY-MM`, so the upcoming list can hand off to the month it
          // was showing. Null for a missing or malformed value, which opens the
          // calendar on the current month rather than failing the route.
          initialMonth: parseCalendarMonth(state.uri.queryParameters['month']),
        ),
      ),
      GoRoute(
        path: '/calendar/:type/:id',
        builder: (context, state) {
          final venueMode = state.pathParameters['type'] == 'venue';
          final id = state.pathParameters['id'] ?? '';
          return EventsListPage(
            venueMode: venueMode,
            venueId: venueMode ? id : null,
            myPerformerIds: venueMode ? null : [id],
          );
        },
      ),
      GoRoute(
        path: '/events/new',
        builder: (context, state) {
          final query = state.uri.queryParameters;
          final date = query['date'];
          return CreateEventPage(
            initialDate: date != null ? DateTime.tryParse(date) : null,
            prefillVenueId: query['venueId'],
            prefillVenueName: query['venueName'],
            lockVenue: query['lockVenue'] == '1',
            prefillPerformerIds: query['performerId'] != null
                ? [query['performerId']!]
                : null,
          );
        },
      ),
      GoRoute(
        path: '/events/:id/edit',
        builder: (context, state) {
          final query = state.uri.queryParameters;
          final extra = state.extra;
          return CreateEventPage(
            // `extra` is untyped; a wrong runtime type must degrade to "no
            // prefilled event" instead of throwing during navigation.
            event: extra is Event ? extra : null,
            prefillVenueId: query['venueId'],
            prefillVenueName: query['venueName'],
            lockVenue: query['lockVenue'] == '1',
          );
        },
      ),
    ],
  );
}
