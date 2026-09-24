import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/event.dart';
import '../models/identified.dart';
import '../models/membership.dart';
import '../models/performer.dart';
import '../models/venue.dart';
import '../services/pocketbase_service.dart';
import 'session_store.dart';

/// Lazily resolved [SharedPreferences] handle.
///
/// Resolving on first use is not a micro-optimisation: constructing a
/// repository must not touch the platform channel, because that throws outside
/// a widget-test binding — and a repository whose records are never persisted
/// (or restored in a test) has no reason to reach for platform storage at all.
class _PrefsHandle {
  _PrefsHandle([this._injected]);

  final Future<SharedPreferences>? _injected;
  Future<SharedPreferences>? _resolved;

  Future<SharedPreferences> get instance =>
      _resolved ??= _injected ?? SharedPreferences.getInstance();
}

/// A collection cached in memory and mirrored to [SharedPreferences].
///
/// Implemented as a mixin so that both [EntityRepository] and
/// [MembershipRepository] can extend [ChangeNotifier] directly, while the parts
/// that are easy to get subtly wrong — join-or-restart load passes, the
/// last-good-value fallback when the server is unreachable, corrupt-cache
/// detection and the id index — live in exactly one place.
mixin _CachedRecords<T extends Identified> on ChangeNotifier {
  /// Server access, used by [fetch].
  PocketBaseService get service;

  /// [SharedPreferences] key this collection is mirrored under.
  String get cacheKey;

  late final _PrefsHandle _prefs = _PrefsHandle();

  final List<T> _items = [];
  final Map<String, T> _index = {};

  bool _loading = false;
  bool _loaded = false;
  bool _stale = false;
  bool _cacheCorrupt = false;

  /// Bumped by [reset]; a pass that finishes afterwards must not refill a cache
  /// the caller has already thrown away (sign-out).
  int _generation = 0;

  Future<void>? _pass;
  bool _passForced = false;

  /// Identity of the pass whose result may still be applied.
  ///
  /// A pass that has been superseded (a forced load arrived while it ran) still
  /// has an awaiting caller, so it must run to completion — but it must not
  /// write its older payload over the records the newer pass just fetched.
  Object? _currentPass;

  /// Fetches the whole collection from the server.
  Future<List<T>> fetch();

  /// Serialises one record for the offline mirror.
  ///
  /// Display names are deliberately left out of the persisted shape (see
  /// [Event.toJson]): a name resolved from `expand` is a snapshot of a venue at
  /// fetch time, and restoring it days later would show a renamed venue under
  /// its old name with nothing signalling the staleness. The canonical fields
  /// are enough — screens resolve names through the venue/performer caches,
  /// which are themselves refreshed.
  Map<String, dynamic> toCacheJson(T item);

  /// Inverse of [toCacheJson].
  T fromCacheJson(Map<String, dynamic> json);

  /// Unmodifiable snapshot of the records, in server order.
  List<T> get items => List.unmodifiable(_items);

  bool get loading => _loading;

  /// True once records are available, from the server or from the mirror.
  bool get loaded => _loaded;

  /// True when the last pass could not reach the server and [items] are the
  /// previous or persisted values.
  bool get stale => _stale;

  /// True when the persisted mirror could not be decoded and was dropped.
  bool get cacheCorrupt => _cacheCorrupt;

  /// O(1) lookup, backed by an index rebuilt with the records.
  T? byId(String id) => _index[id];

  /// Loads the collection.
  ///
  /// [force] refetches even when records are already loaded — pull-to-refresh
  /// and realtime invalidation both depend on it actually reaching the server.
  Future<void> load({bool force = false}) {
    final running = _pass;
    // Join an in-flight pass — unless this call is forced and the pass it would
    // join is not. Joining there would silently drop `force` and turn
    // pull-to-refresh into a no-op whenever a load happened to be in flight.
    if (running != null && (!force || _passForced)) return running;
    if (!force && _loaded) return Future<void>.value();

    final generation = _generation;
    final token = Object();
    _currentPass = token;
    late final Future<void> pass;
    // `identical` guard: this pass may already have been replaced by a newer
    // one (a forced load arriving while it was still running). Only the pass
    // that is still current may clear the slot — an overwritten pass clearing
    // it would drop the newer pass's future and let the next caller start
    // yet another fetch.
    pass = _load(generation, token).whenComplete(() {
      if (identical(_pass, pass)) {
        _pass = null;
        _passForced = false;
      }
    });
    _pass = pass;
    _passForced = force;
    return pass;
  }

  /// Whether the pass identified by [token] may still publish its result.
  bool _isCurrent(Object token, int generation) =>
      generation == _generation && identical(_currentPass, token);

  /// Drops everything held in memory. The persisted mirror is kept: it is the
  /// offline fallback and the next successful load replaces it wholesale.
  void reset() {
    _generation++;
    _pass = null;
    _passForced = false;
    _currentPass = null;
    _items.clear();
    _index.clear();
    _loading = false;
    _loaded = false;
    _stale = false;
    _cacheCorrupt = false;
    notifyListeners();
  }

  Future<void> _load(int generation, Object token) async {
    _loading = true;
    // The "started loading" notification is sent one microtask later rather than
    // synchronously. [load] is called from `initState` by the screens that own
    // their data (the dashboard and the tabbed calendar both force a pass there),
    // and `initState` runs *during a build*: notifying a listener that is an
    // ancestor of the widget being built trips the framework's "setState() called
    // during build" assertion. Observers lose nothing — `loading` is already true
    // when this returns, and no frame can be built before the microtask runs.
    await Future<void>.value();
    notifyListeners();

    Object? failure;
    StackTrace? failureStack;
    try {
      final fetched = await fetch();
      if (_isCurrent(token, generation)) {
        _replaceAll(fetched);
        _loaded = true;
        _stale = false;
        unawaited(_persist());
      }
      return;
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      // Only the current pass owns the loading flag; a superseded one clearing
      // it would hide the fetch that is still running.
      if (_isCurrent(token, generation)) {
        _loading = false;
        notifyListeners();
      }
    }

    if (!_isCurrent(token, generation)) return;

    // The server is unreachable. Serve the last known values — the in-memory
    // ones if an earlier pass succeeded, otherwise the persisted mirror — and
    // flag them stale so screens can say they are offline, instead of showing
    // an error over data they could still display.
    if (_items.isEmpty) await _hydrate(generation, token);
    if (!_isCurrent(token, generation)) return;
    if (_items.isEmpty && !_loaded) {
      Error.throwWithStackTrace(failure, failureStack);
    }
    _stale = true;
    notifyListeners();
  }

  void _replaceAll(List<T> records) {
    _items
      ..clear()
      ..addAll(records);
    _index.clear();
    for (final record in records) {
      final id = record.id;
      if (id != null && id.isNotEmpty) _index[id] = record;
    }
  }

  Future<void> _persist() async {
    try {
      // Encoded synchronously, before the first await: the payload has to be
      // the records this pass produced, not whatever a later pass has replaced
      // them with by the time preferences answer.
      final payload = jsonEncode([
        for (final record in _items) toCacheJson(record),
      ]);
      final prefs = await _prefs.instance;
      await prefs.setString(cacheKey, payload);
    } catch (_) {
      // Persistence is best-effort; a failed mirror must never fail a load.
      // It also covers environments without platform storage (widget tests),
      // where resolving preferences itself throws.
    }
  }

  Future<void> _hydrate(int generation, Object token) async {
    try {
      final prefs = await _prefs.instance;
      final raw = prefs.getString(cacheKey);
      if (raw == null) return;
      final List<T> restored;
      try {
        final decoded = jsonDecode(raw);
        restored = [
          for (final entry in decoded as List<dynamic>)
            fromCacheJson(Map<String, dynamic>.from(entry as Map)),
        ];
      } catch (_) {
        // Corrupt mirror (an older schema, a truncated write). Drop it and
        // raise the flag the offline banner reads, rather than failing
        // silently and leaving the user with an empty screen and no reason.
        _cacheCorrupt = true;
        await prefs.remove(cacheKey);
        notifyListeners();
        return;
      }
      if (!_isCurrent(token, generation)) return;
      _replaceAll(restored);
      _loaded = true;
    } catch (_) {
      // Preferences unavailable in this environment: nothing to restore.
    }
  }
}

/// Base class for the venue/performer caches.
///
/// Records are fetched once and shared by every screen, then mirrored per
/// collection so an offline relaunch still shows the last known entities.
abstract class EntityRepository<T extends NamedEntity> extends ChangeNotifier
    with _CachedRecords<T> {
  EntityRepository(this.service, {required this.cacheKey});

  @override
  final PocketBaseService service;

  @override
  final String cacheKey;

  @override
  T fromCacheJson(Map<String, dynamic> json) => decode(json);

  /// Inverse of [toCacheJson] for this repository's record type.
  ///
  /// [NamedEntity] only promises an id and a name, so the two serialisation
  /// halves have to be supplied by the concrete repository (`Venue.toJson` /
  /// `Venue.fromJson`), which is also what keeps the wire and cache shapes
  /// separate.
  @protected
  T decode(Map<String, dynamic> json);

  /// Case-insensitive substring match on [NamedEntity.displayName].
  ///
  /// Answered from the loaded records rather than a request per keystroke: the
  /// repository pages through the whole collection, so the local copy already
  /// is the complete set the user may see. A cold cache still has to fetch
  /// first, otherwise the picker would report "no matches" for every query.
  Future<List<T>> search(String query, {int limit = 50}) async {
    if (_items.isEmpty && !loaded) {
      try {
        await load();
      } catch (_) {
        // Offline: search whatever was restored from the mirror.
      }
    }
    final needle = query.trim().toLowerCase();
    final matches = <T>[];
    for (final item in _items) {
      if (needle.isEmpty || item.displayName.toLowerCase().contains(needle)) {
        matches.add(item);
        if (matches.length >= limit) break;
      }
    }
    return matches;
  }
}

/// Cached performer records shared across screens.
class PerformerRepository extends EntityRepository<Performer> {
  PerformerRepository({PocketBaseService? service})
    : super(service ?? PocketBaseService.shared, cacheKey: 'performers_cache');

  @override
  Future<List<Performer>> fetch() => service.getPerformers();

  @override
  Map<String, dynamic> toCacheJson(Performer item) => item.toJson();

  @override
  Performer decode(Map<String, dynamic> json) => Performer.fromJson(json);
}

/// Cached venue records shared across screens.
class VenueRepository extends EntityRepository<Venue> {
  VenueRepository({PocketBaseService? service})
    : super(service ?? PocketBaseService.shared, cacheKey: 'venues_cache');

  @override
  Future<List<Venue>> fetch() => service.getVenues();

  @override
  Map<String, dynamic> toCacheJson(Venue item) => item.toJson();

  @override
  Venue decode(Map<String, dynamic> json) => Venue.fromJson(json);
}

/// The memberships visible to the signed-in user, cached and mirrored like the
/// entity collections.
///
/// Membership is its own collection, so it is its own repository: it is the one
/// record type that is neither a venue nor a performer and therefore cannot be
/// an [EntityRepository].
class MembershipRepository extends ChangeNotifier
    with _CachedRecords<Membership> {
  MembershipRepository({PocketBaseService? service})
    : service = service ?? PocketBaseService.shared;

  @override
  final PocketBaseService service;

  @override
  final String cacheKey = 'memberships_cache';

  @override
  Future<List<Membership>> fetch() => service.getMemberships();

  @override
  Map<String, dynamic> toCacheJson(Membership item) => item.toJson();

  @override
  Membership fromCacheJson(Map<String, dynamic> json) =>
      Membership.fromJson(json);

  /// Invites [email] to manage [targetId].
  ///
  /// The row is created **pending**: when the address already has an account
  /// the server resolves `userId` but still does not grant access — the invitee
  /// has to accept it from their dashboard. Nothing is written to this
  /// repository's own list, because the new row is addressed to the invitee,
  /// not to the manager who created it.
  Future<void> invite({
    required String targetId,
    required TargetType targetType,
    required String email,
    String role = 'manager',
  }) async {
    await service.createMembership(
      targetId: targetId,
      targetType: targetType,
      email: email,
      role: role,
    );
    await _reload();
  }

  /// The roster of [targetType]/[targetId], read straight from the endpoint.
  ///
  /// Deliberately uncached, for two reasons: the cache holds *my* rows under a
  /// self-only rule and a roster is per-target, so a cached one would be
  /// whatever target was opened last; and a stale roster is worse than none —
  /// it would show a member who has already been removed.
  ///
  /// Rethrows (unlike [load], which serves the mirror): a 403 means "you may
  /// not read this roster" and the screen has to say so, not render an empty
  /// team as though the entity had no members.
  Future<List<Membership>> roster({
    required TargetType targetType,
    required String targetId,
  }) => service.getRoster(targetType: targetType, targetId: targetId);

  /// The join requests awaiting this user's decision, read straight from the
  /// endpoint.
  ///
  /// Deliberately uncached, like [roster] and for the same reason: this
  /// repository's own list is self-only, so it cannot hold another user's
  /// request row at all, and a cached copy would keep showing a request the
  /// user has already approved. Rethrows as well — the caller decides whether a
  /// failed read is worth reporting, and here it is a badge rather than a
  /// screen, so `AssignmentsController` swallows it.
  Future<List<Membership>> incomingRequests() => service.getIncomingRequests();

  /// Accepts or declines the invitation [membershipId]; the server deletes a
  /// declined row. Reloads so an accepted invite becomes a real assignment.
  Future<void> respond({
    required String membershipId,
    required bool accept,
  }) async {
    await service.respondToInvite(membershipId: membershipId, accept: accept);
    await _reload();
  }

  /// Asks to join [targetType]/[targetId] and reloads.
  ///
  /// The row this creates is addressed to the *caller*, so unlike [invite] it
  /// does land in this repository's own list — as a pending request that grants
  /// nothing. The reload is what makes it show up, which is the only way a
  /// browse screen can offer "waiting for approval" instead of a button that
  /// the duplicate check would reject.
  Future<void> requestToJoin({
    required TargetType targetType,
    required String targetId,
    String role = 'member',
  }) async {
    await service.requestToJoin(
      targetType: targetType,
      targetId: targetId,
      role: role,
    );
    await _reload();
  }

  /// Approves or rejects the request/invitation [membershipId], then reloads.
  ///
  /// A manager calling this decides somebody else's row, so nothing about the
  /// change lands in the caller's own list on its own — the reload re-reads
  /// whatever the server now shows (the caller may also be the requester
  /// withdrawing their own request, which does).
  Future<void> decide({
    required String membershipId,
    required bool approve,
  }) async {
    await service.decideRequest(membershipId: membershipId, approve: approve);
    await _reload();
  }

  /// Promotes or demotes [membershipId]. The server rejects a change that would
  /// leave the target with no active manager.
  Future<void> setRole({
    required String membershipId,
    required String role,
  }) async {
    await service.updateMembership(membershipId, role: role);
    await _reload();
  }

  Future<void> remove(String id) async {
    await service.deleteMembership(id);
    await _reload();
  }

  /// Refreshes after a write.
  ///
  /// The write already succeeded, so a failed follow-up read must not be
  /// reported as a failed invite: the repository keeps the previous list, marks
  /// it [stale] and the next refresh repairs it.
  Future<void> _reload() async {
    try {
      await load(force: true);
    } catch (_) {
      // Handled by the stale flag set inside the load.
    }
  }
}

/// A month's in-flight load, together with whether it was forced.
///
/// [forced] is what makes a forced call able to start its own pass instead of
/// joining a non-forced one.
class _MonthPass {
  const _MonthPass({required this.future, required this.forced});

  final Future<List<Event>> future;
  final bool forced;
}

/// Month-scoped event cache.
///
/// Events are fetched per displayed month, which is what the calendar and the
/// day sheet both need. Successful loads are mirrored per month; when a fetch
/// fails the last good month is served and [isMonthStale] flips so screens can
/// warn the user they are looking at cached data.
class EventRepository extends ChangeNotifier {
  EventRepository({
    PocketBaseService? service,
    Future<SharedPreferences>? prefs,
  }) : _service = service ?? PocketBaseService.shared,
       _prefs = _PrefsHandle(prefs);

  /// How many months are kept in memory. Each key is also a server round-trip
  /// on every mutation, so the bound keeps a long browsing session from turning
  /// one save into dozens of requests.
  static const int _monthCacheCapacity = 24;

  final PocketBaseService _service;
  final _PrefsHandle _prefs;

  /// `YYYY-MM` → that month's events, in least-recently-used order.
  final Map<String, List<Event>> _monthCache = {};

  /// `YYYY-MM` keys the user has actually looked at.
  ///
  /// A *set*, not "the last month loaded": the tabbed calendar holds several
  /// months open at once and a day sheet can show a neighbouring one, and a
  /// mutation must leave *every* one of them consistent — reloading only the
  /// most recent would silently leave the other tabs showing a deleted event.
  final Set<String> _loadedMonths = {};

  final Set<String> _staleMonths = {};
  final Map<String, _MonthPass> _passes = {};

  /// `YYYY-MM` → identity of the pass currently allowed to publish that month.
  /// Separate from [_passes] because it has to exist before the pass's future
  /// does.
  final Map<String, Object> _passTokens = {};

  bool _cacheCorrupt = false;
  int _generation = 0;

  // ---- the upcoming list -------------------------------------------------
  //
  // Not month-keyed like the calendar cache: "what is next" is a question about
  // the whole collection, and a booking five months out is still the next thing
  // that happens. The server answers it in one sorted query, so this holds a
  // single result rather than a horizon of months.

  /// The last upcoming query's result, or null when it has never loaded.
  List<Event>? _upcoming;

  /// True when the last upcoming query fell back to [_upcoming] because the
  /// server was unreachable.
  bool _upcomingStale = false;

  Future<List<Event>>? _upcomingPass;
  bool _upcomingForced = false;
  Object? _upcomingToken;
  DateTime? _upcomingFrom;

  /// How many upcoming events one query asks for. Well past what a list screen
  /// shows at once, and small enough to stay one round-trip.
  static const int upcomingLimit = 50;

  /// `YYYY-MM` keys currently held in memory, for diagnostics and tests.
  Set<String> get loadedMonths => Set.unmodifiable(_loadedMonths);

  /// The last upcoming events, or null when the view has never loaded them.
  ///
  /// The returned list is this repository's own storage: treat it as read-only.
  List<Event>? get upcomingEvents => _upcoming;

  /// True when the last upcoming query could not reach the server and
  /// [upcomingEvents] are the previous answer.
  bool get upcomingStale => _upcomingStale;

  /// True when the mirrored month cache could not be decoded and was dropped.
  bool get cacheCorrupt => _cacheCorrupt;

  /// True when [month]'s most recent load fell back to cached data.
  /// Per-month so one stale month does not banner every tab.
  bool isMonthStale(DateTime month) => _staleMonths.contains(_monthKey(month));

  /// The cached events for [month], or null when the month is not in memory.
  ///
  /// The returned list is the cache's own storage: treat it as read-only.
  /// Reading counts as a use, so the least-recently-used month is the one that
  /// gets evicted.
  List<Event>? cachedMonth(DateTime month) {
    final key = _monthKey(month);
    final cached = _monthCache[key];
    if (cached != null) _touch(key);
    return cached;
  }

  /// Loads [month]'s events, sharing an in-flight fetch for the same month.
  ///
  /// [force] starts a new pass rather than joining a non-forced one, so a
  /// refresh button is never swallowed by a load that happened to be running.
  Future<List<Event>> loadForMonth(DateTime month, {bool force = false}) {
    final key = _monthKey(month);
    final running = _passes[key];
    if (running != null && (!force || running.forced)) return running.future;

    _touch(key);
    final generation = _generation;
    // Identity of the pass allowed to publish a result for this month: a
    // non-forced pass that a forced one has replaced still has an awaiting
    // caller, but its older snapshot must not overwrite the newer one.
    //
    // Registered *before* the load starts and keyed by month, because the
    // `_MonthPass` cannot be stored until its future exists — checking against
    // `_passes[key]` would compare against a not-yet-assigned (or already
    // replaced) entry and silently skip every cache write.
    final token = Object();
    _passTokens[key] = token;
    late final _MonthPass pass;
    pass = _MonthPass(
      forced: force,
      future: _loadMonth(key, month, generation, token).whenComplete(() {
        // Same `identical` guard as [_CachedRecords.load]: an overwritten pass
        // must not remove the newer pass's entry from the map.
        if (identical(_passTokens[key], token)) {
          _passes.remove(key);
          _passTokens.remove(key);
        }
      }),
    );
    _passes[key] = pass;
    return pass.future;
  }

  /// Whether the pass identified by [token] may still publish [key]'s events.
  bool _isCurrentMonth(String key, Object token, int generation) =>
      generation == _generation && identical(_passTokens[key], token);

  /// Reloads every month the user has loaded.
  ///
  /// Mutations call this so a create/update/delete is reflected in all open
  /// months, not just the newest one.
  Future<void> refreshLoaded({bool force = true}) async {
    for (final key in _loadedMonths.toList()..sort()) {
      final month = _monthFromKey(key);
      if (month == null) continue;
      try {
        await loadForMonth(month, force: force);
      } catch (_) {
        // One unreachable month must not abort the refresh of the others; that
        // month keeps its previous events with `stale` set.
      }
    }
    // The same mutation that changes a month changes what is next — a deleted
    // booking must leave the upcoming list, and a created one must appear. Only
    // once the view has asked for it: a query nobody is showing would be a
    // request per mutation for no reason.
    final from = _upcomingFrom;
    if (_upcoming != null && from != null) {
      try {
        await upcoming(from: from, force: force);
      } catch (_) {
        // Reported by [upcomingStale], exactly as a month reports its own.
      }
    }
  }

  /// Creates one event and refreshes the loaded months. Returns its id.
  Future<String> create(Event event) async {
    final created = await _service.createEvent(event);
    await refreshLoaded();
    return created.id ?? '';
  }

  /// Creates every instance of a recurrence, one after the other.
  ///
  /// Sequential on purpose: each instance goes through the server's
  /// double-booking guard, and one rejected occurrence (a venue already booked
  /// in that slot) must not abort the rest of the series. Returns the
  /// human-readable reason for each rejected instance; never throws for a
  /// per-instance rejection.
  Future<List<String>> createSeries(List<Event> events) async {
    final failures = <String>[];
    var created = 0;
    for (final event in events) {
      try {
        await _service.createEvent(event);
        created++;
      } catch (error) {
        // Prefix the start instant: the same guard message repeated for five
        // occurrences is useless without knowing which five.
        failures.add('${_stamp(event.start)} — ${_message(error)}');
      }
    }
    if (created > 0) await refreshLoaded();
    return failures;
  }

  /// Loads the events that have not finished by [from] (default: now).
  ///
  /// Deduplicates an in-flight query the same way [loadForMonth] deduplicates a
  /// month: a screen mounting while another has already asked would otherwise
  /// issue its own request and could read an empty list from the wrong moment.
  /// A failure keeps the previous answer and flips [upcomingStale] rather than
  /// throwing, so an offline user sees their schedule with a warning instead of
  /// an error — matching what the calendar already does per month.
  Future<List<Event>> upcoming({
    DateTime? from,
    int limit = upcomingLimit,
    bool force = false,
  }) {
    final running = _upcomingPass;
    if (running != null && (!force || _upcomingForced)) return running;

    final start = from ?? DateTime.now();
    _upcomingFrom = start;
    final token = Object();
    _upcomingToken = token;
    late final Future<List<Event>> pass;
    pass = _loadUpcoming(start, limit, token).whenComplete(() {
      // Same guard as the month passes: an overwritten pass must not clear the
      // newer pass's slot.
      if (identical(_upcomingToken, token)) _upcomingPass = null;
    });
    _upcomingPass = pass;
    _upcomingForced = force;
    return pass;
  }

  Future<List<Event>> _loadUpcoming(
    DateTime from,
    int limit,
    Object token,
  ) async {
    bool current() => identical(_upcomingToken, token);
    try {
      final items = await _service.getUpcoming(from);
      if (!current()) return items;
      final future = [
        for (final event in items)
          if (event.end.isAfter(from)) event,
      ];
      _upcoming = future.length > limit ? future.sublist(0, limit) : future;
      _upcomingStale = false;
      notifyListeners();
      return _upcoming!;
    } catch (_) {
      if (!current()) rethrow;
      final previous = _upcoming;
      // No previous answer to fall back on: this is a first load that failed,
      // and the screen has to be allowed to say so.
      if (previous == null) rethrow;
      _upcomingStale = true;
      notifyListeners();
      return previous;
    }
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    await _service.updateEvent(id, updates);
    await refreshLoaded();
  }

  Future<void> delete(String id) async {
    await _service.deleteEvent(id);
    await refreshLoaded();
  }

  /// How many instances one recurrence currently has.
  ///
  /// Asked of the server rather than recomputed from the rule: the stored
  /// instances are what the series actually created, and a locally recomputed
  /// count could promise more than exist (a rule whose occurrences the server
  /// refused) or fewer.
  Future<int> seriesInstanceCount(String seriesId) async {
    final instances = await _service.getSeries(seriesId);
    return instances.length;
  }

  /// Deletes every occurrence of one recurrence, returning how many went.
  ///
  /// Resolved through `seriesId` rather than by recomputing the recurrence: the
  /// stored instances are the truth about what a series actually created, and
  /// recomputing could miss one the server refused at the time or delete one the
  /// user had since edited onto a different date.
  Future<int> deleteSeries(String seriesId) async {
    final instances = await _service.getSeries(seriesId);
    var deleted = 0;
    for (final instance in instances) {
      final id = instance.id;
      if (id == null || id.isEmpty) continue;
      await _service.deleteEvent(id);
      deleted++;
    }
    if (deleted > 0) await refreshLoaded();
    return deleted;
  }

  /// Drops the in-memory month cache, e.g. on sign-out.
  void reset() {
    _generation++;
    _monthCache.clear();
    _loadedMonths.clear();
    _staleMonths.clear();
    _passes.clear();
    _passTokens.clear();
    _cacheCorrupt = false;
    // Per-session state like the rest: the next account must not inherit the
    // previous one's schedule, which is exactly what a stale list would show.
    _upcoming = null;
    _upcomingStale = false;
    _upcomingPass = null;
    _upcomingForced = false;
    _upcomingToken = null;
    _upcomingFrom = null;
    notifyListeners();
  }

  Future<List<Event>> _loadMonth(
    String key,
    DateTime month,
    int generation,
    Object token,
  ) async {
    // Half-open range so an event that starts exactly at midnight on the first
    // of the next month belongs to that month and not to both.
    final start = DateTime(
      month.year,
      month.month,
      1,
    ).toUtc().toIso8601String();
    final end = DateTime(
      month.year,
      month.month + 1,
      1,
    ).toUtc().toIso8601String();
    try {
      final items = await _service.getEvents(
        filter: 'start < "$end" && end > "$start"',
      );
      if (_isCurrentMonth(key, token, generation)) {
        _store(key, items);
        _loadedMonths.add(key);
        _staleMonths.remove(key);
        unawaited(_persistMonth(key, items));
        notifyListeners();
      }
      return items;
    } catch (_) {
      if (!_isCurrentMonth(key, token, generation)) rethrow;
      final cached = _monthCache[key] ?? await _readPersistedMonth(key);
      if (!_isCurrentMonth(key, token, generation)) rethrow;
      if (cached == null) rethrow;
      _store(key, cached);
      _loadedMonths.add(key);
      _staleMonths.add(key);
      notifyListeners();
      return cached;
    }
  }

  /// Inserts [events] and refreshes the LRU order.
  void _store(String key, List<Event> events) {
    _touch(key);
    _monthCache[key] = events;
    while (_monthCache.length > _monthCacheCapacity) {
      final coldest = _monthCache.keys.first;
      _monthCache.remove(coldest);
      // Anything evicted from memory leaves the loaded set with it: keeping the
      // key would make every future mutation reload a month nobody holds (and
      // whose absence is already covered by its persisted mirror).
      _loadedMonths.remove(coldest);
      _staleMonths.remove(coldest);
    }
  }

  void _touch(String key) {
    final existing = _monthCache.remove(key);
    if (existing != null) _monthCache[key] = existing;
  }

  Future<void> _persistMonth(String key, List<Event> events) async {
    try {
      // Encoded synchronously, before the first await, so the payload is the
      // list this pass fetched rather than a later pass's replacement.
      final payload = jsonEncode([for (final event in events) event.toJson()]);
      final prefs = await _prefs.instance;
      await prefs.setString('events_cache_$key', payload);
    } catch (_) {
      // Best-effort mirror.
    }
  }

  Future<List<Event>?> _readPersistedMonth(String key) async {
    try {
      final prefs = await _prefs.instance;
      final raw = prefs.getString('events_cache_$key');
      if (raw == null) return null;
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        return [
          for (final entry in decoded)
            Event.fromJson(Map<String, dynamic>.from(entry as Map)),
        ];
      } catch (_) {
        // Corrupt mirror: drop it and say so, instead of failing silently and
        // leaving the offline banner explaining nothing.
        _cacheCorrupt = true;
        await prefs.remove('events_cache_$key');
        notifyListeners();
        return null;
      }
    } catch (_) {
      return null;
    }
  }

  static String _monthKey(DateTime month) =>
      '${month.year}-${month.month.toString().padLeft(2, '0')}';

  static DateTime? _monthFromKey(String key) {
    final parsed = DateTime.tryParse('$key-01');
    return parsed == null ? null : DateTime(parsed.year, parsed.month);
  }

  /// Locale-independent `YYYY-MM-DD HH:MM` stamp for a series failure line.
  ///
  /// Deliberately not localized: the data layer has no `BuildContext`, and the
  /// screen shows these strings verbatim next to the server's own prose.
  static String _stamp(DateTime instant) {
    final local = instant.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _message(Object error) {
    if (error is PocketBaseException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    return error.toString();
  }
}

/// Whether the signed-in user is signed in, and who they are.
///
/// Deliberately owns no repositories: it is the session, not a data cache, and
/// the shared caches have to outlive a sign-out/sign-in cycle.
///
/// Persistence goes through a [SessionStore], which is injectable because the
/// keystore those credentials belong in is a platform channel — passing an
/// in-memory store is what lets the widget tests exercise a sign-in without one.
class SessionController extends ChangeNotifier {
  SessionController({
    PocketBaseService? service,
    Future<SharedPreferences>? prefs,
    SessionStore? store,
  }) : _service = service ?? PocketBaseService.shared,
       _store = store ?? SecureSessionStore(prefs: prefs);

  final PocketBaseService _service;
  final SessionStore _store;

  Map<String, dynamic>? _user;

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null;
  String? get userId => _user?['id']?.toString();

  /// Signs in and returns the user record, or null when the credentials were
  /// rejected.
  ///
  /// The distinction that matters to the sign-in screen is "wrong password"
  /// versus "backend unreachable": the first is an ordinary answer and returns
  /// null, the second is thrown so the screen can show the localized
  /// "backend unreachable" message instead of blaming the password.
  Future<Map<String, dynamic>?> login(String email, String password) async {
    final Map<String, dynamic> record;
    try {
      record = await _service.login(email, password);
    } on PocketBaseException catch (error) {
      // PocketBase answers a bad password with 400 (not 401), so the whole
      // 4xx range is a rejected sign-in attempt; only transport failures and
      // server errors mean "unreachable".
      if (error.statusCode >= 400 && error.statusCode < 500) return null;
      rethrow;
    }
    _user = record;
    await _persistSession();
    notifyListeners();
    return record;
  }

  /// Creates an account and adopts the resulting session.
  ///
  /// Lets [PocketBaseException] escape so the signup screen can show
  /// PocketBase's own rejection wording (e.g. an already-registered email).
  Future<void> register({
    required String email,
    required String password,
    required String passwordConfirm,
    String? name,
  }) async {
    _user = await _service.signUp(
      email: email,
      password: password,
      passwordConfirm: passwordConfirm,
      name: name,
    );
    await _persistSession();
    notifyListeners();
  }

  /// Signs in as a throwaway demo guest, generating the account's credentials.
  ///
  /// See [PocketBaseService.signInAsGuest]: this is an ordinary account with a
  /// generated address and password, so everything downstream — persistence,
  /// the assignments refresh, sign-out — treats it like any other session. That
  /// is deliberate; the alternative (a synthetic session with no server record)
  /// would need its own branch in every one of those paths and would break the
  /// moment the guest tried to create anything.
  ///
  /// Lets [PocketBaseException] escape: the sign-in screen shows the server's
  /// own wording, because "why can I not get in" is the question the user is
  /// asking.
  Future<void> loginAsGuest({String? name}) async {
    _user = await _service.signInAsGuest(name: name);
    await _persistSession();
    notifyListeners();
  }

  /// Restores a persisted session (user + auth token/cookie).
  ///
  /// No network round-trip: the app has to open logged-in even when the backend
  /// is unreachable, and an expired token surfaces as a 401 on the first real
  /// request rather than as a sign-in screen the user cannot get past offline.
  Future<void> restoreSession() async {
    try {
      final stored = await _store.read();
      if (stored == null) return;
      _user = stored.user;
      _service.restoreAuth(stored.token, stored.cookie);
    } catch (_) {
      // Corrupt or unreadable session: treat as signed out. This has to hold
      // for a store that throws as well as for a value it cannot decode — an
      // unopenable keystore signs the user out, it does not stop the launch.
      _user = null;
    }
    notifyListeners();
  }

  /// Drops the in-memory session and the persisted credentials.
  void logout() {
    _user = null;
    _service.restoreAuth(null, null);
    unawaited(_clearSession());
    notifyListeners();
  }

  Future<void> _persistSession() async {
    final user = _user;
    if (user == null) return;
    try {
      await _store.write(
        StoredSession(
          user: user,
          token: _service.authToken,
          cookie: _service.authCookie,
        ),
      );
    } catch (_) {
      // Best-effort: a failed save must not fail a sign-in.
    }
  }

  Future<void> _clearSession() async {
    try {
      await _store.clear();
    } catch (_) {
      // Best-effort: the in-memory session is already gone, and that is what
      // the rest of the app reads.
    }
  }
}

/// Which venues and performers the signed-in user may act on.
///
/// Derived state, never stored twice: it recomputes from the session and the
/// three shared caches whenever any of them changes, so a screen that watches
/// this controller cannot hold an answer that predates a membership edit.
class AssignmentsController extends ChangeNotifier {
  AssignmentsController({
    required SessionController session,
    required PerformerRepository performers,
    required VenueRepository venues,
    required MembershipRepository memberships,
  }) {
    // See RealtimeSync: the parameter names are the wiring contract, so the
    // collaborators are copied into private fields in the body instead of
    // through private initializing formals.
    _session = session;
    _performers = performers;
    _venues = venues;
    _memberships = memberships;
    // Not `_recompute` directly: a dependency changing has to repaint this
    // controller's own watchers, not just refresh its fields behind them.
    _session.addListener(_onDependencyChanged);
    _performers.addListener(_onDependencyChanged);
    _venues.addListener(_onDependencyChanged);
    _memberships.addListener(_onDependencyChanged);
    _recompute();
  }

  late final SessionController _session;
  late final PerformerRepository _performers;
  late final VenueRepository _venues;
  late final MembershipRepository _memberships;

  List<Performer> _myPerformers = const [];
  List<Venue> _myVenues = const [];
  List<Membership> _myMemberships = const [];
  List<Membership> _pendingInvites = const [];
  List<Membership> _incomingRequests = const [];
  List<Membership> _myRequests = const [];
  Set<String> _myPerformerIds = const {};
  Set<String> _myVenueIds = const {};

  List<Performer> get myPerformers => List.unmodifiable(_myPerformers);
  List<Venue> get myVenues => List.unmodifiable(_myVenues);
  List<Membership> get myMemberships => List.unmodifiable(_myMemberships);

  /// Pending rows whose target this user **actively manages** and whose origin
  /// is a join request — the dashboard's "access requests" section.
  ///
  /// This is what the user must *decide*: somebody else asked to join, and only
  /// an active manager of that target can approve or reject them. It is the
  /// manager-side counterpart of [pendingInvites], and the two never overlap:
  /// each row appears in exactly one of the three pending lists, because the
  /// actor who can resolve it is different in each.
  ///
  /// Filled by [refresh] from its own endpoint rather than derived from the
  /// memberships collection: those rows belong to other users, and the
  /// collection's self-only rule can never return them. The list is therefore
  /// empty until a refresh succeeds — see [refresh] for why a failed read
  /// clears it instead of keeping the previous one.
  List<Membership> get incomingRequests => List.unmodifiable(_incomingRequests);

  /// This user's own outstanding join requests: the ones *they* are waiting on.
  ///
  /// The third list, and the one a browse screen needs — it is how "you already
  /// asked to join this" becomes visible state instead of a button that the
  /// server's duplicate check would only reject. Waiting is not waiting *on*
  /// the user, so this list carries no affordance: it is the reason
  /// [incomingRequests] and [pendingInvites] cannot answer the question.
  List<Membership> get myRequests => List.unmodifiable(_myRequests);

  /// Invitations addressed to this user that are still unanswered — the ones
  /// **they** must accept or decline.
  ///
  /// Deliberately invitations only: a join request of their own is pending too,
  /// but the person who acts on it is a manager, not them, so it belongs in
  /// [myRequests].
  List<Membership> get pendingInvites => List.unmodifiable(_pendingInvites);

  bool isMyPerformer(String id) => _myPerformerIds.contains(id);
  bool isMyVenue(String id) => _myVenueIds.contains(id);

  /// Reloads memberships and both entity caches, then recomputes.
  ///
  /// Rethrows: the caller (sign-in, pull-to-refresh) knows whether the user is
  /// waiting on it and how to show a failure; swallowing here would leave the
  /// screen silently showing "no assignments".
  Future<void> refresh({bool force = false}) async {
    if (!_session.isLoggedIn) {
      // No session means no assignments; fetching would only produce a 401 the
      // sign-in screen cannot act on.
      _recompute();
      notifyListeners();
      return;
    }
    try {
      await Future.wait([
        _memberships.load(force: force),
        _performers.load(force: force),
        _venues.load(force: force),
      ]);
      // Best-effort, and deliberately inside its own try: the badge is a
      // courtesy on top of the assignments, so a failure here must not fail the
      // refresh — the dashboard would then report an error over an account
      // whose calendar is perfectly fine. It clears rather than keeping the
      // previous list, because a "somebody asked to join" badge that outlives
      // its row is worse than no badge: the user would act on a request that is
      // already gone.
      try {
        _incomingRequests = await _memberships.incomingRequests();
      } catch (_) {
        _incomingRequests = const [];
      }
    } finally {
      // Even when one of the loads failed, the ones that succeeded (or were
      // restored from the mirror) still describe this user.
      _recompute();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onDependencyChanged);
    _performers.removeListener(_onDependencyChanged);
    _venues.removeListener(_onDependencyChanged);
    _memberships.removeListener(_onDependencyChanged);
    super.dispose();
  }

  /// Recomputes and notifies: the dependencies' own notifications are consumed
  /// here, and this controller has to pass the change on to its watchers.
  void _onDependencyChanged() {
    _recompute();
    notifyListeners();
  }

  void _recompute() {
    final userId = _session.userId ?? '';
    final email = (_session.user?['email'] ?? '').toString().toLowerCase();
    final signedIn = userId.isNotEmpty;
    final records = signedIn ? _memberships.items : const <Membership>[];

    // Only *active* memberships are assignments. A pending row is an invitation
    // that has not been accepted yet — putting its target in the calendar here
    // would make consent meaningless: an invite would silently grant the
    // invitee access they never agreed to. That is exactly the bug the pending
    // status exists to fix.
    _myMemberships = signedIn
        ? [
            for (final membership in records)
              if (membership.isActive && membership.userId == userId)
                membership,
          ]
        : const [];

    // Invitations addressed to this user, by resolved id or by email — the two
    // ways a pending row can name its invitee. Deliberately not part of
    // `_myMemberships`: it feeds the dashboard's "pending" section and nothing
    // else.
    //
    // Requests are excluded even though they are pending too: an invitation is
    // answered by its invitee (this user), a request by a manager, so the two
    // cannot share a list without offering the wrong affordance on one of them.
    _pendingInvites = signedIn
        ? [
            for (final membership in records)
              if (membership.isPending &&
                  !membership.initiatedByRequest &&
                  (membership.userId == userId ||
                      (email.isNotEmpty &&
                          (membership.pendingEmail ?? '').toLowerCase() ==
                              email)))
                membership,
          ]
        : const [];

    // Manager-side requests are not in `records` at all: the collection's
    // self-only rule cannot return rows for a target the caller merely manages,
    // so [refresh] fills `_incomingRequests` from its own endpoint. All this
    // has to do is not clobber that, and drop it on sign-out — a badge must not
    // outlive the account it belonged to.
    if (!signedIn) _incomingRequests = const [];

    // Requests *I* am waiting on — mine, and therefore not mine to decide. Kept
    // apart from `_pendingInvites` because the actor differs: there the user
    // accepts, here the user waits (and may withdraw).
    _myRequests = signedIn
        ? [
            for (final membership in records)
              if (membership.isPending &&
                  membership.initiatedByRequest &&
                  (membership.requestedByMe || membership.userId == userId))
                membership,
          ]
        : const [];

    // Both roles grant access: a `member` of a performer and a `manager` of a
    // venue are equally "mine" as far as calendars and event writes go.
    _myPerformerIds = {
      for (final membership in _myMemberships)
        if (membership.targetType == TargetType.performer) membership.targetId,
    };
    _myVenueIds = {
      for (final membership in _myMemberships)
        if (membership.targetType == TargetType.venue) membership.targetId,
    };

    _myPerformers = [
      for (final performer in _performers.items)
        if (performer.id != null && _myPerformerIds.contains(performer.id))
          performer,
    ];
    _myVenues = [
      for (final venue in _venues.items)
        if (venue.id != null && _myVenueIds.contains(venue.id)) venue,
    ];
  }
}
