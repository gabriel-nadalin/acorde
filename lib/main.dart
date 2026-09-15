import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/repositories.dart';
import 'router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Restore a persisted session before the first frame so an offline relaunch
  // opens logged-in instead of forcing login.
  final auth = AuthController();
  await auth.restoreSession();
  runApp(MyApp(auth: auth));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => EventRepository()),
      ],
      child: MaterialApp.router(
        title: 'Event Calendar',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        ),
        routerConfig: router,
      ),
    );
  }
}