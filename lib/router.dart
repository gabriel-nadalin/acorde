import 'package:go_router/go_router.dart';

import 'models/event.dart';
import 'screens/create_event.dart';
import 'screens/events_list.dart';
import 'screens/sign_up.dart';
import 'screens/user_calendar_tabs.dart';
import 'screens/user_dashboard.dart';
import 'screens/user_select.dart';
import 'screens/venue_browse.dart';

/// App route table.
///
/// Routes:
///   /                     sign-in
///   /signup               create account
///   /venues               browse all venues
///   /dashboard            current user's entity list
///   /calendar             current user's tabbed calendar
///   /calendar/:type/:id   single-entity calendar browse (type = venue|performer)
///   /events/new           create event (?venueId=&venueName=&performerId=&date=&lockVenue=1)
///   /events/:id/edit      edit event (pass the Event via `extra`)
///
/// Route builders stay free of repository lookups: they forward ids and let
/// the page resolve display names from the providers it already reads.
final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const UserSelectPage(),
    ),
    GoRoute(
      path: '/signup',
      builder: (context, state) => const SignUpPage(),
    ),
    GoRoute(
      path: '/venues',
      builder: (context, state) => const VenueBrowsePage(),
    ),
    GoRoute(
      path: '/dashboard',
      builder: (context, state) => const UserDashboardPage(),
    ),
    GoRoute(
      path: '/calendar',
      builder: (context, state) => const UserCalendarTabs(),
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
          prefillPerformerIds: query['performerId'] != null ? [query['performerId']!] : null,
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
