/// Create/edit screens for the two ownable entity kinds.
///
/// Creating a record is how an account gets attached to it: the entity hook
/// inserts the creator's `memberships` row inside the same request (see
/// pb_hooks/entities.guard.pb.js), which is why the create path refreshes
/// [AssignmentsController] before it pops — otherwise the venue the user just
/// made would be missing from "my entities" until the next cold start.
///
/// Venue and performer differ in four columns and one collection name, so the
/// screen — load, validation, save, delete, team management — is written once
/// against [_EntitySpec] instead of twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/identified.dart';
import '../models/membership.dart';
import '../models/performer.dart';
import '../models/user_lookup.dart';
import '../models/venue.dart';
import '../router_paths.dart';
import '../services/pocketbase_service.dart';
import '../utils/entity_names.dart';
import '../utils/error_text.dart';

/// Loosest pattern that still catches a typo. The server is the authority on
/// which addresses exist, and a stricter client rule would reject legal but
/// unusual addresses before the invitation ever reached it.
final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Create/edit form for a venue, including who manages it.
class VenueEditPage extends StatefulWidget {
  const VenueEditPage({super.key, this.venueId});

  /// Record to edit. Null creates a new venue.
  final String? venueId;

  @override
  State<VenueEditPage> createState() => _VenueEditPageState();
}

class _VenueEditPageState extends State<VenueEditPage> {
  /// Built once: the spec owns the text controllers, so recreating it on a
  /// rebuild would throw away whatever the user has typed.
  late final _VenueSpec _spec;

  @override
  void initState() {
    super.initState();
    _spec = _VenueSpec(context.read<VenueRepository>());
  }

  @override
  void dispose() {
    _spec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EntityEditor<Venue>(spec: _spec, entityId: widget.venueId);
}

/// Create/edit form for a performer, including its members.
class PerformerEditPage extends StatefulWidget {
  const PerformerEditPage({super.key, this.performerId});

  /// Record to edit. Null creates a new performer.
  final String? performerId;

  @override
  State<PerformerEditPage> createState() => _PerformerEditPageState();
}

class _PerformerEditPageState extends State<PerformerEditPage> {
  late final _PerformerSpec _spec;

  @override
  void initState() {
    super.initState();
    _spec = _PerformerSpec(context.read<PerformerRepository>());
  }

  @override
  void dispose() {
    _spec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EntityEditor<Performer>(spec: _spec, entityId: widget.performerId);
}

/// The form itself, shared by both record kinds.
class _EntityEditor<T extends NamedEntity> extends StatefulWidget {
  const _EntityEditor({super.key, required this.spec, this.entityId});

  final _EntitySpec<T> spec;

  /// Record to edit, or null to create one.
  final String? entityId;

  @override
  State<_EntityEditor<T>> createState() => _EntityEditorState<T>();
}

/// The user's answer to the duplicate prompt.
enum _DuplicateChoice { cancel, create, claim }

class _EntityEditorState<T extends NamedEntity>
    extends State<_EntityEditor<T>> {
  final _formKey = GlobalKey<FormState>();

  /// Null in create mode, where there is nothing to resolve before the form can
  /// be shown.
  Future<T?>? _future;
  bool _busy = false;

  /// The id being edited, or null to create.
  ///
  /// The router hands the path segment through verbatim, so an empty segment
  /// must mean "create" rather than "edit the record whose id is ''".
  String? get _id {
    final id = widget.entityId;
    return (id == null || id.isEmpty) ? null : id;
  }

  @override
  void initState() {
    super.initState();
    final id = _id;
    if (id != null) _future = _load(id);
  }

  /// Resolves the record being edited and seeds the form with it.
  ///
  /// The seeding happens here rather than in `build`: assigning a controller
  /// notifies its field, and rebuilding a field during a build is illegal.
  Future<T?> _load(String id) async {
    final spec = widget.spec;
    await spec.loadCache();
    var entity = spec.cached(id);
    if (entity == null) {
      // A deep link (or a fresh tab) can land here before any cache pass that
      // contains this record has run; one forced refetch is the difference
      // between "gone" and "not loaded yet".
      await spec.loadCache(force: true);
      entity = spec.cached(id);
    }
    if (entity != null) spec.fill(entity);
    return entity;
  }

  void _reload() {
    final id = _id;
    if (id != null) {
      setState(() {
        _future = _load(id);
      });
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final spec = widget.spec;
    final id = _id;

    // Creating is the only path where a duplicate can appear: an edit is
    // already pointed at one record.
    if (id == null) {
      // True means "it is safe to create": either nothing matched, or the user
      // chose to create anyway. Every other outcome (claim, open, cancel) has
      // already navigated or returned, so this must not fall through to a write.
      final mayCreate = await _resolveDuplicate();
      if (!mounted || !mayCreate) return;
    }

    setState(() => _busy = true);
    Object? error;
    try {
      // `body()` comes from the model's writable fields, so an edit patches
      // exactly those columns and never `createdBy` (server-set, see the models).
      final body = spec.body();
      if (id == null) {
        await spec.create(body);
      } else {
        await spec.update(id, body);
      }
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    if (error != null) {
      _snack(errorText(l10n, error));
      return;
    }

    await _refreshAssignments(context);
    if (!mounted) return;
    _snack(id == null ? l10n.entityCreated : l10n.entityUpdated);
    context.pop(true);
  }

  /// What the user chose when a same-named record already existed.
  ///
  /// Three outcomes, not two: "create anyway" and "claim it" both continue, but
  /// they must diverge (one writes a new record, the other adopts the existing
  /// one). Modelling the choice as a bool collapsed them, so "create anyway"
  /// silently claimed the other record instead of creating anything.
  Future<_DuplicateChoice> _promptDuplicate(T match) async {
    final l10n = AppLocalizations.of(context);
    final assignments = context.read<AssignmentsController>();
    final matchId = match.id;
    final mine =
        matchId != null &&
        (widget.spec.targetType == TargetType.venue
            ? assignments.isMyVenue(matchId)
            : assignments.isMyPerformer(matchId));

    final typeLabel = widget.spec.targetType == TargetType.venue
        ? l10n.venue
        : l10n.performer;

    return await showDialog<_DuplicateChoice>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              l10n.duplicateExistsTitle(typeLabel, match.displayName),
            ),
            content: Text(
              mine ? l10n.duplicateAlreadyMineBody : l10n.duplicateClaimBody,
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_DuplicateChoice.cancel),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_DuplicateChoice.create),
                child: Text(l10n.createAnywayAction),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_DuplicateChoice.claim),
                child: Text(
                  mine ? l10n.openEntityAction : l10n.claimEntityAction,
                ),
              ),
            ],
          ),
        ) ??
        _DuplicateChoice.cancel;
  }

  /// Guards the create path against splitting an entity in two.
  ///
  /// Two records for the same venue share no id, and the server's conflict check
  /// compares `venueId` — so both accept a booking for the same room at the same
  /// hour and neither can see the other. Offering a claim is what stops that,
  /// and it is also how an unreachable seeded entity (one with no manager)
  /// becomes usable.
  ///
  /// Advisory by design: two genuinely different venues can share a name, and a
  /// check that runs before the write cannot close the race where two people
  /// submit at once. That is why "create anyway" is offered rather than the
  /// duplicate being refused.
  Future<bool> _resolveDuplicate() async {
    final l10n = AppLocalizations.of(context);
    final name = widget.spec.name.text.trim();
    if (name.isEmpty) return true;

    final spec = widget.spec;
    List<T> candidates;
    try {
      candidates = await spec.all();
    } catch (_) {
      // The lookup is a courtesy. Failing it must not block creating a record,
      // which is the operation the user actually asked for.
      return true;
    }
    if (!mounted) return false;

    final match = candidates
        .where((c) => c.id != null && sameEntityName(c.name, name))
        .firstOrNull;
    if (match == null) return true;

    final choice = await _promptDuplicate(match);
    if (!mounted) return false;
    // Explicitly asked to keep both: this is the one branch that returns to the
    // caller's create, and it must not fall through into the claim below.
    if (choice == _DuplicateChoice.create) return true;
    if (choice != _DuplicateChoice.claim) return false;

    // "Claim it" and "Open it" both resolve to the same record; which verb the
    // user saw depends only on whether they already manage it.
    final matchId = match.id!;
    final assignments = context.read<AssignmentsController>();
    final mine = spec.targetType == TargetType.venue
        ? assignments.isMyVenue(matchId)
        : assignments.isMyPerformer(matchId);

    if (mine) {
      // Already theirs: send them to it rather than writing a second record.
      context.pushReplacement(
        spec.targetType == TargetType.venue
            ? venuesEditPath(matchId)
            : performersEditPath(matchId),
      );
      return false;
    }

    setState(() => _busy = true);
    Object? error;
    try {
      await spec.claim(matchId);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return false;
    if (error != null) {
      // 409 means somebody else got there first; the server's wording explains
      // that far better than a generic failure.
      _snack(errorText(l10n, error));
      return false;
    }

    await _refreshAssignments(context);
    if (!mounted) return false;
    _snack(l10n.claimSucceeded(match.displayName));
    context.pop(true);
    return false;
  }

  Future<void> _delete(T entity) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.confirmDeleteTitle(entity.displayName)),
        content: Text(l10n.confirmDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final id = entity.id;
    if (id == null) return;

    setState(() => _busy = true);
    Object? error;
    try {
      await widget.spec.delete(id);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    if (error != null) {
      // The server refuses to delete a record other records still point at
      // ("Venue still has events. Remove or reassign them first."). That
      // sentence is the honest explanation, and re-deriving the reference
      // check here to phrase it differently would only add a second place to
      // get the rule wrong.
      _snack(errorText(l10n, error));
      return;
    }

    await _refreshAssignments(context);
    if (!mounted) return;
    _snack(l10n.entityDeleted);
    context.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final future = _future;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.spec.title(l10n, editing: future != null)),
      ),
      // The load states are spelled out instead of using AsyncView: its content
      // builder only runs for non-null data (`requireData` asserts), and "this
      // record does not exist" is exactly a null result. The failure text still
      // comes from errorText, like every other screen.
      body: future == null
          ? _form(l10n, null)
          : FutureBuilder<T?>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return _loadFailed(context, l10n, snapshot.error!);
                }
                final entity = snapshot.data;
                if (entity == null) {
                  // Deleted since the link was copied, or not visible to this
                  // account. That is an answer, not a failure: no retry loop.
                  return Center(child: Text(l10n.notFound));
                }
                return _form(l10n, entity);
              },
            ),
    );
  }

  Widget _loadFailed(
    BuildContext context,
    AppLocalizations l10n,
    Object error,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(errorText(l10n, error)),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _reload, child: Text(l10n.retry)),
        ],
      ),
    );
  }

  Widget _form(AppLocalizations l10n, T? entity) {
    final spec = widget.spec;
    final target = entity;
    final targetId = target?.id;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextFormField(
            controller: spec.name,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(labelText: spec.nameLabel(l10n)),
            // The server requires at least one character; catching it here puts
            // the complaint next to the field instead of in a snack bar.
            validator: (value) =>
                (value ?? '').trim().isEmpty ? l10n.titleRequired : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: spec.contact,
            decoration: InputDecoration(labelText: l10n.contactLabel),
          ),
          for (final field in spec.fields(l10n)) ...[
            const SizedBox(height: 12),
            field,
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _busy ? null : _save,
            child: _busy ? const CircularProgressIndicator() : Text(l10n.save),
          ),
          if (target != null && targetId != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _delete(target),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.delete),
            ),
            const SizedBox(height: 24),
            // Only once the record has an id: an unsaved create has nothing to
            // attach a membership row to, and the creator's own row is written
            // by the server when the create lands.
            _TeamSection(targetId: targetId, targetType: spec.targetType),
          ],
        ],
      ),
    );
  }
}

/// One entity kind's form state and its server calls.
///
/// Holds this kind's controllers so the shared editor never has to know which
/// columns exist, and builds the write body from the typed model, which is what
/// keeps server-managed `createdBy` out of every request by construction.
abstract class _EntitySpec<T extends NamedEntity> {
  _EntitySpec(this.service);

  @protected
  final PocketBaseService service;

  /// Columns every ownable record has.
  final name = TextEditingController();
  final contact = TextEditingController();

  /// Which collection family this record belongs to; also decides the role a
  /// new collaborator gets.
  TargetType get targetType;

  String title(AppLocalizations l10n, {required bool editing});

  /// Label of the required name field, phrased for this kind.
  String nameLabel(AppLocalizations l10n);

  /// This kind's remaining fields, in display order.
  List<Widget> fields(AppLocalizations l10n);

  /// Fields a client may write, and nothing else.
  Map<String, dynamic> body();

  /// Resolves [id] from the cache [loadCache] fills.
  T? cached(String id);

  Future<void> loadCache({bool force = false});

  /// Copies [entity]'s values into the controllers.
  void fill(T entity);

  Future<void> create(Map<String, dynamic> body);

  Future<void> update(String id, Map<String, dynamic> body);

  Future<void> delete(String id);

  /// Every known record of this kind, for the duplicate comparison.
  ///
  /// Deliberately the whole loaded set rather than a name query. The server's
  /// search is a raw substring match, so it cannot answer the question this
  /// check actually asks: `"harbor  hall!"` is a substring of nothing, and a
  /// name-query prefilter would therefore report "no duplicate" for exactly the
  /// misspellings the comparison exists to catch. Matching happens locally
  /// against [sameEntityName], which is the only place the fuzzy rule lives.
  Future<List<T>> all();

  /// Adopts an existing record of this kind for the signed-in user.
  Future<void> claim(String id);

  /// The record is missing from the server as far as this client is concerned;
  /// the editor turns a null lookup into its own message.
  void dispose() {
    name.dispose();
    contact.dispose();
  }
}

class _VenueSpec extends _EntitySpec<Venue> {
  _VenueSpec(this._venues) : super(PocketBaseService.shared);

  final VenueRepository _venues;
  final address = TextEditingController();
  final capacity = TextEditingController();
  final timezone = TextEditingController();

  @override
  TargetType get targetType => TargetType.venue;

  @override
  String title(AppLocalizations l10n, {required bool editing}) =>
      editing ? l10n.editVenue : l10n.createVenue;

  @override
  String nameLabel(AppLocalizations l10n) => l10n.venueNameLabel;

  @override
  List<Widget> fields(AppLocalizations l10n) => [
    TextFormField(
      controller: address,
      decoration: InputDecoration(labelText: l10n.addressLabel),
    ),
    TextFormField(
      controller: capacity,
      keyboardType: TextInputType.number,
      // Digits only, so an unparseable capacity cannot be typed — which is
      // why this field needs no validator and no error message of its own.
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: l10n.capacityLabel),
    ),
    TextFormField(
      controller: timezone,
      decoration: InputDecoration(labelText: l10n.timezoneLabel),
    ),
  ];

  @override
  Map<String, dynamic> body() => Venue(
    name: name.text.trim(),
    address: _blankToNull(address.text),
    contact: _blankToNull(contact.text),
    capacity: int.tryParse(capacity.text.trim()),
    timezone: _blankToNull(timezone.text),
  ).toWriteMap();

  @override
  Venue? cached(String id) => _venues.byId(id);

  @override
  Future<void> loadCache({bool force = false}) => _venues.load(force: force);

  @override
  void fill(Venue venue) {
    name.text = venue.name;
    address.text = venue.address ?? '';
    contact.text = venue.contact ?? '';
    capacity.text = venue.capacity?.toString() ?? '';
    timezone.text = venue.timezone ?? '';
  }

  @override
  Future<void> create(Map<String, dynamic> body) => service.createVenue(body);

  @override
  Future<List<Venue>> all() async {
    await _venues.load();
    return _venues.items;
  }

  @override
  Future<void> claim(String id) =>
      service.claimEntity(targetType: TargetType.venue, targetId: id);

  @override
  Future<void> update(String id, Map<String, dynamic> body) =>
      service.updateVenue(id, body);

  @override
  Future<void> delete(String id) => service.deleteVenue(id);

  @override
  void dispose() {
    address.dispose();
    capacity.dispose();
    timezone.dispose();
    super.dispose();
  }
}

class _PerformerSpec extends _EntitySpec<Performer> {
  _PerformerSpec(this._performers) : super(PocketBaseService.shared);

  final PerformerRepository _performers;
  final type = TextEditingController();

  @override
  TargetType get targetType => TargetType.performer;

  @override
  String title(AppLocalizations l10n, {required bool editing}) =>
      editing ? l10n.editPerformer : l10n.createPerformer;

  @override
  String nameLabel(AppLocalizations l10n) => l10n.performerNameLabel;

  @override
  List<Widget> fields(AppLocalizations l10n) => [
    TextFormField(
      controller: type,
      decoration: InputDecoration(labelText: l10n.typeLabel),
    ),
  ];

  @override
  Map<String, dynamic> body() => Performer(
    name: name.text.trim(),
    contact: _blankToNull(contact.text),
    type: _blankToNull(type.text),
  ).toWriteMap();

  @override
  Performer? cached(String id) => _performers.byId(id);

  @override
  Future<void> loadCache({bool force = false}) =>
      _performers.load(force: force);

  @override
  void fill(Performer performer) {
    name.text = performer.name;
    contact.text = performer.contact ?? '';
    type.text = performer.type ?? '';
  }

  @override
  Future<void> create(Map<String, dynamic> body) =>
      service.createPerformer(body);

  @override
  Future<List<Performer>> all() async {
    await _performers.load();
    return _performers.items;
  }

  @override
  Future<void> claim(String id) =>
      service.claimEntity(targetType: TargetType.performer, targetId: id);

  @override
  Future<void> update(String id, Map<String, dynamic> body) =>
      service.updatePerformer(id, body);

  @override
  Future<void> delete(String id) => service.deletePerformer(id);

  @override
  void dispose() {
    type.dispose();
    super.dispose();
  }
}

/// Membership management for one saved record: who is on it, who is still only
/// invited, and the invite form.
///
/// Membership is a collection of its own rather than an id list on the record
/// (see [Membership]), so this section is the only place a record gains or
/// loses collaborators.
///
/// The rows come from `GET /api/agenda/roster`, not from the repository. The
/// collection's list rule is self-only — it exposes my rows and invitations
/// addressed to my address — which is the right privacy default and useless for
/// a team list: it would show this manager their own row and nobody else's. The
/// rule cannot express "every row of an entity I actively manage" because
/// `targetId` is plain text rather than a relation, so the roster is served by
/// an explicit endpoint that authorizes by membership. A consequence worth
/// knowing: a plain `member` gets 403 from it, so this section checks the local
/// role first and simply does not render for them.
class _TeamSection extends StatefulWidget {
  const _TeamSection({required this.targetId, required this.targetType});

  final String targetId;
  final TargetType targetType;

  @override
  State<_TeamSection> createState() => _TeamSectionState();
}

class _TeamSectionState extends State<_TeamSection> {
  final _inviteKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  late Future<List<Membership>> _future;
  bool _inviting = false;
  String? _busyId;

  /// Display name of an already-registered invitee, once looked up.
  String? _inviteeName;

  @override
  void initState() {
    super.initState();
    _future = _loadRoster();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  /// True when this account holds an **active manager** membership for the
  /// record, which is exactly what the roster endpoint requires.
  ///
  /// Checked locally from the caller's own membership rows so a plain member
  /// never sees controls the server would refuse — and never sees a 403 dressed
  /// up as a broken team list.
  bool get _canManageRoster {
    final memberships = context.read<AssignmentsController>().myMemberships;
    for (final membership in memberships) {
      if (membership.targetId == widget.targetId &&
          membership.targetType == widget.targetType &&
          membership.isActive &&
          membership.isManager) {
        return true;
      }
    }
    return false;
  }

  Future<List<Membership>> _loadRoster() => context
      .read<MembershipRepository>()
      .roster(targetType: widget.targetType, targetId: widget.targetId);

  /// Refetches the roster.
  ///
  /// The `setState` body is a BLOCK, not an arrow: an arrow body
  /// (`setState(() => _future = _loadRoster())`) evaluates to the assigned
  /// value — a `Future` — and `setState` asserts that its callback returns
  /// nothing, so every invite/approve/role-change aborted the frame in debug
  /// and never refetched. The same shape appears wherever a future is parked in
  /// state (this screen's `_reload`, `UserDashboardPage`, `VenueBrowsePage`).
  void _reload() {
    setState(() {
      _future = _loadRoster();
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _invite() async {
    final l10n = AppLocalizations.of(context);
    if (!(_inviteKey.currentState?.validate() ?? false)) return;

    final email = _email.text.trim();
    final repo = context.read<MembershipRepository>();
    setState(() => _inviting = true);
    Object? error;
    try {
      await repo.invite(
        targetId: widget.targetId,
        targetType: widget.targetType,
        email: email,
        // The role follows the record kind: a venue invite makes a co-manager,
        // a performer invite a member.
        role: widget.targetType == TargetType.venue ? 'manager' : 'member',
      );
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _inviting = false);
    }

    if (!mounted) return;
    if (error != null) {
      _snack(_inviteErrorText(l10n, error));
      return;
    }

    await _refreshAssignments(context);
    if (!mounted) return;
    _email.clear();
    _inviteeName = null;
    _reload();
    _snack(l10n.inviteSent(email));
  }

  /// Accepts or declines an invitation addressed to this account.
  /// Looks up whether the typed address already has an account.
  ///
  /// Purely a courtesy on the invite form: the server resolves the address
  /// either way, so this only changes what the helper text promises. A failed or
  /// gated lookup (the endpoint 403s a caller who manages nothing) therefore
  /// stays silent rather than reporting an error the user cannot act on.
  Future<void> _lookupInvitee() async {
    final email = _email.text.trim();
    if (!_emailPattern.hasMatch(email)) return;
    final service = context.read<MembershipRepository>().service;
    UserLookup? found;
    try {
      found = await service.lookupUser(email);
    } catch (_) {
      found = null;
    }
    if (!mounted) return;
    // Only report a positive result; "does not exist" needs no message because
    // the standing helper text already describes what happens then.
    setState(
      () => _inviteeName = (found != null && found.exists) ? found.name : null,
    );
  }

  Future<void> _respond(Membership membership, {required bool accept}) async {
    final l10n = AppLocalizations.of(context);
    final id = membership.id;
    if (id == null) return;
    final repo = context.read<MembershipRepository>();
    setState(() => _busyId = id);
    Object? error;
    try {
      await repo.respond(membershipId: id, accept: accept);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    if (!mounted) return;
    if (error != null) {
      _snack(errorText(l10n, error));
      return;
    }
    await _refreshAssignments(context);
    if (!mounted) return;
    _reload();
  }

  /// Approves or rejects somebody's request to join, or withdraws my own.
  ///
  /// Distinct from [_respond] on purpose: that one is the *invitee* answering an
  /// invitation, this one is a *manager* deciding a request. The server keeps
  /// them apart too (a requester cannot approve their own request), and folding
  /// the two into one call would erase that distinction — the manager branch
  /// would become reachable by the very person it is meant to gate.
  Future<void> _decide(Membership membership, {required bool approve}) async {
    final l10n = AppLocalizations.of(context);
    final id = membership.id;
    if (id == null) return;
    final repo = context.read<MembershipRepository>();
    setState(() => _busyId = id);
    Object? error;
    try {
      await repo.decide(membershipId: id, approve: approve);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    if (!mounted) return;
    if (error != null) {
      _snack(errorText(l10n, error));
      return;
    }
    await _refreshAssignments(context);
    if (!mounted) return;
    _reload();
  }

  Future<void> _setRole(Membership membership, String role) async {
    final l10n = AppLocalizations.of(context);
    final id = membership.id;
    if (id == null || membership.role == role) return;
    final repo = context.read<MembershipRepository>();
    setState(() => _busyId = id);
    Object? error;
    try {
      await repo.setRole(membershipId: id, role: role);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    if (!mounted) return;
    if (error != null) {
      // The last active manager cannot be demoted, and the server's wording
      // says so better than anything reconstructed here.
      _snack(errorText(l10n, error));
      return;
    }
    await _refreshAssignments(context);
    if (!mounted) return;
    _reload();
  }

  Future<void> _remove(Membership membership) async {
    final l10n = AppLocalizations.of(context);
    final id = membership.id;
    if (id == null) return;
    final repo = context.read<MembershipRepository>();
    setState(() => _busyId = id);
    Object? error;
    try {
      await repo.remove(id);
    } catch (e) {
      error = e;
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
    if (!mounted) return;
    if (error != null) {
      _snack(errorText(l10n, error));
      return;
    }
    await _refreshAssignments(context);
    if (!mounted) return;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isVenue = widget.targetType == TargetType.venue;
    // An entity with no manager left would be unadministrable, so the server
    // refuses to remove the last one; this only has to avoid offering it.
    if (!_canManageRoster) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isVenue ? l10n.managerSectionTitle : l10n.memberSectionTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        FutureBuilder<List<Membership>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            if (snapshot.hasError) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(errorText(l10n, snapshot.error!)),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _reload, child: Text(l10n.retry)),
                ],
              );
            }
            final rows = snapshot.data ?? const <Membership>[];
            if (rows.isEmpty) return Text(l10n.listEmpty);
            return Column(children: [for (final row in rows) _row(l10n, row)]);
          },
        ),
        const SizedBox(height: 12),
        Form(
          key: _inviteKey,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(
                    labelText: l10n.inviteEmailLabel,
                    // An invitation is now a request, not a grant: it stays
                    // pending until the invitee accepts, so the old "they join
                    // as soon as they sign in" wording would be a lie. When the
                    // address is known to have an account, say so by name
                    // instead — same meaning, less doubt for the inviter.
                    helperText: _inviteeName == null
                        ? l10n.inviteNeedsAcceptance
                        : l10n.accountExists(_inviteeName!),
                  ),
                  onChanged: (_) {
                    if (_inviteeName != null) {
                      setState(() => _inviteeName = null);
                    }
                  },
                  onFieldSubmitted: (_) => _lookupInvitee(),
                  validator: (value) =>
                      _emailPattern.hasMatch((value ?? '').trim())
                      ? null
                      : l10n.emailInvalid,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: FilledButton(
                  onPressed: _inviting ? null : _invite,
                  child: _inviting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(isVenue ? l10n.addManager : l10n.addMember),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(AppLocalizations l10n, Membership membership) {
    final id = membership.id;
    final busy = id != null && _busyId == id;
    final roleLabel = membership.isManager ? l10n.roleManager : l10n.roleMember;

    // A pending row has two possible owners, and which one it has decides the
    // action. An INVITATION is answered by the person it was sent to (consent);
    // a REQUEST is decided by a manager of the entity (approval). Showing the
    // wrong one is how a manager would end up "accepting" their own members'
    // invitations, or a requester would see an approve button the server
    // refuses.
    final iAmInvitee =
        membership.isPending &&
        membership.isSelf &&
        !membership.initiatedByRequest;
    final iMustDecide =
        membership.isPending &&
        !membership.isSelf &&
        membership.initiatedByRequest;
    // My own outstanding request: withdrawable, not approvable.
    final iRequested = membership.isPending && membership.requestedByMe;
    // An active row is managed by any manager, but a manager must not be able
    // to strip their own last remaining rights by accident; the server refuses
    // that case and says why.
    final canManage = membership.isActive;

    return Card(
      child: ListTile(
        leading: Icon(
          membership.isPending
              ? (membership.initiatedByRequest
                    ? Icons.how_to_reg_outlined
                    : Icons.mail_outline)
              : (membership.isManager
                    ? Icons.shield_outlined
                    : Icons.person_outline),
        ),
        title: Text(_label(l10n, membership)),
        subtitle: Text(
          membership.isPending
              ? '${membership.initiatedByRequest ? l10n.rosterRequested : l10n.awaitingAcceptance} · $roleLabel'
              : roleLabel,
        ),
        trailing: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (iAmInvitee) ...[
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: l10n.rosterApprove,
                      onPressed: () => _respond(membership, accept: true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel_outlined),
                      tooltip: l10n.rosterReject,
                      onPressed: () => _respond(membership, accept: false),
                    ),
                  ],
                  if (iMustDecide) ...[
                    IconButton(
                      icon: const Icon(Icons.check_circle_outline),
                      tooltip: l10n.approveRequest,
                      onPressed: () => _decide(membership, approve: true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.cancel_outlined),
                      tooltip: l10n.rejectRequest,
                      onPressed: () => _decide(membership, approve: false),
                    ),
                  ],
                  if (iRequested)
                    IconButton(
                      icon: const Icon(Icons.undo),
                      tooltip: l10n.withdrawRequest,
                      // Withdrawing is a rejection of my own request; the
                      // server accepts it because the manager branch is
                      // separate.
                      onPressed: () => _decide(membership, approve: false),
                    ),
                  if (canManage) ...[
                    PopupMenuButton<String>(
                      tooltip: l10n.changeRole,
                      icon: const Icon(Icons.manage_accounts_outlined),
                      onSelected: (role) => _setRole(membership, role),
                      itemBuilder: (context) => [
                        CheckedPopupMenuItem(
                          value: 'manager',
                          checked: membership.isManager,
                          child: Text(l10n.roleManager),
                        ),
                        CheckedPopupMenuItem(
                          value: 'member',
                          checked: !membership.isManager,
                          child: Text(l10n.roleMember),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.person_remove_outlined),
                      tooltip: l10n.delete,
                      onPressed: () => _remove(membership),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  /// Label for a roster row.
  ///
  /// The endpoint resolves display names, so this only has to pick the best of
  /// what it was given: a name, else the email that identifies the row. Both are
  /// empty for the residue of a deleted account, which gets a neutral label
  /// rather than a blank tile.
  String _label(AppLocalizations l10n, Membership membership) {
    final name = membership.name.trim();
    final email = membership.email.trim();
    final base = name.isNotEmpty
        ? name
        : (email.isNotEmpty ? email : l10n.userFallback);
    return membership.isSelf ? '$base (${l10n.rosterYou})' : base;
  }

  /// [errorText] funnels every failure without server prose into one generic
  /// bucket; sending an invitation is not loading data, so that bucket gets the
  /// action's own wording.
  String _inviteErrorText(AppLocalizations l10n, Object error) {
    final text = errorText(l10n, error);
    return text == l10n.couldNotLoadData ? l10n.couldNotInvite : text;
  }
}

/// Recomputes the user's assignments after a write to an entity or to its
/// membership rows.
///
/// "My entities" and the pending-invitation list on the dashboard are derived
/// from those rows plus the entity caches, so a write made on this screen is
/// invisible there until something refreshes them; creating a record even
/// depends on it, because the creator's membership row is inserted server-side
/// after the create.
///
/// Best-effort by design: the write already succeeded, so a failed re-read must
/// never be reported as a failed write. `force` is on purpose — a plain refresh
/// would join the completed non-forced pass and change nothing.
Future<void> _refreshAssignments(BuildContext context) async {
  try {
    await context.read<AssignmentsController>().refresh(force: true);
  } catch (_) {
    // See above.
  }
}

/// Blank form values become null so clearing a field clears it on the server
/// too, instead of writing an empty string the list would then show as a name.
String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
