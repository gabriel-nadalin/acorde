import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../models/event.dart';
import '../data/repositories.dart';
import '../router_paths.dart';
import '../theme/colors.dart';
import '../widgets/async_view.dart';
import '../widgets/calendar_grid.dart';

class EventsListPage extends StatefulWidget {
  final bool venueMode;
  final List<String>? myPerformerIds;
  final List<String>? myVenueIds;
  final String? venueId;
  final String? venueName;
  final String? performerName;
  const EventsListPage({super.key, this.venueMode = false, this.myPerformerIds, this.myVenueIds, this.venueId, this.venueName, this.performerName});

  @override
  State<EventsListPage> createState() => _EventsListPageState();
}

class _EventsListPageState extends State<EventsListPage> {
  late Future<List<Event>> _future;
  DateTime _focusedMonth = DateTime.now();

  EventRepository get _eventsRepo => context.read<EventRepository>();
  AuthController get _auth => context.read<AuthController>();

  /// Explicit venue focus of this page (`/calendar/venue/:id`), if any.
  String? get _venueFocusId =>
      (widget.venueId != null && widget.venueId!.isNotEmpty) ? widget.venueId : null;

  /// True when this page was given its own id scope (a tab or a route).
  bool get _hasScope =>
      (widget.myPerformerIds?.isNotEmpty ?? false) || (widget.myVenueIds?.isNotEmpty ?? false);

  /// True when the page carries no id scope at all, so it follows the user's
  /// own assignments instead of a narrowed view.
  bool get _followsAssignments => widget.myPerformerIds == null && widget.myVenueIds == null;

  /// Whether [e] is booked by a performer this page tracks.
  ///
  /// An explicit tab/route id list narrows the page to those performers; a
  /// page with no scope at all follows the user's assignments, whose
  /// membership [AuthController] computes once in `refresh()`. A page scoped
  /// by the *other* id list tracks no performers, so a performer tab never
  /// picks up the user's unrelated bookings.
  bool _matchesPerformer(Event e) {
    final scope = widget.myPerformerIds;
    if (scope != null) return e.performers.any(scope.contains);
    return _followsAssignments && e.performers.any(_auth.isMyPerformer);
  }

  /// Whether [e] is booked at a venue this page tracks; see
  /// [_matchesPerformer].
  bool _matchesVenue(Event e) {
    final venueId = e.venueId;
    if (venueId == null) return false;
    final scope = widget.myVenueIds;
    if (scope != null) return scope.contains(venueId);
    return _followsAssignments && _auth.isMyVenue(venueId);
  }

  @override
  void initState() {
    super.initState();
    _future = _loadEvents();
  }

  String _venueNameFor(Event e) {
    if (widget.venueId != null && widget.venueId == e.venueId && (widget.venueName ?? '').isNotEmpty) {
      return widget.venueName!;
    }
    return e.venueName ?? e.venueId ?? '';
  }

  String _performerNamesFor(Event e) {
    if (e.performerNames.isNotEmpty) return e.performerNames.join(', ');
    return e.performers.join(', ');
  }

  Future<List<Event>> _loadEvents() async {
    final repo = _eventsRepo;
    try {
      return await repo.loadForMonth(_focusedMonth);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load events: $e')),
        );
      }
      return [];
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _loadEvents();
    });
    await _future;
  }

  Set<String> _highlightedDays(List<Event> items) {
    final s = <String>{};
    for (final e in items) {
      final start = e.start.toLocal();
      final end = e.end.toLocal();
      var current = DateTime(start.year, start.month, start.day);
      final last = DateTime(end.year, end.month, end.day);
      while (!current.isAfter(last)) {
        s.add(ymdKey(current));
        current = current.add(const Duration(days: 1));
      }
    }
    return s;
  }

  Set<String> _eventCats(Event e) {
    final cats = <String>{};
    final hasMyPerfs = widget.myPerformerIds?.isNotEmpty ?? false;
    final hasMyVens = widget.myVenueIds?.isNotEmpty ?? false;
    final isVenueView = widget.venueMode || (widget.venueId?.isNotEmpty ?? false);
    final isPerfOnlyView = hasMyPerfs && !hasMyVens && !isVenueView;
    final isVenOnlyView = hasMyVens && !hasMyPerfs && !isVenueView;

    // If this page is explicitly a venue view, treat all events as venue bookings
    if (isVenueView || isVenOnlyView) {
      if (e.venueId != null) cats.add('venue');
      return cats;
    }

    // If this is explicitly a performer-only view, treat events as performer bookings
    if (isPerfOnlyView) {
      if (e.performers.isNotEmpty && _matchesPerformer(e)) cats.add('performer');
      return cats;
    }

    // Combined or default behavior: honour the page scope, else the user's own
    // assignments.
    if (_matchesPerformer(e)) cats.add('performer');
    if (_matchesVenue(e)) cats.add('venue');
    return cats;
  }

  Color _colorForEvent(Event e) {
    final cats = _eventCats(e);
    if (cats.length == 2) return AppColors.both;
    if (cats.contains('performer')) return AppColors.performer;
    if (cats.contains('venue')) return AppColors.venue;
    return AppColors.other;
  }

  /// Day-cell tap: create (venue mode, empty day), or browse/edit via the
  /// day bottom sheet.
  Future<void> _onDayTap(BuildContext context, DateTime dayDate, List<Event> dayEvents, bool hasEvent) async {
    if (!widget.venueMode && !hasEvent) return;
    final list = dayEvents;

    if (widget.venueMode && !hasEvent) {
      final res = await context.push<bool?>(
        eventsNewPath(
          venueId: widget.venueMode ? widget.venueId : null,
          venueName: widget.venueMode ? widget.venueName : null,
          lockVenue: true,
          date: dayDate,
        ),
      );
      if (!mounted) return;
      if (res == true) await _refresh();
      return;
    }

    final result = await showModalBottomSheet(
      context: context,
      builder: (ctx) => SizedBox(
        height: 340,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${dayDate.year}-${dayDate.month.toString().padLeft(2, '0')}-${dayDate.day.toString().padLeft(2, '0')}', style: Theme.of(context).textTheme.titleLarge),
                  if (widget.venueMode)
                    ElevatedButton.icon(
                      onPressed: () => Navigator.of(ctx).pop({'action': 'add'}),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Event'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text('No events', style: Theme.of(context).textTheme.bodyLarge))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final e = list[i];
                        return ListTile(
                          leading: CircleAvatar(radius: 8, backgroundColor: _colorForEvent(e)),
                          title: Text(e.title),
                          subtitle: Text('${e.start.toLocal()} - ${e.end.toLocal()}\n${_venueNameFor(e)} • ${_performerNamesFor(e)}'),
                          onTap: widget.venueMode ? () => Navigator.of(ctx).pop({'action': 'edit', 'event': e}) : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );

    if (result is Map<String, dynamic>) {
      final action = result['action'] as String?;
      if (action == 'add') {
        if (!mounted) return;
        final res = await context.push<bool?>(
          eventsNewPath(
            venueId: widget.venueMode ? widget.venueId : null,
            venueName: widget.venueMode ? widget.venueName : null,
            lockVenue: true,
            date: dayDate,
          ),
        );
        if (res == true) await _refresh();
      } else if (action == 'edit' && result['event'] is Event) {
        final ev = result['event'] as Event;
        if (widget.venueMode) {
          if (!mounted) return;
          final res = await context.push<bool?>(
            eventsEditPath(
              ev.id ?? '',
              venueId: widget.venueMode ? widget.venueId : null,
              venueName: widget.venueMode ? widget.venueName : null,
              lockVenue: true,
            ),
            extra: ev,
          );
          if (res == true) await _refresh();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
        title: Builder(builder: (ctx) {
          String titleStr;
          if (widget.venueMode) {
            titleStr = widget.venueName?.isNotEmpty == true ? widget.venueName! : 'Venue Calendar';
          } else if ((widget.myPerformerIds != null && widget.myPerformerIds!.isNotEmpty) || (widget.myVenueIds != null && widget.myVenueIds!.isNotEmpty)) {
            titleStr = widget.performerName?.isNotEmpty == true ? widget.performerName! : 'My Calendar';
          } else {
            titleStr = widget.performerName?.isNotEmpty == true ? widget.performerName! : 'Performer Calendar';
          }
          return Text(titleStr);
        }),
        actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))],
      ),
      body: Column(
        children: [
          if (context.watch<EventRepository>().isMonthStale(_focusedMonth))
            MaterialBanner(
              leading: const Icon(Icons.cloud_off),
              content: const Text('Offline — showing cached events'),
              actions: [
                TextButton(onPressed: _refresh, child: const Text('Retry')),
              ],
            ),
          Expanded(
            child: FutureBuilder<List<Event>>(
              future: _future,
              builder: (context, snap) {
                return AsyncView(
                  snapshot: snap,
                  errorMessage: 'Could not load events',
                  onRetry: _refresh,
                  builder: (context, items) {
                    final filtered = _venueFocusId != null
                        ? items.where((e) => e.venueId == _venueFocusId).toList()
                        : _hasScope
                            ? items.where((e) => _matchesPerformer(e) || _matchesVenue(e)).toList()
                            : items;

                    final highlighted = _highlightedDays(filtered);

                    return CalendarGrid(
                      focusedMonth: _focusedMonth,
                      onMonthChanged: (m) {
                        setState(() => _focusedMonth = m);
                        _refresh();
                      },
                      events: filtered,
                      highlightedDays: highlighted,
                      eventCats: _eventCats,
                      onDayTap: _onDayTap,
                      showLegend: (widget.myPerformerIds != null && widget.myPerformerIds!.isNotEmpty) &&
                          (widget.myVenueIds != null && widget.myVenueIds!.isNotEmpty),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: widget.venueMode
          ? FloatingActionButton(
              onPressed: () async {
                final res = await context.push<bool?>(
                  eventsNewPath(venueId: widget.venueId, venueName: widget.venueName, lockVenue: true),
                );
                if (res == true) await _refresh();
              },
              // Use a page-unique heroTag to avoid duplicate Hero tags in nested scaffolds
              heroTag: widget.key ?? const ValueKey('events_list_fab'),
              tooltip: 'New event',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}