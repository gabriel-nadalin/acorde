import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../router_paths.dart';
import '../theme/colors.dart';
import 'events_list.dart';

class UserCalendarTabs extends StatefulWidget {
  final int? initialIndex;
  const UserCalendarTabs({super.key, this.initialIndex});

  @override
  State<UserCalendarTabs> createState() => _UserCalendarTabsState();
}

class _UserCalendarTabsState extends State<UserCalendarTabs> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int _version = 0; // bump to force child rebuilds after creates

  List<Map<String, dynamic>> get _performers => context.read<AuthController>().myPerformers;
  List<Map<String, dynamic>> get _venues => context.read<AuthController>().myVenues;

  int get _tabsCount => 1 + _performers.length + _venues.length;

  @override
  void initState() {
    super.initState();
    final init = (widget.initialIndex != null && widget.initialIndex! >= 0 && widget.initialIndex! < _tabsCount) ? widget.initialIndex! : 0;
    _tabController = TabController(length: _tabsCount, vsync: this, initialIndex: init);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Widget> _buildTabs() {
    final tabs = <Widget>[];
    tabs.add(const Tab(text: 'Combined'));
    for (final p in _performers) {
      final name = (p['name'] ?? p['id'] ?? 'Performer').toString();
      tabs.add(Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.performer, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
      ])));
    }
    for (final v in _venues) {
      final name = (v['name'] ?? v['id'] ?? 'Venue').toString();
      tabs.add(Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.venue, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
      ])));
    }
    return tabs;
  }

  List<Widget> _buildViews() {
    final views = <Widget>[];
    final perfIds = _performers.map((p) => p['id']?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    final venIds = _venues.map((v) => v['id']?.toString() ?? '').where((s) => s.isNotEmpty).toList();

    // combined view
    views.add(EventsListPage(key: ValueKey('events-$_version-0'), myPerformerIds: perfIds.isNotEmpty ? perfIds : null, myVenueIds: venIds.isNotEmpty ? venIds : null, performerName: null));

    var idx = 1;
    for (final p in _performers) {
      final id = p['id']?.toString() ?? '';
      final name = p['name']?.toString();
      views.add(EventsListPage(key: ValueKey('events-$_version-$idx'), myPerformerIds: id.isNotEmpty ? [id] : null, performerName: name));
      idx++;
    }

    for (final v in _venues) {
      final id = v['id']?.toString() ?? '';
      final name = v['name']?.toString();
      views.add(EventsListPage(key: ValueKey('events-$_version-$idx'), venueMode: true, venueId: id.isNotEmpty ? id : null, venueName: name));
      idx++;
    }

    return views;
  }

  Future<void> _chooseAccountAndCreate() async {
    final choice = await showModalBottomSheet<Map<String, String>>(context: context, builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_performers.isNotEmpty) ...[
              const ListTile(title: Text('Create for performer')),
              ..._performers.map((p) {
                final id = p['id']?.toString() ?? '';
                final name = (p['name'] ?? id).toString();
                return ListTile(
                  title: Text(name),
                  leading: const Icon(Icons.person),
                  onTap: () => Navigator.of(ctx).pop({'type': 'performer', 'id': id}),
                );
              }),
            ],
            if (_venues.isNotEmpty) ...[
              const ListTile(title: Text('Create for venue')),
              ..._venues.map((v) {
                final id = v['id']?.toString() ?? '';
                final name = (v['name'] ?? id).toString();
                return ListTile(
                  title: Text(name),
                  leading: const Icon(Icons.location_on),
                  onTap: () => Navigator.of(ctx).pop({'type': 'venue', 'id': id, 'name': name}),
                );
              }),
            ],
          ],
        ),
      );
    });

    if (choice == null) return;
    if (choice['type'] == 'performer' && choice['id'] != null) {
      final res = await context.push<bool?>(eventsNewPath(performerId: choice['id']!));
      if (res == true) setState(() => _version++);
    } else if (choice['type'] == 'venue' && choice['id'] != null) {
      final res = await context.push<bool?>(
        eventsNewPath(venueId: choice['id']!, venueName: choice['name'], lockVenue: true),
      );
      if (res == true) setState(() => _version++);
    }
  }

  Widget? _buildFab() {
    final index = _tabController.index;
    if (index == 0) {
      return FloatingActionButton(
        heroTag: const ValueKey('user_calendar_fab_combined'),
        onPressed: _chooseAccountAndCreate,
        tooltip: 'New event',
        child: const Icon(Icons.add),
      );
    }

    if (index <= _performers.length) {
      final perfIdx = index - 1;
      final p = _performers[perfIdx];
      final id = p['id']?.toString() ?? '';
      return FloatingActionButton(
        heroTag: ValueKey('user_calendar_fab_perf_$id'),
        onPressed: () async {
          final res = await context.push<bool?>(eventsNewPath(performerId: id));
          if (res == true) setState(() => _version++);
        },
        tooltip: 'New event (performer)',
        child: const Icon(Icons.add),
      );
    }

    final venueIdx = index - 1 - _performers.length;
    final v = _venues[venueIdx];
    final id = v['id']?.toString() ?? '';
    final name = v['name']?.toString();
    return FloatingActionButton(
      heroTag: ValueKey('user_calendar_fab_venue_$id'),
      onPressed: () async {
        final res = await context.push<bool?>(
          eventsNewPath(venueId: id, venueName: name, lockVenue: true),
        );
        if (res == true) setState(() => _version++);
      },
      tooltip: 'New event (venue)',
      child: const Icon(Icons.add),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: _buildTabs(),
        ),
      ),
      body: TabBarView(controller: _tabController, children: _buildViews()),
      floatingActionButton: _buildFab(),
    );
  }
}