import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/membership.dart';
import '../nav/destinations.dart';
import '../router_paths.dart';
import '../utils/event_scope.dart';
import '../models/event.dart';
import '../utils/calendar_math.dart';
import '../utils/error_text.dart';
import '../utils/event_labels.dart';
import '../widgets/async_view.dart';

/// "My entities": the venues and performers this account manages or belongs to,
/// plus the invitations still waiting to be claimed.
///
/// Every list here is derived by [AssignmentsController] from the membership
/// rows the server owns, so its [refresh] is the whole source of truth — and so
/// are its failures. Swallowing them would render "no profiles assigned" for an
/// account that merely could not reach the backend: a lie that sends the user
/// hunting for entities instead of for their network.
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

  /// Loads everything the dashboard shows: the assignments behind its sections,
  /// and the upcoming list behind its preview card.
  ///
  /// The assignments error is deliberately not guarded: [AsyncView] turns it
  /// into the error state, which is the only place the real cause can be shown.
  ///
  /// The preview needs its own kick, and does guard. It renders nothing until
  /// the query has answered — a card claiming "nothing coming up" while the
  /// answer is still in flight would be a lie — so without asking here the card
  /// would never appear on a fresh session, which is the screen it is for. Not
  /// awaited either: the sections should not wait behind it.
  Future<void> _load() async {
    context.read<EventRepository>().upcoming().catchError(
      (Object _) => <Event>[],
    );
    await context.read<AssignmentsController>().refresh(force: true);
  }

  Future<void> _reload() async {
    setState(() {
      _future = _load();
    });
    await _future;
  }

  /// Refetch after a write made on a child route, without letting a refresh
  /// failure escape into the button that triggered it — the error state already
  /// reports it.
  Future<void> _reloadQuietly() async {
    setState(() {
      _future = _load();
    });
    try {
      await _future;
    } catch (_) {
      // Shown by the AsyncView.
    }
  }

  /// Opens a create/edit route and recomputes the lists if the child wrote
  /// something: both creating and deleting an entity change them.
  Future<void> _openEditor(String location) async {
    final changed = await context.push<bool>(location);
    if (changed != true || !mounted) return;
    await _reloadQuietly();
  }

  /// Opens the full upcoming list.
  ///
  /// No load here: [_load] already asked for it, and the page kicks its own as
  /// well, so this is purely a navigation.
  Future<void> _openUpcoming() => context.push('/upcoming');

  /// Route to the entity a membership belongs to, where its roster — and the
  /// approve/reject controls — live.
  String _rosterPath(Membership membership) =>
      membership.targetType == TargetType.venue
      ? venuesEditPath(membership.targetId)
      : performersEditPath(membership.targetId);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.watch<SessionController>();
    final assignments = context.watch<AssignmentsController>();
    // Read, not watch: these are caches, not the page's data. The dashboard
    // rebuilds when the assignments above recompute, which happens for every
    // change to them.
    final venues = context.read<VenueRepository>();
    final performers = context.read<PerformerRepository>();
    final user = session.user ?? const <String, dynamic>{};
    final name = user['name'] ?? user['email'] ?? l10n.userFallback;
    return Scaffold(
      appBar: AppBar(
        // No back arrow: this is home, and every other top-level screen replaces
        // this one rather than stacking on it, so there is nothing behind it to
        // return to. The way out of the signed-in area is the sign-out button
        // beside it — a second control for the same thing, shaped like "back",
        // would be a lie about where it goes.
        title: Text(l10n.dashboardTitle(name.toString())),
        actions: navActions(
          context,
          current: Destinations.mine,
          accountAction: true,
        ),
      ),
      body: FutureBuilder<void>(
        future: _future,
        builder: (context, snap) => AsyncView<void>(
          snapshot: snap,
          // The cause, not the symptom: "Cannot reach the server" and "your
          // session expired" call for different reactions, and the empty lists
          // below would suggest a third one that does not exist.
          errorMessage: snap.hasError ? errorText(l10n, snap.error!) : null,
          onRetry: _reload,
          builder: (context, _) {
            final sectionStyle = Theme.of(context).textTheme.titleLarge;
            // The one thing the dashboard cannot show from assignments alone:
            // what is actually next. It is a preview, not the full list, so the
            // card stays a fixed height however busy the schedule gets.
            //
            // Scoped to this account's assignments, through the same predicate
            // the upcoming screen and the calendar use: the repository's answer
            // covers every event on the server, and a "what is next for you"
            // card filled with bookings that touch nothing of yours would be
            // describing somebody else's week. See `lib/utils/event_scope.dart`.
            final allUpcoming = context.watch<EventRepository>().upcomingEvents;
            final performerIds = assignments.myPerformerIds;
            final venueIds = assignments.myVenueIds;
            final upcoming = allUpcoming == null
                ? null
                : [
                    for (final event in allUpcoming)
                      if (eventInScope(
                        event,
                        performerIds: performerIds,
                        venueIds: venueIds,
                      ))
                        event,
                  ];
            final invites = assignments.pendingInvites;
            final requests = assignments.incomingRequests;
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _UpcomingCard(
                    events: upcoming,
                    style: sectionStyle,
                    onOpen: _openUpcoming,
                  ),
                  const SizedBox(height: 16),
                  _SectionHeader(
                    title: l10n.myVenues,
                    actionLabel: l10n.addVenue,
                    style: sectionStyle,
                    onAction: () => _openEditor(venuesNewPath()),
                    secondaryLabel: l10n.browseVenues,
                    onSecondary: () => context.push(venuesBrowsePath()),
                  ),
                  const SizedBox(height: 8),
                  if (assignments.myVenues.isEmpty) Text(l10n.noVenueProfiles),
                  for (final venue in assignments.myVenues)
                    Card(
                      child: ListTile(
                        title: Text(venue.displayName),
                        subtitle: Text(venue.address ?? venue.id ?? ''),
                        // Labelled rather than a bare icon: this list is for
                        // managing records, so the action that does that says so.
                        // Shown only to a manager: a plain member reaches this
                        // row too, and the server refuses their edit, so the
                        // button would only ever produce a 403.
                        trailing:
                            (venue.id == null ||
                                !assignments.canManageVenue(venue.id!))
                            ? null
                            : TextButton.icon(
                                onPressed: () =>
                                    _openEditor(venuesEditPath(venue.id!)),
                                icon: const Icon(Icons.edit),
                                label: Text(l10n.manageVenue),
                              ),
                        onTap: venue.id == null
                            ? null
                            : () => context.push('/calendar/venue/${venue.id}'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _SectionHeader(
                    title: l10n.myPerformers,
                    actionLabel: l10n.addPerformer,
                    style: sectionStyle,
                    onAction: () => _openEditor(performersNewPath()),
                    // Reaching the full list is how a user finds an act they
                    // belong to but were never added to — the discovery half of
                    // the invite flow, which venues already had.
                    secondaryLabel: l10n.browsePerformers,
                    onSecondary: () => context.push(performersBrowsePath()),
                  ),
                  const SizedBox(height: 8),
                  if (assignments.myPerformers.isEmpty)
                    Text(l10n.noPerformerProfiles),
                  for (final performer in assignments.myPerformers)
                    Card(
                      child: ListTile(
                        title: Text(performer.displayName),
                        subtitle: Text(
                          performer.contact ??
                              performer.type ??
                              performer.id ??
                              '',
                        ),
                        trailing:
                            (performer.id == null ||
                                !assignments.canManagePerformer(performer.id!))
                            ? null
                            : TextButton.icon(
                                onPressed: () => _openEditor(
                                  performersEditPath(performer.id!),
                                ),
                                icon: const Icon(Icons.edit),
                                label: Text(l10n.managePerformer),
                              ),
                        onTap: performer.id == null
                            ? null
                            : () => context.push(
                                '/calendar/performer/${performer.id}',
                              ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(l10n.pendingInvites, style: sectionStyle),
                  const SizedBox(height: 8),
                  if (invites.isEmpty) Text(l10n.listEmpty),
                  for (final invite in invites)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.mail_outline),
                        // Naming the target is the point: "invited" alone does
                        // not say to what. The name is a local lookup — the
                        // invitee is not a manager yet, so there is no route to
                        // open here.
                        title: Text(
                          _inviteTarget(invite, venues, performers, l10n),
                        ),
                        // They have to accept before it grants anything, so the
                        // dashboard says who owes the action rather than
                        // implying access already exists.
                        subtitle: Text(l10n.awaitingAcceptance),
                      ),
                    ),
                  const SizedBox(height: 16),
                  // The manager-side queue. This is the whole "notification"
                  // story: there is no email channel, so a request is only ever
                  // discovered here. Each row links to the entity's roster,
                  // which is where approving actually happens — putting the
                  // decision in two places would mean two places to get it
                  // wrong.
                  Text(l10n.incomingRequestsTitle, style: sectionStyle),
                  const SizedBox(height: 8),
                  if (requests.isEmpty) Text(l10n.listEmpty),
                  for (final request in requests)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.how_to_reg_outlined),
                        title: Text(
                          _inviteTarget(request, venues, performers, l10n),
                        ),
                        subtitle: Text(l10n.rosterRequested),
                        trailing: TextButton.icon(
                          onPressed: () => _openEditor(_rosterPath(request)),
                          icon: const Icon(Icons.people_outline),
                          label: Text(l10n.decideRequestAction),
                        ),
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

  /// What a pending invitation is for, from the caches already in memory.
  ///
  /// Falls back to the invited address when the entity is not cached (the
  /// invitation can arrive before the entity list has ever been fetched), so a
  /// row always shows something a person can act on.
  String _inviteTarget(
    Membership invite,
    VenueRepository venues,
    PerformerRepository performers,
    AppLocalizations l10n,
  ) {
    final name = invite.targetType == TargetType.venue
        ? venues.byId(invite.targetId)?.displayName
        : performers.byId(invite.targetId)?.displayName;
    if (name != null && name.isNotEmpty) return name;
    return invite.pendingEmail ?? l10n.untitled;
  }
}

/// Section title with the section's create action beside it.
///
/// The actions live next to the list they add to rather than in the app bar,
/// where a single pair of "add" icons would not say which list they belong to.
/// "What is next", as a preview on the dashboard.
///
/// A fixed number of rows rather than a scrollable: this is a glance, and the
/// full list is one tap away. It renders nothing at all before the query has
/// answered — a card that says "nothing coming up" while the answer is still in
/// flight would be a lie, and the sections below it are what the dashboard is
/// for anyway.
class _UpcomingCard extends StatelessWidget {
  const _UpcomingCard({
    required this.events,
    required this.style,
    required this.onOpen,
  });

  /// Null until the first query answers.
  final List<Event>? events;
  final TextStyle? style;
  final Future<void> Function() onOpen;

  /// How many bookings the preview shows before deferring to the full list.
  static const int _previewCount = 3;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final loaded = events;
    if (loaded == null) return const SizedBox.shrink();

    final locale = Localizations.localeOf(context).toLanguageTag();
    final labels = EventLabels.of(context);
    final shown = loaded.take(_previewCount).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l10n.upcomingEvents, style: style),
            TextButton(onPressed: onOpen, child: Text(l10n.upcomingSeeAll)),
          ],
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text(l10n.noUpcoming)
        else
          Card(
            child: Column(
              children: [
                for (final event in shown)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.event_available),
                    title: Text(
                      event.title.isEmpty ? l10n.untitled : event.title,
                    ),
                    subtitle: Text(
                      [
                        formatDateTime(locale, event.start.toLocal()),
                        labels.line(event),
                      ].where((part) => part.isNotEmpty).join('\n'),
                    ),
                    onTap: onOpen,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
    this.style,
    this.secondaryLabel,
    this.onSecondary,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;
  final TextStyle? style;

  /// Optional second action, e.g. "browse all" beside "add". Given as a label
  /// rather than an icon because the section already carries an icon button for
  /// adding, and two unlabelled buttons in one row are a guessing game.
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final secondary = secondaryLabel;
    return Row(
      children: [
        Expanded(child: Text(title, style: style)),
        if (secondary != null && onSecondary != null)
          TextButton(onPressed: onSecondary, child: Text(secondary)),
        TextButton.icon(
          onPressed: onAction,
          icon: const Icon(Icons.add),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}
