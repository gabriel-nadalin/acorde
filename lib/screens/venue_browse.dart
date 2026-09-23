import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../router_paths.dart';
import '../widgets/async_view.dart';

/// Browsable list of every venue, so an account with no assignments yet still
/// has something to open.
///
/// Reads the venue collection directly rather than [AuthController]'s
/// assignment lists: this is "all venues", not "my venues". The real app would
/// filter by proximity; the prototype lists them all.
class VenueBrowsePage extends StatefulWidget {
  const VenueBrowsePage({super.key});

  @override
  State<VenueBrowsePage> createState() => _VenueBrowsePageState();
}

class _VenueBrowsePageState extends State<VenueBrowsePage> {
  late Future<List<Map<String, dynamic>>> _future;

  VenueRepository get _venues => context.read<AuthController>().venues;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final repo = _venues;
    await repo.load(force: true);
    return repo.items;
  }

  Future<void> _reload() async {
    setState(() => _future = _load());
    await _future;
  }

  String _name(Map<String, dynamic> v) =>
      (v['name'] ?? v['title'] ?? v['id']).toString();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = context.watch<AuthController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.venuesTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.signOut,
            onPressed: () {
              context.read<AuthController>().logout();
              context.go('/');
            },
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) => AsyncView<List<Map<String, dynamic>>>(
          snapshot: snap,
          errorMessage: l10n.couldNotLoadVenues,
          onRetry: _reload,
          builder: (context, venues) {
            if (venues.isEmpty) {
              return Center(child: Text(l10n.noVenuesFound));
            }
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.builder(
                itemCount: venues.length,
                itemBuilder: (context, i) {
                  final v = venues[i];
                  final id = v['id']?.toString() ?? '';
                  final managed = auth.isMyVenue(id);
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.location_on),
                      title: Text(_name(v)),
                      subtitle: Text(v['address']?.toString() ?? ''),
                      trailing: managed
                          ? IconButton(
                              icon: const Icon(Icons.add),
                              tooltip: l10n.newEventForVenue,
                              onPressed: id.isEmpty
                                  ? null
                                  : () => context.push(
                                        eventsNewPath(
                                          venueId: id,
                                          venueName: _name(v),
                                          lockVenue: true,
                                        ),
                                      ),
                            )
                          : null,
                      onTap: id.isEmpty
                          ? null
                          : () => context.push('/calendar/venue/$id'),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
