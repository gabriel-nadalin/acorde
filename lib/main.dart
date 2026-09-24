import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'data/realtime_sync.dart';
import 'data/repositories.dart';
import 'l10n/app_localizations.dart';
import 'router.dart';
import 'services/pocketbase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // One service instance for the whole app so the auth token and cookie
  // survive navigation, and so the realtime subscription shares it.
  final service = PocketBaseService.shared;
  final session = SessionController(service: service);
  final performers = PerformerRepository(service: service);
  final venues = VenueRepository(service: service);
  final memberships = MembershipRepository(service: service);
  final assignments = AssignmentsController(
    session: session,
    performers: performers,
    venues: venues,
    memberships: memberships,
  );
  final events = EventRepository(service: service);

  // Restore a persisted session before the first frame so an offline relaunch
  // opens logged-in instead of forcing login.
  await session.restoreSession();
  try {
    await assignments.refresh();
  } catch (_) {
    // Offline relaunch: the session is valid but the caches are not reachable.
    // The dashboard surfaces the failure with a retry; booting must not fail.
  }

  final realtime = RealtimeSync(
    service: service,
    events: events,
    performers: performers,
    venues: venues,
    memberships: memberships,
  );
  realtime.start();

  runApp(
    MyApp(
      session: session,
      assignments: assignments,
      performers: performers,
      venues: venues,
      memberships: memberships,
      events: events,
      realtime: realtime,
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    required this.session,
    required this.assignments,
    required this.performers,
    required this.venues,
    required this.memberships,
    required this.events,
    this.realtime,
  });

  final SessionController session;
  final AssignmentsController assignments;
  final PerformerRepository performers;
  final VenueRepository venues;
  final MembershipRepository memberships;
  final EventRepository events;

  /// Optional so widget tests can build the app without a live socket.
  final RealtimeSync? realtime;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final router = createRouter(
    session: widget.session,
    assignments: widget.assignments,
  );

  @override
  void dispose() {
    widget.realtime?.dispose();
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: widget.session),
        ChangeNotifierProvider.value(value: widget.assignments),
        ChangeNotifierProvider.value(value: widget.performers),
        ChangeNotifierProvider.value(value: widget.venues),
        ChangeNotifierProvider.value(value: widget.memberships),
        ChangeNotifierProvider.value(value: widget.events),
      ],
      child: MaterialApp.router(
        onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
        localizationsDelegates: const [
          ...AppLocalizations.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
        ),
        // Follow the platform setting; the calendar palette adapts via
        // AppColors (see lib/theme/colors.dart).
        themeMode: ThemeMode.system,
        routerConfig: router,
      ),
    );
  }
}
