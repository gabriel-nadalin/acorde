import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/performer.dart';
import '../models/venue.dart';
import '../nav/destinations.dart';
import '../theme/colors.dart';
import 'events_list.dart';

/// Tabbed calendar: one combined tab plus one tab per assigned performer and
/// venue.
///
/// The tab list is derived from [AssignmentsController], which is a
/// [ChangeNotifier] — creating a venue changes the tabs, so this listens rather
/// than reading once. `TabController.length` is fixed at construction, so a
/// changed assignment list rebuilds the controller instead of mismatching it.
class UserCalendarTabs extends StatefulWidget {
  const UserCalendarTabs({super.key, this.initialIndex, this.initialMonth});

  final int? initialIndex;

  /// Month to open every tab on (`?month=YYYY-MM`), or null for the current one.
  ///
  /// Applies to the whole tab set rather than to one tab: the tabs are views of
  /// the same schedule, so opening them on different months would make switching
  /// tabs silently change the date, which is the kind of surprise the tab strip
  /// exists to avoid.
  final DateTime? initialMonth;

  @override
  State<UserCalendarTabs> createState() => _UserCalendarTabsState();
}

class _UserCalendarTabsState extends State<UserCalendarTabs>
    with TickerProviderStateMixin {
  late final AssignmentsController _assignments = context
      .read<AssignmentsController>();
  TabController? _tabController;
  int _tabCount = 0;

  List<Performer> get _performers => _assignments.myPerformers;
  List<Venue> get _venues => _assignments.myVenues;

  @override
  void initState() {
    super.initState();
    _assignments.addListener(_syncTabs);
    _syncTabs();
  }

  @override
  void dispose() {
    _assignments.removeListener(_syncTabs);
    _tabController?.dispose();
    super.dispose();
  }

  int get _tabsCount => 1 + _performers.length + _venues.length;

  /// Rebuilds the [TabController] when the assignment list changes length.
  ///
  /// Reusing a controller whose `length` no longer matches its `TabBar` throws
  /// during paint, so the controller is replaced rather than mutated.
  void _syncTabs() {
    final count = _tabsCount;
    if (_tabController == null) {
      final initial =
          (widget.initialIndex != null &&
              widget.initialIndex! >= 0 &&
              widget.initialIndex! < count)
          ? widget.initialIndex!
          : 0;
      _tabController = TabController(
        length: count,
        vsync: this,
        initialIndex: initial,
      );
      _tabCount = count;
      return;
    }
    if (count != _tabCount) {
      final previousIndex = _tabController!.index;
      _tabController!.dispose();
      final next = previousIndex < count ? previousIndex : 0;
      _tabController = TabController(
        length: count,
        vsync: this,
        initialIndex: next,
      );
      _tabCount = count;
    }
    if (mounted) setState(() {});
  }

  Widget _tabLabel(String name, Color dotColor) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  List<Widget> _buildTabs(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      Tab(text: l10n.combined),
      for (final p in _performers)
        _tabLabel(p.displayName, AppColors.performer(context)),
      for (final v in _venues)
        _tabLabel(v.displayName, AppColors.venue(context)),
    ];
  }

  /// Refetches every month the calendar has loaded, for the bar's refresh button.
  ///
  /// Failures are left to the pages: each reports its own (a stale banner, an
  /// error view), and a snackbar here would say the same thing a second time.
  Future<void> _refresh() async {
    try {
      await context.read<EventRepository>().refreshLoaded(force: true);
    } catch (_) {
      // See above.
    }
  }

  List<Widget> _buildViews() {
    final performerIds = [
      for (final p in _performers) p.id,
    ].whereType<String>().toList();
    final venueIds = [
      for (final v in _venues) v.id,
    ].whereType<String>().toList();

    return [
      // Combined view: an explicit id scope, so it tracks exactly the user's
      // assignments and never widens to unrelated bookings.
      EventsListPage(
        key: const ValueKey('events-combined'),
        embedded: true,
        initialMonth: widget.initialMonth,
        // Covers every assignment at once, so a new event here has no single
        // owner to seed and the page asks which one it is for.
        combinedMode: true,
        myPerformerIds: performerIds.isNotEmpty ? performerIds : null,
        myVenueIds: venueIds.isNotEmpty ? venueIds : null,
      ),
      for (final p in _performers)
        EventsListPage(
          key: ValueKey('events-performer-${p.id}'),
          embedded: true,
          initialMonth: widget.initialMonth,
          myPerformerIds: p.id != null ? [p.id!] : null,
          performerName: p.displayName,
        ),
      for (final v in _venues)
        EventsListPage(
          key: ValueKey('events-venue-${v.id}'),
          embedded: true,
          initialMonth: widget.initialMonth,
          venueMode: true,
          venueId: v.id,
          venueName: v.displayName,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = _tabController;
    if (controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      // The only bar on this screen. Every tab is an embedded EventsListPage, so
      // there is one back arrow and it sits where every other screen's does.
      appBar: AppBar(
        leading: backToHomeButton(context),
        title: Text(l10n.calendar),
        actions: [
          // One refresh for the calendar rather than one per tab: the pages are
          // embedded now, so their own refresh buttons went with their bars. This
          // refetches every month on screen, which is what "refresh the calendar"
          // means however many tabs are loaded.
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _refresh,
          ),
          ...navActions(
            context,
            current: Destinations.calendar,
            accountAction: true,
          ),
        ],
        bottom: TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: _buildTabs(context),
        ),
      ),
      body: TabBarView(controller: controller, children: _buildViews()),
      // No FAB here: every tab is an EventsListPage, and that page owns the
      // create button — including which assignment a new event is seeded with.
    );
  }
}
