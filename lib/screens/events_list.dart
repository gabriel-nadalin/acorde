import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/event.dart';
import '../models/membership.dart';
import '../nav/destinations.dart';
import '../router_paths.dart';
import '../theme/colors.dart';
import '../utils/calendar_math.dart';
import '../utils/error_text.dart';
import '../utils/event_delete.dart';
import '../utils/event_labels.dart';
import '../widgets/async_view.dart';
import '../widgets/calendar_grid.dart';

/// Month calendar of events, optionally narrowed to one performer or venue.
///
/// The optional id lists are *scopes*, not filters applied after the fact: a
/// page given either of them must only ever mark events that fall inside them,
/// so a performer tab never picks up the user's unrelated venue bookings.
class EventsListPage extends StatefulWidget {
  final bool venueMode;

  /// True when this page covers several assignments at once (the combined
  /// calendar tab), so a new event has no single owner to be seeded with.
  ///
  /// Stated by the caller instead of inferred from the id lists: a combined page
  /// with one assignment carries exactly the same ids as a page dedicated to
  /// that one, and the two must not seed a new event the same way.
  final bool combinedMode;

  /// True when a host already draws the top bar — the tabbed calendar, whose bar
  /// carries the tabs themselves.
  ///
  /// Without this the calendar stacked two bars: the host's ("Calendário", with
  /// the destinations) and this page's beneath it ("Meu calendário", with the
  /// back arrow), which put the back button in the middle of the screen instead
  /// of where every other screen has it. One bar, owned by the outer screen.
  final bool embedded;

  final List<String>? myPerformerIds;
  final List<String>? myVenueIds;
  final String? venueId;
  final String? venueName;
  final String? performerName;

  /// Month to open on, or null for the current one.
  ///
  /// Only ever an *initial* value: it seeds [_focusedMonth] in `initState` and
  /// is not consulted again, so the user's own month navigation is not undone by
  /// a rebuild. The handoff it exists for is the upcoming list's day headers,
  /// which open the calendar on the month the user was looking at.
  final DateTime? initialMonth;

  const EventsListPage({
    super.key,
    this.venueMode = false,
    this.combinedMode = false,
    this.embedded = false,
    this.myPerformerIds,
    this.myVenueIds,
    this.venueId,
    this.venueName,
    this.performerName,
    this.initialMonth,
  });

  @override
  State<EventsListPage> createState() => _EventsListPageState();
}

class _EventsListPageState extends State<EventsListPage> {
  /// The month on screen, normalised to its first day.
  ///
  /// This is the page's *only* statement about which month it is showing: the
  /// events come from the repository keyed by it, so a background mutation or
  /// a realtime update cannot leave the grid describing a different month than
  /// the banner does.
  late DateTime _focusedMonth = _startOfMonth(
    widget.initialMonth ?? DateTime.now(),
  );

  /// Events belonging to [_dataMonth], as returned by the last load. Rendered
  /// only while [_dataMonth] is still the focused month — a list that belongs
  /// to another month must never be presented as this month's.
  List<Event>? _events;
  DateTime? _dataMonth;
  Object? _error;

  static DateTime _startOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

  EventRepository get _eventsRepo => context.read<EventRepository>();
  AssignmentsController get _assignments =>
      context.read<AssignmentsController>();
  VenueRepository get _venueRepo => context.read<VenueRepository>();
  PerformerRepository get _performerRepo => context.read<PerformerRepository>();

  /// Explicit venue focus of this page (`/calendar/venue/:id`), if any.
  String? get _venueFocusId =>
      (widget.venueId != null && widget.venueId!.isNotEmpty)
      ? widget.venueId
      : null;

  /// True when this page was given its own id scope (a tab or a route).
  bool get _hasScope =>
      (widget.myPerformerIds?.isNotEmpty ?? false) ||
      (widget.myVenueIds?.isNotEmpty ?? false);

  /// True when the page carries no id scope at all, so it follows the user's
  /// own assignments instead of a narrowed view.
  bool get _followsAssignments =>
      widget.myPerformerIds == null && widget.myVenueIds == null;

  /// Booking scopes for the current build, resolved by [build].
  ///
  /// [_eventCats] is consulted once per event *and* once per grid cell, so the
  /// id sets are built once per build instead of once per lookup. `null` means
  /// the page tracks nothing on that axis.
  Set<String>? _performerScope;
  Set<String>? _venueScope;

  /// Performer ids whose bookings this page marks as its own, or null when it
  /// tracks none.
  ///
  /// An explicit list wins outright. A page focused on a single venue tracks
  /// that venue and no performer scope — the user's own performer bookings are
  /// a different axis, and painting them onto a venue page would be exactly
  /// the unrelated-booking leak the scopes exist to prevent. Only a page with
  /// no scope at all falls back to the user's assignments.
  Set<String>? _resolvePerformerScope() {
    final explicit = widget.myPerformerIds;
    if (explicit != null) return explicit.toSet();
    if (_venueFocusId != null || !_followsAssignments) return null;
    return {
      for (final p in _assignments.myPerformers)
        if (p.id != null) p.id!,
    };
  }

  /// Venue ids whose bookings this page marks as its own; see
  /// [_resolvePerformerScope]. A venue-focused page tracks the venue it shows
  /// even when the user does not manage it, which is why its cells still carry
  /// the venue marker on a read-only visit.
  Set<String>? _resolveVenueScope() {
    final explicit = widget.myVenueIds;
    if (explicit != null) return explicit.toSet();
    final focus = _venueFocusId;
    if (focus != null) return {focus};
    if (!_followsAssignments) return null;
    return {
      for (final v in _assignments.myVenues)
        if (v.id != null) v.id!,
    };
  }

  /// The page's one decision about an event: is it booked by a performer this
  /// page tracks, at a venue it tracks, both, or neither?
  ///
  /// Day markers, event colour and the scoped filter all read this result, so
  /// a cell can never be tinted "both" while its marker says "performer".
  /// It reads the scopes [build] resolved, so the two axes stay in one place.
  Set<String> _eventCats(Event e) {
    final cats = <String>{};
    final performerScope = _performerScope;
    if (performerScope != null && e.performers.any(performerScope.contains)) {
      cats.add('performer');
    }
    final venueScope = _venueScope;
    final venueId = e.venueId;
    if (venueScope != null && venueId != null && venueScope.contains(venueId)) {
      cats.add('venue');
    }
    return cats;
  }

  Color _colorForEvent(BuildContext context, Event e) {
    final cats = _eventCats(e);
    if (cats.length == 2) return AppColors.both(context);
    if (cats.contains('performer')) return AppColors.performer(context);
    if (cats.contains('venue')) return AppColors.venue(context);
    return AppColors.other(context);
  }

  /// True when this page may create/edit events: a venue page for a venue the
  /// user manages. Browsing any other venue's calendar stays read-only, which
  /// is exactly what the server enforces (pb_hooks/events.guard.pb.js), so the
  /// UI never offers an action that would come back 403.
  bool get _canEditVenue {
    if (!widget.venueMode) return false;
    final id = widget.venueId;
    if (id == null || id.isEmpty) return false;
    return _assignments.isMyVenue(id);
  }

  /// The performer this page is dedicated to, or null when it covers more.
  ///
  /// A one-element [myPerformerIds] is a page about one act — a performer tab or
  /// `/calendar/performer/:id`.
  String? get _focusPerformerId {
    final ids = widget.myPerformerIds;
    if (ids == null || ids.length != 1) return null;
    final id = ids.first;
    return id.isEmpty ? null : id;
  }

  /// True when this page may write the events it shows — create one, or open one
  /// for editing.
  ///
  /// A write has to name something the server will authorize it against: a venue
  /// this account manages, or an act it belongs to (pb_hooks/events.guard.pb.js
  /// allows exactly those two). Everything else is a 403 dressed up as a button,
  /// which is why a venue calendar for a venue the user does not manage stays
  /// read-only. Creation and editing read the same flag, so no view offers one
  /// while withholding the other.
  bool get _canWrite {
    if (widget.venueMode) return _canEditVenue;
    if (widget.combinedMode) {
      // Nothing to write for until the account has an assignment to write with.
      return _assignments.myPerformers.isNotEmpty ||
          _assignments.myVenues.isNotEmpty;
    }
    final performerId = _focusPerformerId;
    return performerId != null && _assignments.isMyPerformer(performerId);
  }

  /// Tooltip for the create button, naming what the event will be for.
  String _newEventTooltip(AppLocalizations l10n) {
    if (widget.venueMode) return l10n.newEventForVenue;
    if (!widget.combinedMode && _focusPerformerId != null) {
      return l10n.newEventForPerformer;
    }
    return l10n.newEvent;
  }

  /// Starts a new event, seeded with [date] when the user picked a day.
  ///
  /// The single creation path. The FAB, a day cell and the day sheet's "Add
  /// event" all come through here, so they cannot disagree about what a new event
  /// is seeded with — they used to be gated separately, which is exactly how
  /// tapping a day came to work on a venue calendar and do nothing at all on a
  /// performer or combined one.
  Future<void> _createEvent({DateTime? date}) async {
    final location = await _newEventLocation(date: date);
    if (location == null || !mounted) return;
    final created = await context.push<bool?>(location);
    if (created == true) _reloadAfterMutation();
  }

  /// Route location for a new event on this page, or null when the user backed
  /// out of choosing which assignment it is for.
  Future<String?> _newEventLocation({DateTime? date}) async {
    if (widget.venueMode) {
      return eventsNewPath(
        venueId: widget.venueId,
        venueName: _venueDisplayName,
        lockVenue: true,
        date: date,
      );
    }
    if (widget.combinedMode) return _chooseAssignmentFor(date: date);
    final performerId = _focusPerformerId;
    if (performerId == null) return null;
    // The act is seeded but the venue is left open: an act plays wherever it is
    // booked, so the venue is a choice, not a property of the page.
    return eventsNewPath(performerId: performerId, date: date);
  }

  /// Asks which assignment a new event belongs to.
  ///
  /// The combined calendar covers every assignment at once and so has none of
  /// its own to seed. Asking also keeps the venue locked to one this account
  /// manages, rather than leaving the form free to pick one the server would
  /// refuse.
  Future<String?> _chooseAssignmentFor({DateTime? date}) async {
    final l10n = AppLocalizations.of(context);
    final performers = _assignments.myPerformers;
    final venues = _assignments.myVenues;

    final choice = await showModalBottomSheet<Map<String, String>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (performers.isNotEmpty) ...[
                ListTile(title: Text(l10n.createForPerformer)),
                for (final p in performers)
                  ListTile(
                    title: Text(p.displayName),
                    leading: Icon(entityIcon(TargetType.performer)),
                    onTap: () => Navigator.of(
                      ctx,
                    ).pop({'type': 'performer', 'id': p.id ?? ''}),
                  ),
              ],
              if (venues.isNotEmpty) ...[
                ListTile(title: Text(l10n.createForVenue)),
                for (final v in venues)
                  ListTile(
                    title: Text(v.displayName),
                    leading: Icon(entityIcon(TargetType.venue)),
                    onTap: () => Navigator.of(ctx).pop({
                      'type': 'venue',
                      'id': v.id ?? '',
                      'name': v.displayName,
                    }),
                  ),
              ],
            ],
          ),
        ),
      ),
    );

    if (choice == null) return null;
    final id = choice['id'] ?? '';
    if (id.isEmpty) return null;
    return choice['type'] == 'performer'
        ? eventsNewPath(performerId: id, date: date)
        : eventsNewPath(
            venueId: id,
            venueName: choice['name'],
            lockVenue: true,
            date: date,
          );
  }

  /// Opens one booking for editing.
  ///
  /// Only reachable from a page that may write (see [_canWrite]), and the venue
  /// is locked only on a venue page: passing `lockVenue` anywhere else would
  /// *hide* the venue picker in the form, which is not what "not locked" means.
  Future<void> _editEvent(Event ev) async {
    final lockVenue = widget.venueMode && (widget.venueId?.isNotEmpty ?? false);
    final result = await context.push<bool?>(
      eventsEditPath(
        ev.id ?? '',
        venueId: lockVenue ? widget.venueId : null,
        venueName: lockVenue ? _venueDisplayName : null,
        lockVenue: lockVenue,
      ),
      extra: ev,
    );
    if (result == true) _reloadAfterMutation();
  }

  /// Display name of the venue this page focuses on.
  ///
  /// Callers may pass a name (calendar tab) or only an id (route), so resolve
  /// from the venue cache when needed — the router stays free of lookups.
  String? get _venueDisplayName {
    if (widget.venueName?.isNotEmpty ?? false) return widget.venueName;
    final id = widget.venueId;
    if (id == null || id.isEmpty) return null;
    return _venueRepo.byId(id)?.displayName;
  }

  /// Display name of the performer this page focuses on (single-id pages only).
  String? get _performerDisplayName {
    if (widget.performerName?.isNotEmpty ?? false) return widget.performerName;
    final ids = widget.myPerformerIds;
    if (ids == null || ids.length != 1) return null;
    return _performerRepo.byId(ids.first)?.displayName;
  }

  /// Names for this page's events, from the one implementation both screens use.
  ///
  /// Carries this page's venue override: the calendar is handed a venue's name by
  /// the route that opened it, and the booking should be labelled with the same
  /// name the page is titled with rather than a second lookup that could differ.
  EventLabels get _labels => EventLabels(
    l10n: AppLocalizations.of(context),
    venues: _venueRepo,
    performers: _performerRepo,
    venueOverrideId: widget.venueId,
    venueOverrideName: widget.venueName,
  );

  /// Subtitle lines for one event inside the day sheet.
  String _daySheetSubtitle(Event e) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final updated = e.updated;
    return [
      '${formatDateTime(locale, e.start.toLocal())} - ${formatDateTime(locale, e.end.toLocal())}',
      _labels.line(e),
      // Only rows the server has touched carry an `updated`; in the user's own
      // timezone, since the wire value is UTC.
      if (updated != null)
        AppLocalizations.of(
          context,
        ).lastUpdated(formatDate(locale, updated.toLocal())),
    ].join('\n');
  }

  @override
  void initState() {
    super.initState();
    _loadMonth();
  }

  /// Loads the displayed month, cache first.
  ///
  /// 1. [EventRepository.cachedMonth] — another calendar tab, a mutation or a
  ///    realtime update may already have this month, and refetching it would
  ///    only make the grid flicker.
  /// 2. [EventRepository.loadForMonth] — only when the cache has nothing for
  ///    the month; the repository shares one in-flight fetch per month, so the
  ///    calendar tabs do not each fire their own request.
  ///
  /// [force] is the refresh/retry path, where the user is explicitly asking
  /// for fresh data.
  Future<void> _loadMonth({bool force = false}) async {
    final repo = _eventsRepo;
    final month = _focusedMonth;

    if (!force) {
      final cached = repo.cachedMonth(month);
      if (cached != null) {
        if (!mounted) return;
        setState(() {
          _events = cached;
          _dataMonth = month;
          _error = null;
        });
        return;
      }
    }

    // Clearing the previous failure is what turns a retry back into the
    // loading view; the loading view itself is just "no data for this month
    // yet", so it needs no flag of its own.
    if (mounted) {
      setState(() => _error = null);
    }
    try {
      final items = await repo.loadForMonth(month, force: force);
      // The user may have moved to another month while this was in flight; its
      // answer belongs to the month that asked for it, never to the month now
      // on screen.
      if (!mounted || month != _focusedMonth) return;
      setState(() {
        _events = items;
        _dataMonth = month;
      });
    } catch (e) {
      if (!mounted || month != _focusedMonth) return;
      setState(() => _error = e);
    }
  }

  Future<void> _refresh() => _loadMonth(force: true);

  /// Month navigation. The old month's list is dropped rather than kept as a
  /// placeholder: it is a different month's data, and rendering it under the
  /// new month's header would mislabel every cell.
  void _onMonthChanged(DateTime month) {
    final next = _startOfMonth(month);
    if (next == _focusedMonth) return;
    setState(() {
      _focusedMonth = next;
      _events = null;
      _dataMonth = null;
      _error = null;
    });
    _loadMonth();
  }

  /// Re-reads the month after a create/edit.
  ///
  /// Cache first on purpose: the repository reloads every loaded month as part
  /// of the mutation, so this normally just picks the fresh list up instead of
  /// issuing a second request for data that is already there.
  void _reloadAfterMutation() {
    _loadMonth();
  }

  /// Day-cell activation: start a new event on an empty day, or open the day's
  /// bookings.
  ///
  /// Offered on every calendar this account can write to, not just a venue one.
  Future<void> _onDayTap(
    BuildContext context,
    DateTime dayDate,
    List<Event> dayEvents,
    bool hasEvent,
  ) async {
    if (!_canWrite && !hasEvent) return;
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();

    // An empty day goes straight to the form: a sheet listing nothing, with one
    // button on it, is a step that only exists to be dismissed.
    if (_canWrite && !hasEvent) {
      await _createEvent(date: dayDate);
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
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
                  // Flexible, because the date is the part that can be long:
                  // Portuguese spells the weekday out in full ("quinta-feira, 8
                  // de janeiro de 2026"), and a Material 3 bottom sheet is capped
                  // at 640 logical pixels, so an intrinsic-width date plus the
                  // button overflowed the sheet on every device — a phone worst of
                  // all. Letting the date wrap is the fix that does not depend on
                  // how long any particular translation happens to be.
                  Expanded(
                    child: Text(
                      formatFullDate(locale, dayDate),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_canWrite)
                    ElevatedButton.icon(
                      onPressed: () => Navigator.of(ctx).pop({'action': 'add'}),
                      icon: const Icon(Icons.add),
                      label: Text(l10n.addEvent),
                    ),
                ],
              ),
            ),
            Expanded(
              child: dayEvents.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noEvents,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    )
                  : ListView.separated(
                      itemCount: dayEvents.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final e = dayEvents[i];
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 8,
                            backgroundColor: _colorForEvent(context, e),
                          ),
                          title: Text(e.title),
                          subtitle: Text(_daySheetSubtitle(e)),
                          trailing: _canWrite
                              ? IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: l10n.deleteEvent,
                                  // Deletes without closing the sheet: a day with
                                  // several bookings usually means removing more
                                  // than one, and the sheet rebuilds itself from
                                  // the repository once the row is gone.
                                  onPressed: () => confirmDeleteEvent(ctx, e),
                                )
                              : null,
                          onTap: _canWrite
                              ? () => Navigator.of(
                                  ctx,
                                ).pop({'action': 'edit', 'event': e})
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || result == null) return;
    final action = result['action'] as String?;
    if (action == 'add') {
      await _createEvent(date: dayDate);
    } else if (action == 'edit' && result['event'] is Event) {
      await _editEvent(result['event'] as Event);
    }
  }

  /// This page's own top bar, for the routes where it is the whole screen.
  AppBar _buildAppBar(BuildContext context, AppLocalizations l10n) {
    return AppBar(
      // Two ways in: as a drill-down (a venue or act opened from a list), where
      // back means the list you came from, and as a standalone top-level page,
      // where back means home.
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: context.canPop() ? l10n.back : l10n.backToHome,
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            goHome(context);
          }
        },
      ),
      title: Builder(
        builder: (ctx) {
          final l10n = AppLocalizations.of(ctx);
          final String titleStr;
          if (widget.venueMode) {
            titleStr = _venueDisplayName ?? l10n.venueCalendar;
          } else if (_hasScope) {
            titleStr = _performerDisplayName ?? l10n.myCalendar;
          } else {
            titleStr = _performerDisplayName ?? l10n.performerCalendar;
          }
          return Text(titleStr);
        },
      ),
      actions: [
        IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The repository is the single source of truth for the displayed month.
    // Watching it — rather than holding a Future captured in `initState` — is
    // what makes a background mutation or a realtime update repaint the grid
    // and the offline banner from the same data.
    final repo = context.watch<EventRepository>();
    // Names resolve out of the performer/venue caches, which load asynchronously
    // (at login, and again after realtime updates): watch them so a late
    // arrival repaints the labels instead of leaving every reference looking
    // orphaned.
    context.watch<VenueRepository>();
    context.watch<PerformerRepository>();
    // An unscoped page derives its scopes from the user's assignments, and
    // `_canEditVenue` decides whether this page offers write actions at all —
    // both have to react when assignments finish loading.
    context.watch<AssignmentsController>();

    // Resolve the two booking axes once, here, before any event is classified:
    // `_eventCats` runs once per event and once per grid cell.
    _performerScope = _resolvePerformerScope();
    _venueScope = _resolveVenueScope();

    // Cache first, then the list the last load returned — and only for the
    // month on screen.
    final items =
        repo.cachedMonth(_focusedMonth) ??
        (_dataMonth == _focusedMonth ? _events : null);
    final stale = repo.isMonthStale(_focusedMonth);
    // AsyncView's contract is a snapshot, so the page's own (single) source of
    // truth is projected onto one: waiting while nothing is loaded, the error
    // it caught, otherwise the data.
    final snapshot = items != null
        ? AsyncSnapshot<List<Event>>.withData(ConnectionState.done, items)
        : _error != null
        ? AsyncSnapshot<List<Event>>.withError(ConnectionState.done, _error!)
        : const AsyncSnapshot<List<Event>>.waiting();

    return Scaffold(
      // No bar when a host owns it: the tabbed calendar's bar carries the tabs
      // and the destinations, and a second one here put the back button below
      // them instead of in the leading position every other screen uses.
      appBar: widget.embedded ? null : _buildAppBar(context, l10n),
      body: Column(
        children: [
          if (stale || repo.cacheCorrupt)
            MaterialBanner(
              leading: Icon(stale ? Icons.cloud_off : Icons.warning_amber),
              content: Text(
                stale ? l10n.offlineShowingCached : l10n.localCacheCorrupt,
              ),
              actions: [
                TextButton(onPressed: _refresh, child: Text(l10n.retry)),
              ],
            ),
          Expanded(
            child: AsyncView<List<Event>>(
              snapshot: snapshot,
              errorMessage: _error == null ? null : errorText(l10n, _error!),
              onRetry: _refresh,
              builder: (context, monthEvents) {
                // A page with any scope shows exactly the events it tracks,
                // through the same predicate that colours them. A page with no
                // scope at all is the plain "everything this month" browse.
                final scoped = _hasScope || _venueFocusId != null;
                final filtered = scoped
                    ? monthEvents
                          .where((e) => _eventCats(e).isNotEmpty)
                          .toList()
                    : monthEvents;

                final highlighted = highlightedDayKeys(filtered);

                return CalendarGrid(
                  focusedMonth: _focusedMonth,
                  onMonthChanged: _onMonthChanged,
                  events: filtered,
                  highlightedDays: highlighted,
                  eventCats: _eventCats,
                  onDayTap: _onDayTap,
                  // A cell acts when the page can start an event on an empty day,
                  // or when there is something on the day to open.
                  dayEnabled: (hasEvent) => _canWrite || hasEvent,
                  showLegend:
                      (widget.myPerformerIds != null &&
                          widget.myPerformerIds!.isNotEmpty) &&
                      (widget.myVenueIds != null &&
                          widget.myVenueIds!.isNotEmpty),
                );
              },
            ),
          ),
        ],
      ),
      // The page owns the button, including on the calendar tabs, which used to
      // add one of their own on top of this one's — two buttons, one position.
      floatingActionButton: _canWrite
          ? FloatingActionButton(
              onPressed: () => _createEvent(),
              // Page-unique: the calendar tabs hold several of these pages at
              // once, and duplicate Hero tags throw during a transition.
              heroTag: widget.key ?? const ValueKey('events_list_fab'),
              tooltip: _newEventTooltip(l10n),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
