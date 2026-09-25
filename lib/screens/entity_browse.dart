import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/identified.dart';
import '../models/membership.dart';
import '../models/performer.dart';
import '../models/venue.dart';
import '../nav/destinations.dart';
import '../router_paths.dart';
import '../utils/error_text.dart';
import '../widgets/async_view.dart';

/// Browsable list of every venue or performer, so an account with no
/// assignments yet still has something to open and something to ask for.
///
/// One screen serves both kinds. They differ only in labels, icons and paths —
/// every behaviour (create, manage, request access, pending state, open the
/// calendar, add an event) is identical, and two near-identical 200-line files
/// would drift the moment one of them gained a feature. The differences live in
/// [_BrowseSpec], the same shape `entity_edit.dart` uses for its editor.
///
/// Reads the collection directly rather than the account's assignment list:
/// this is "all venues", not "my venues". The real app would filter by
/// proximity; the prototype lists them all.
///
/// Management is the one exception to that rule: creating is offered to
/// everybody (it is how an account gets its first assignment), editing only for
/// the entities this account manages, and asking to join for the rest.
class EntityBrowsePage extends StatefulWidget {
  const EntityBrowsePage({super.key, required this.targetType});

  final TargetType targetType;

  @override
  State<EntityBrowsePage> createState() => _EntityBrowsePageState();
}

class _EntityBrowsePageState extends State<EntityBrowsePage> {
  late final _BrowseSpec _spec = _BrowseSpec.of(context, widget.targetType);
  late Future<List<NamedEntity>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<NamedEntity>> _load({bool force = false}) async {
    // Skipped entirely with no session, for two reasons. The list below is the
    // whole page for a visitor — the per-row actions these gate are not rendered
    // at all (see [_EntityBrowsePageState.build]) — so the fetch would be a
    // pointless round-trip that 401s. And `refresh` with no session notifies its
    // listeners synchronously rather than awaiting anything, so calling it from
    // here lands a rebuild inside this mount build and trips the framework's
    // "markNeedsBuild during build" assertion.
    if (context.read<SessionController>().isLoggedIn) {
      final assignments = context.read<AssignmentsController>();
      // Recompute the assignments alongside the list, because the "manage"
      // action is gated on them: a list that was never computed would hide it
      // for the very entities this account owns. Best-effort — the list is what
      // this page is for, so an assignment failure must not fail it (the
      // dashboard is where that failure is reported).
      try {
        await assignments.refresh(force: force);
      } catch (_) {
        // See above; the list below still loads.
      }
    }
    return _spec.load(force: force);
  }

  Future<void> _reload() async {
    setState(() {
      _future = _load(force: true);
    });
    await _future;
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Asks to be let in to an entity this account does not manage.
  ///
  /// The counterpart of the invite form: an invite can only be sent by somebody
  /// who already knows the address, so this is how a user who finds their own
  /// venue or act in the public list gets access without being found first. It
  /// creates a pending *request* the entity's managers decide — it grants
  /// nothing on its own, which is why it is safe to offer on anything at all.
  Future<void> _requestAccess(NamedEntity entity) async {
    final l10n = AppLocalizations.of(context);
    final id = entity.id;
    if (id == null || id.isEmpty) return;
    final memberships = context.read<MembershipRepository>();
    Object? error;
    try {
      await memberships.requestToJoin(
        targetType: _spec.targetType,
        targetId: id,
      );
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    if (error != null) {
      _snack(errorText(l10n, error));
      return;
    }
    try {
      await context.read<AssignmentsController>().refresh(force: true);
    } catch (_) {
      // The request succeeded; a failed re-read only delays showing it.
    }
    if (!mounted) return;
    _snack(l10n.requestSent);
    try {
      await _reload();
    } catch (_) {
      // See above.
    }
  }

  /// Opens a create/edit route and refetches this list when the child reports a
  /// write, since either one changes what belongs here.
  Future<void> _openEditor(String location) async {
    final changed = await context.push<bool>(location);
    if (changed != true || !mounted) return;
    try {
      await _reload();
    } catch (_) {
      // The list keeps its previous contents and the AsyncView reports the
      // failure; the write itself already succeeded.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final assignments = context.watch<AssignmentsController>();
    // Read here rather than in the action builders: signed out, the whole
    // per-row action area disappears and the create button goes with it, so the
    // decision belongs where they are laid out. This is a destination that is
    // deliberately reachable without a session (see [Destination.requiresAuth]),
    // which is what makes the signed-out branch reachable at all.
    final signedIn = context.watch<SessionController>().isLoggedIn;
    // Entities I have an outstanding request for, so the action can show as
    // pending instead of being offered again (the server refuses a duplicate
    // request, and a button that always errors is worse than the state).
    final requested = {
      for (final m in assignments.myRequests)
        if (m.targetType == _spec.targetType) m.targetId,
    };

    return Scaffold(
      appBar: AppBar(
        leading: backToHomeButton(context),
        title: Text(_spec.title(l10n)),
        // The app's destinations, minus this one — so the sibling list is here
        // ("where are the performers?" is the first question somebody on the
        // venue list asks) and so is the calendar, which used to be reachable
        // from this screen only by popping back to the dashboard.
        actions: navActions(
          context,
          current: _spec.destination,
          accountAction: true,
        ),
      ),
      // On the Scaffold rather than in the list, so the empty state — the one a
      // brand-new account sees — offers the same way forward. Signed out there
      // is nobody to own the record, and creating one requires a session, so the
      // button is withheld rather than shown as a form that cannot submit.
      floatingActionButton: !signedIn
          ? null
          : FloatingActionButton(
              tooltip: _spec.addLabel(l10n),
              onPressed: () => _openEditor(_spec.newPath),
              child: const Icon(Icons.add),
            ),
      body: FutureBuilder<List<NamedEntity>>(
        future: _future,
        builder: (context, snap) => AsyncView<List<NamedEntity>>(
          snapshot: snap,
          errorMessage: snap.hasError ? errorText(l10n, snap.error!) : null,
          onRetry: _reload,
          builder: (context, entities) {
            if (entities.isEmpty) {
              return Center(child: Text(_spec.emptyMessage(l10n)));
            }
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.builder(
                itemCount: entities.length,
                itemBuilder: (context, i) {
                  final entity = entities[i];
                  final id = entity.id ?? '';
                  // Two different questions, and conflating them is what put a
                  // dead pencil in front of a plain member: `assigned` is "I
                  // belong here", which the events guard accepts for booking,
                  // while `managed` is "I administer this", which is the only
                  // thing an edit or a roster change is allowed to require.
                  final assigned =
                      id.isNotEmpty && _spec.isManaged(assignments, id);
                  final managed =
                      id.isNotEmpty && _spec.canManage(assignments, id);
                  return Card(
                    child: ListTile(
                      leading: Icon(_spec.destination.icon),
                      title: Text(entity.displayName),
                      subtitle: Text(_spec.subtitle(entity)),
                      // Signed out: no manage, no request, no pending marker —
                      // all three describe a relationship between this visitor
                      // and the entity, and there is no visitor to have one.
                      // The row still opens its calendar, which is the one thing
                      // a reader can do here (and which asks them to sign in on
                      // the way, see the redirect in lib/router.dart).
                      trailing: (id.isEmpty || !signedIn)
                          ? null
                          : managed
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.add),
                                  tooltip: _spec.eventTooltip(l10n),
                                  onPressed: () =>
                                      context.push(_spec.newEventPath(entity)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit),
                                  tooltip: _spec.manageTooltip(l10n),
                                  onPressed: () =>
                                      _openEditor(_spec.editPath(id)),
                                ),
                              ],
                            )
                          : assigned
                          // A member books events here but cannot rename or
                          // re-roster the entity, so the create action stays and
                          // the manage one goes. Showing "Solicitar acesso"
                          // instead would be worse than useless: they already
                          // have access.
                          ? IconButton(
                              icon: const Icon(Icons.add),
                              tooltip: _spec.eventTooltip(l10n),
                              onPressed: () =>
                                  context.push(_spec.newEventPath(entity)),
                            )
                          : (requested.contains(id)
                                ? Tooltip(
                                    message: l10n.requestPending,
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Icon(Icons.hourglass_empty),
                                    ),
                                  )
                                : IconButton(
                                    icon: const Icon(Icons.how_to_reg_outlined),
                                    tooltip: l10n.requestAccess,
                                    onPressed: () => _requestAccess(entity),
                                  )),
                      onTap: id.isEmpty
                          ? null
                          : () => context.push(_spec.calendarPath(id)),
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

/// Everything that differs between the venue and performer browse lists.
///
/// A plain data object rather than subclasses: unlike the editor spec, there is
/// no per-kind state or extra behaviour here, only labels, paths and how to load
/// the list. Keeping it in one place is what makes it obvious that the two kinds
/// really do behave identically.
class _BrowseSpec {
  const _BrowseSpec({
    required this.targetType,
    required this.title,
    required this.destination,
    required this.addLabel,
    required this.manageTooltip,
    required this.eventTooltip,
    required this.newPath,
    required this.emptyMessage,
    required this.load,
    required this.isManaged,
    required this.canManage,
    required this.subtitle,
    required this.editPath,
    required this.calendarPath,
    required this.newEventPath,
  });

  final TargetType targetType;
  final String Function(AppLocalizations) title;

  /// This list's own destination. Carries the kind's icon for the rows below,
  /// and tells the top bar which entry to leave out.
  final Destination destination;
  final String Function(AppLocalizations) addLabel;
  final String Function(AppLocalizations) manageTooltip;
  final String Function(AppLocalizations) eventTooltip;
  final String newPath;
  final String Function(AppLocalizations) emptyMessage;
  final Future<List<NamedEntity>> Function({bool force}) load;
  final bool Function(AssignmentsController, String id) isManaged;

  /// Narrower than [isManaged]: whether the account holds an active **manager**
  /// row, which is what the server demands before it will let the record be
  /// renamed, re-rostered or deleted.
  final bool Function(AssignmentsController, String id) canManage;
  final String Function(NamedEntity) subtitle;
  final String Function(String id) editPath;
  final String Function(String id) calendarPath;
  final String Function(NamedEntity) newEventPath;

  /// Builds the spec for [type], binding the matching repository from
  /// [context] so the widget itself stays free of per-kind knowledge.
  factory _BrowseSpec.of(BuildContext context, TargetType type) {
    switch (type) {
      case TargetType.venue:
        final repo = context.read<VenueRepository>();
        return _BrowseSpec(
          targetType: TargetType.venue,
          title: (l10n) => l10n.venuesTitle,
          destination: Destinations.venues,
          addLabel: (l10n) => l10n.addVenue,
          manageTooltip: (l10n) => l10n.manageVenue,
          eventTooltip: (l10n) => l10n.newEventForVenue,
          newPath: venuesNewPath(),
          emptyMessage: (l10n) => l10n.noVenuesFound,
          load: ({bool force = false}) async {
            await repo.load(force: force);
            return repo.items;
          },
          isManaged: (assignments, id) => assignments.isMyVenue(id),
          canManage: (assignments, id) => assignments.canManageVenue(id),
          subtitle: (entity) => (entity as Venue).address ?? '',
          editPath: venuesEditPath,
          calendarPath: (id) => entityCalendarPath('venue', id),
          newEventPath: (entity) => eventsNewPath(
            venueId: entity.id,
            venueName: entity.displayName,
            lockVenue: true,
          ),
        );

      case TargetType.performer:
        final repo = context.read<PerformerRepository>();
        return _BrowseSpec(
          targetType: TargetType.performer,
          title: (l10n) => l10n.performers,
          destination: Destinations.performers,
          addLabel: (l10n) => l10n.addPerformer,
          manageTooltip: (l10n) => l10n.managePerformer,
          eventTooltip: (l10n) => l10n.newEventForPerformer,
          newPath: performersNewPath(),
          emptyMessage: (l10n) => l10n.noPerformersFound,
          load: ({bool force = false}) async {
            await repo.load(force: force);
            return repo.items;
          },
          isManaged: (assignments, id) => assignments.isMyPerformer(id),
          canManage: (assignments, id) => assignments.canManagePerformer(id),
          subtitle: (entity) {
            final performer = entity as Performer;
            return performer.contact ?? performer.type ?? '';
          },
          editPath: performersEditPath,
          calendarPath: (id) => entityCalendarPath('performer', id),
          // A performer booking is not locked to a venue: the act plays
          // wherever they are booked, so the form is left open to pick one.
          newEventPath: (entity) => eventsNewPath(performerId: entity.id),
        );
    }
  }
}
