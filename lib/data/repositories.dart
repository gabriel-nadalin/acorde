import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/event.dart';
import '../services/pocketbase_service.dart';

/// Cached performer records shared across screens.
///
/// Loads once per app session (or on explicit `force`), then serves the same
/// records to every consumer, eliminating duplicate fetches.
class PerformerRepository extends ChangeNotifier {
  PerformerRepository({PocketBaseService? service})
      : _service = service ?? PocketBaseService.shared;

  final PocketBaseService _service;
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _loaded = false;

  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  bool get loading => _loading;
  bool get loaded => _loaded;

  Map<String, dynamic>? byId(String id) {
    for (final p in _items) {
      if (p['id']?.toString() == id) return p;
    }
    return null;
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    notifyListeners();
    try {
      _items = await _service.getPerformers(perPage: 1000);
      _loaded = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}

/// Cached venue records shared across screens.
class VenueRepository extends ChangeNotifier {
  VenueRepository({PocketBaseService? service})
      : _service = service ?? PocketBaseService.shared;

  final PocketBaseService _service;
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  bool _loaded = false;

  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  bool get loading => _loading;
  bool get loaded => _loaded;

  Map<String, dynamic>? byId(String id) {
    for (final v in _items) {
      if (v['id']?.toString() == id) return v;
    }
    return null;
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_loaded && !force) return;
    _loading = true;
    notifyListeners();
    try {
      _items = await _service.getVenues(perPage: 1000);
      _loaded = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}

/// Month-scoped event cache. Mutations reload the cached month so the
/// calendar stays consistent after create/update/delete.
///
/// Successful loads are persisted to [SharedPreferences] per month; when a
/// fetch fails, the last good month is served from the cache and [stale]
/// flips so screens can warn the user they are seeing offline data.
class EventRepository extends ChangeNotifier {
  EventRepository({PocketBaseService? service, Future<SharedPreferences>? prefs})
      : _service = service ?? PocketBaseService.shared,
        _injectedPrefs = prefs;

  final PocketBaseService _service;
  final Future<SharedPreferences>? _injectedPrefs;
  Future<SharedPreferences>? _prefsFuture;

  // Lazy: constructing a repo must not touch the platform channel, which
  // fails outside a widget-test binding (and never for screens that never
  // persist).
  Future<SharedPreferences> get _prefs =>
      _prefsFuture ??= _injectedPrefs ?? SharedPreferences.getInstance();

  List<Event> _events = [];
  DateTime? _loadedMonth;
  final Map<String, List<Event>> _monthCache = {};
  final Set<String> _staleMonths = {};
  final Map<String, Future<List<Event>>> _inFlight = {};

  List<Event> get events => List.unmodifiable(_events);
  DateTime? get loadedMonth => _loadedMonth;

  /// True when [month]'s most recent load fell back to the offline cache.
  /// Per-month so one stale month doesn't banner every tab.
  bool isMonthStale(DateTime month) => _staleMonths.contains(_monthKey(month));

  Future<List<Event>> loadForMonth(DateTime month) {
    final key = _monthKey(month);
    // Dedup: several calendar tabs load the same current month concurrently;
    // share one in-flight fetch instead of firing N requests. The cleanup
    // callback must return void — returning a future here would make
    // `whenComplete` wait on it, and `remove` returns the very future we are
    // building, which deadlocks.
    return _inFlight[key] ??= _loadMonth(key, month).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<List<Event>> _loadMonth(String key, DateTime month) async {
    final start = DateTime(month.year, month.month, 1).toUtc().toIso8601String();
    final end = DateTime(month.year, month.month + 1, 1).toUtc().toIso8601String();
    try {
      final items = await _service.getEvents(
        perPage: 200,
        filter: 'start < "$end" && end > "$start"',
      );
      _monthCache[key] = items;
      _staleMonths.remove(key);
      _loadedMonth = month;
      unawaited(_persist(key, items));
      notifyListeners();
      return items;
    } catch (_) {
      final cached = _monthCache[key] ?? await _readPersisted(key);
      if (cached != null) {
        _monthCache[key] = cached;
        _staleMonths.add(key);
        _loadedMonth = month;
        notifyListeners();
        return cached;
      }
      rethrow;
    }
  }

  Future<String> create(Event event) async {
    final id = await _service.createEvent(event);
    await _reloadIfLoaded();
    return id;
  }

  Future<void> update(String id, Map<String, dynamic> updates) async {
    await _service.updateEvent(id, updates);
    await _reloadIfLoaded();
  }

  Future<void> delete(String id) async {
    await _service.deleteEvent(id);
    await _reloadIfLoaded();
  }

  Future<void> _reloadIfLoaded() async {
    final month = _loadedMonth;
    if (month == null) return;
    try {
      await loadForMonth(month);
    } catch (_) {
      // Mutation succeeded but the follow-up reload failed: keep the previous
      // cache and mark it stale so the UI warns about outdated data.
      _staleMonths.add(_monthKey(month));
      notifyListeners();
    }
  }

  String _monthKey(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';

  Future<void> _persist(String key, List<Event> items) async {
    try {
      // Cap the in-memory cache so browsing far months can't grow it forever.
      if (_monthCache.length > 24) {
        _monthCache.remove(_monthCache.keys.first);
      }
      final prefs = await _prefs;
      await prefs.setString(
        'events_cache_$key',
        jsonEncode([for (final e in items) e.toJson()]),
      );
    } catch (_) {
      // Persistence is best-effort; never fail a load because it broke.
    }
  }

  Future<List<Event>?> _readPersisted(String key) async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString('events_cache_$key');
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in decoded) Event.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }
}

/// Holds the logged-in user and that user's entity assignments.
///
/// Owns the shared [PerformerRepository] and [VenueRepository] so assignment
/// computation (which performers/venues belong to the user) happens once at
/// login instead of being duplicated per screen.
class AuthController extends ChangeNotifier {
  AuthController({PocketBaseService? service, Future<SharedPreferences>? prefs})
      : _service = service ?? PocketBaseService.shared,
        _injectedPrefs = prefs {
    performers = PerformerRepository(service: _service);
    venues = VenueRepository(service: _service);
  }

  static const _userKey = 'auth_user';
  static const _tokenKey = 'auth_token';
  static const _cookieKey = 'auth_cookie';

  final PocketBaseService _service;
  final Future<SharedPreferences>? _injectedPrefs;
  Future<SharedPreferences>? _prefsFuture;

  // Lazy: see EventRepository.
  Future<SharedPreferences> get _prefs =>
      _prefsFuture ??= _injectedPrefs ?? SharedPreferences.getInstance();
  late final PerformerRepository performers;
  late final VenueRepository venues;

  Map<String, dynamic>? _user;
  List<Map<String, dynamic>> _myPerformers = [];
  List<Map<String, dynamic>> _myVenues = [];
  // Id sets mirroring the lists above, so screens can ask "is this mine?"
  // without re-walking the records (or re-deriving membership) themselves.
  Set<String> _myPerformerIds = {};
  Set<String> _myVenueIds = {};

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn => _user != null;
  List<Map<String, dynamic>> get myPerformers => List.unmodifiable(_myPerformers);
  List<Map<String, dynamic>> get myVenues => List.unmodifiable(_myVenues);

  /// True when [id] is a performer assigned to the logged-in user.
  ///
  /// Membership is computed once in [refresh] from each record's `memberIds`;
  /// callers must not re-implement that comparison.
  bool isMyPerformer(String id) => _myPerformerIds.contains(id);

  /// True when [id] is a venue managed by the logged-in user; see
  /// [isMyPerformer].
  bool isMyVenue(String id) => _myVenueIds.contains(id);

  Future<bool> login(String email, String password) async {
    final record = await _service.login(email, password);
    if (record == null) return false;
    _user = record;
    await _persistSession();
    await refresh();
    notifyListeners();
    return true;
  }

  /// Restores a persisted session (user + auth token/cookie) so the app can
  /// open logged-in even when offline. Entity caches are memory-only, so
  /// assignments are recomputed on the next successful online refresh.
  Future<void> restoreSession() async {
    try {
      final prefs = await _prefs;
      final raw = prefs.getString(_userKey);
      if (raw == null) return;
      _user = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _service.restoreAuth(prefs.getString(_tokenKey), prefs.getString(_cookieKey));
      await refresh();
      notifyListeners();
    } catch (_) {
      // Corrupt or unreadable session: treat as logged out.
      _user = null;
    }
  }

  /// Drops the in-memory session and the persisted credentials.
  void logout() {
    _user = null;
    _myPerformers = [];
    _myVenues = [];
    _myPerformerIds = {};
    _myVenueIds = {};
    _service.restoreAuth(null, null);
    unawaited(_clearSession());
    notifyListeners();
  }

  Future<void> _persistSession() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(_userKey, jsonEncode(_user));
      final token = _service.authToken;
      if (token != null) await prefs.setString(_tokenKey, token);
      final cookie = _service.authCookie;
      if (cookie != null) await prefs.setString(_cookieKey, cookie);
    } catch (_) {
      // Persistence is best-effort; a failed save must not fail login.
    }
  }

  Future<void> _clearSession() async {
    try {
      final prefs = await _prefs;
      await prefs.remove(_userKey);
      await prefs.remove(_tokenKey);
      await prefs.remove(_cookieKey);
    } catch (_) {
      // Best-effort.
    }
  }

  /// Reloads performer/venue caches and recomputes this user's assignments.
  ///
  /// [force] controls whether the entity caches refetch or reuse already-
  /// loaded records; pass `true` from pull-to-refresh so it actually does
  /// something instead of returning the same cached assignment list.
  Future<void> refresh({bool force = false}) async {
    final userId = _user?['id']?.toString() ?? '';
    try {
      await Future.wait([performers.load(force: force), venues.load(force: force)]);
      _myPerformers = performers.items
          .where((p) => _service.parseIds(p['memberIds']).contains(userId))
          .toList();
      _myVenues = venues.items
          .where((v) => _service.parseIds(v['managerIds']).contains(userId))
          .toList();
      _myPerformerIds = _myPerformers.map((p) => p['id']?.toString()).whereType<String>().toSet();
      _myVenueIds = _myVenues.map((v) => v['id']?.toString()).whereType<String>().toSet();
    } catch (_) {
      // entity lookup failed; keep assignments as-is
    }
    notifyListeners();
  }
}