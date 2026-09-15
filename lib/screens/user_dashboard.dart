import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../widgets/async_view.dart';

class UserDashboardPage extends StatefulWidget {
  const UserDashboardPage({super.key});

  @override
  State<UserDashboardPage> createState() => _UserDashboardPageState();
}

class _UserDashboardPageState extends State<UserDashboardPage> {
  late Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Reloads the user's entity caches and recomputes their assignments.
  Future<void> _load() => context.read<AuthController>().refresh(force: true);

  Future<void> _reload() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = context.read<AuthController>();
    final user = auth.user ?? const <String, dynamic>{};
    final name = user['name'] ?? user['email'] ?? l10n.userFallback;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle(name.toString())),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today),
            onPressed: () {
              context.push('/calendar');
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              context.read<AuthController>().logout();
              context.go('/');
            },
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _future,
        builder: (context, snap) => AsyncView<void>(
          snapshot: snap,
          onRetry: _reload,
          builder: (context, _) {
            final performers = auth.myPerformers;
            final venues = auth.myVenues;
            final sectionStyle = Theme.of(context).textTheme.titleLarge;
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(l10n.myPerformers, style: sectionStyle),
                  const SizedBox(height: 8),
                  if (performers.isEmpty) Text(l10n.noPerformerProfiles),
                  for (final p in performers)
                    Card(
                      child: ListTile(
                        title: Text(p['name']?.toString() ?? l10n.untitled),
                        subtitle: Text(p['contact']?.toString() ?? p['id']?.toString() ?? ''),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(l10n.myVenues, style: sectionStyle),
                  const SizedBox(height: 8),
                  if (venues.isEmpty) Text(l10n.noVenueProfiles),
                  for (final v in venues)
                    Card(
                      child: ListTile(
                        title: Text(v['name']?.toString() ?? l10n.untitled),
                        subtitle: Text(v['address']?.toString() ?? v['id']?.toString() ?? ''),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
