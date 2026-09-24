import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/event.dart';
import '../nav/destinations.dart';
import '../theme/colors.dart';
import '../router_paths.dart';
import '../utils/calendar_math.dart';
import '../utils/event_delete.dart';
import '../utils/event_labels.dart';
import '../widgets/async_view.dart';

/// Everything still to come, across every assignment, in date order.
///
/// The calendar answers "what is on this day"; this answers "what is next",
/// which is the question somebody actually opens the app with. It is one query
/// (`end > now`, sorted by `start`) rather than a scan of months, so a booking
/// five months out appears without the user paging that far.
///
/// Rows are grouped under the day they fall on, because a schedule read at a
/// glance is read by day: "Thursday, two things" is the shape of the answer.
class UpcomingPage extends StatefulWidget {
  const UpcomingPage({super.key});

  @override
  State<UpcomingPage> createState() => _UpcomingPageState();
}

class _UpcomingPageState extends State<UpcomingPage> {
  @override
  void initState() {
    super.initState();
    // Not awaited and not guarded beyond this: the page watches the repository,
    // so the result (or the failure) arrives as a rebuild.
    context.read<EventRepository>().upcoming().catchError(
      (Object _) => <Event>[],
    );
  }

  Future<void> _refresh() async {
    try {
      await context.read<EventRepository>().upcoming(force: true);
    } catch (_) {
      // Reported by the error view the rebuild lands on.
    }
  }

  /// Whether this account may change [e], mirroring the server's rule
  /// (pb_hooks/events.guard.pb.js): a venue it manages, an act it belongs to, or
  /// an event it created. Anything else is a 403, so no delete is offered.
  bool _canWrite(Event e) {
    final assignments = context.read<AssignmentsController>();
    final userId = context.read<SessionController>().userId;
    final venueId = e.venueId;
    if (venueId != null &&
        venueId.isNotEmpty &&
        assignments.isMyVenue(venueId)) {
      return true;
    }
    if (e.performers.any(assignments.isMyPerformer)) return true;
    return userId != null && userId.isNotEmpty && e.createdBy == userId;
  }

  Future<void> _delete(Event e) async {
    final deleted = await confirmDeleteEvent(context, e);
    if (!deleted || !mounted) return;
    // No manual reload: the repository refreshes its own lists as part of the
    // delete and notifies, and this page is a watcher.
  }

  /// Opens one booking for editing. The caller owns the reload, since the
  /// repository refreshes on the write.
  Future<void> _edit(Event e) async {
    if (!_canWrite(e)) return;
    await context.push<bool?>('/events/${e.id}/edit', extra: e);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final repo = context.watch<EventRepository>();
    // Names resolve from these caches, which load asynchronously, so watching
    // them repaints a row when a late arrival turns an id into a name.
    context.watch<VenueRepository>();
    context.watch<PerformerRepository>();
    context.watch<AssignmentsController>();

    final events = repo.upcomingEvents;
    final snapshot = events != null
        ? AsyncSnapshot<List<Event>>.withData(ConnectionState.done, events)
        : const AsyncSnapshot<List<Event>>.waiting();

    return Scaffold(
      appBar: AppBar(
        leading: backToHomeButton(context),
        title: Text(l10n.upcomingTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n.retry,
            onPressed: _refresh,
          ),
          ...navActions(
            context,
            current: Destinations.upcoming,
            accountAction: true,
          ),
        ],
      ),
      body: Column(
        children: [
          if (repo.upcomingStale)
            MaterialBanner(
              leading: const Icon(Icons.cloud_off),
              content: Text(l10n.offlineShowingCached),
              actions: [
                TextButton(onPressed: _refresh, child: Text(l10n.retry)),
              ],
            ),
          Expanded(
            child: AsyncView<List<Event>>(
              snapshot: snapshot,
              errorMessage: l10n.couldNotLoadEvents,
              onRetry: _refresh,
              builder: (context, items) {
                if (items.isEmpty) {
                  return Center(child: Text(l10n.noUpcoming));
                }
                final labels = EventLabels.of(context);
                // One flat list of headers and rows: a month heading, a day
                // header per day, then that day's bookings, so the whole thing
                // stays a single scrollable rather than a nested-scroll per day.
                final children = <Widget>[];
                DateTime? lastDay;
                DateTime? lastMonth;
                for (final e in items) {
                  final local = e.start.toLocal();
                  final day = DateTime(local.year, local.month, local.day);
                  // Month heading before the first day of each month. The day
                  // headers alone were ambiguous in a long list — "sexta-feira,
                  // 25 de setembro" and "sábado, 7 de novembro" ran together with
                  // nothing saying the month had turned, which is exactly the
                  // information somebody scanning for "how far out does this go"
                  // is after.
                  if (lastMonth == null ||
                      day.month != lastMonth.month ||
                      day.year != lastMonth.year) {
                    children.add(_MonthHeader(label: monthLabel(locale, day)));
                    lastMonth = day;
                  }
                  if (lastDay == null || day != lastDay) {
                    children.add(
                      _DayHeader(
                        label: formatFullDate(locale, day),
                        // Opens the calendar on this day's month. The header is
                        // the natural affordance for "show me this in context",
                        // and the calendar is the screen that answers it — the
                        // day sheet it would otherwise open is already what this
                        // row list shows.
                        onTap: () => context.go(calendarMonthPath(day)),
                      ),
                    );
                    lastDay = day;
                  }
                  children.add(
                    _EventRow(
                      event: e,
                      locale: locale,
                      labels: labels,
                      color: _colorFor(context, e),
                      canWrite: _canWrite(e),
                      onOpen: () => _edit(e),
                      onDelete: () => _delete(e),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: children,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The same category colours the calendar uses, so a booking is the same
  /// colour in both places. An upcoming list mixes kinds, so most rows land on
  /// "other" — which is the honest answer for "neither one of mine".
  Color _colorFor(BuildContext context, Event e) {
    final assignments = context.read<AssignmentsController>();
    final mine = <String>{};
    if (e.performers.any(assignments.isMyPerformer)) mine.add('performer');
    final venueId = e.venueId;
    if (venueId != null && assignments.isMyVenue(venueId)) mine.add('venue');
    if (mine.length == 2) return AppColors.both(context);
    if (mine.contains('performer')) return AppColors.performer(context);
    if (mine.contains('venue')) return AppColors.venue(context);
    return AppColors.other(context);
  }
}

/// A day separator: the heading a run of bookings falls under.
///
/// Tapping it opens the calendar on that day's month, which is the one thing a
/// reader of this list may want that the list cannot give them: the shape of the
/// month around a date. It is the reason this is a button rather than a label.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      // Named for the screen reader and for `find.byTooltip`: the visible text is
      // the date, which says nothing about what tapping it does.
      child: Tooltip(
        message: AppLocalizations.of(context).openInCalendar,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // The affordance that says "this goes somewhere". An icon-only
              // hint rather than a button: the whole row is the target, and a
              // second tappable inside it would be a smaller one for the same
              // action.
              Icon(
                Icons.calendar_month,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A month separator, above the first day header of each month.
///
/// Deliberately heavier than [_DayHeader] and not tappable: it is a range
/// marker, not a destination, and giving it the same weight and the same action
/// as the day header would make the list read as two levels of the same thing.
class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
      child: Text(
        label,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// One booking: time, title, who is where, and the actions this account may take.
class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.locale,
    required this.labels,
    required this.color,
    required this.canWrite,
    required this.onOpen,
    required this.onDelete,
  });

  final Event event;
  final String locale;
  final EventLabels labels;
  final Color color;
  final bool canWrite;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The time is the point of the row, so it leads. Same day or not, the start
    // and end carry the dates when they differ.
    final sameDay =
        event.start.toLocal().year == event.end.toLocal().year &&
        event.start.toLocal().month == event.end.toLocal().month &&
        event.start.toLocal().day == event.end.toLocal().day;
    final when = sameDay
        ? '${formatTime(locale, event.start.toLocal())} – ${formatTime(locale, event.end.toLocal())}'
        : '${formatDateTime(locale, event.start.toLocal())} – ${formatDateTime(locale, event.end.toLocal())}';
    final where = labels.line(event);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: ListTile(
        leading: Container(
          width: 6,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        title: Text(event.title.isEmpty ? l10n.untitled : event.title),
        subtitle: Text(
          [
            when,
            if (where.isNotEmpty) where,
            // A repeating instance says so: without it, a weekly booking looks
            // like one booking that has mysteriously appeared five times.
            if (event.isSeriesInstance) l10n.repeatLabel,
          ].join('\n'),
        ),
        isThreeLine: true,
        trailing: canWrite
            ? IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: l10n.deleteEvent,
                onPressed: onDelete,
              )
            : null,
        onTap: canWrite ? onOpen : null,
      ),
    );
  }
}
