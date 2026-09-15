import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'data/repositories.dart';
import 'models/event.dart';
import 'screens/create_event.dart';
import 'screens/events_list.dart';
import 'screens/user_calendar_tabs.dart';
import 'screens/user_dashboard.dart';
import 'screens/user_select.dart';

/// App route table.
///
/// Routes:
///   /                     user selection (login)
///   /dashboard            current user's entity list
///   /calendar             current user's tabbed calendar
///   /calendar/:type/:id   single-entity calendar browse (type = venue|performer)
///   /events/new           create event (?venueId=&venueName=&performerId=&date=&lockVenue=1)
///   /events/:id/edit      edit event (pass the Event via `extra`)
final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const UserSelectPage(),
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
        final type = state.pathParameters['type'];
        final id = state.pathParameters['id'] ?? '';
        final venueMode = type == 'venue';
        final auth = context.read<AuthController>();
        final venueRec = auth.venues.byId(id);
        final performerRec = auth.performers.byId(id);
        final String? venueName = venueRec?['name']?.toString();
        final String? performerName = performerRec?['name']?.toString();
        return EventsListPage(
          venueMode: venueMode,
          venueId: venueMode ? id : null,
          venueName: venueMode ? venueName : null,
          myPerformerIds: venueMode ? null : [id],
          performerName: venueMode ? performerName : null,
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
        return CreateEventPage(
          event: state.extra as Event?,
          prefillVenueId: query['venueId'],
          prefillVenueName: query['venueName'],
          lockVenue: query['lockVenue'] == '1',
        );
      },
    ),
  ],
);