import 'dart:async';

import '../services/pocketbase_service.dart';
import 'repositories.dart';

/// Keeps the local caches in step with the server.
///
/// Every screen reads from the repositories, so a change made on another device
/// (or another tab) stays invisible until something refetches. This subscribes
/// to PocketBase's realtime stream and refetches only what actually changed,
/// which is what makes a shared calendar usable by two people at once.
///
/// Events are coalesced: the server emits one message per record, and a
/// recurring series can land as a dozen of them, so a short debounce turns a
/// burst into a single reload per collection.
class RealtimeSync {
  RealtimeSync({
    required PocketBaseService service,
    required EventRepository events,
    required PerformerRepository performers,
    required VenueRepository venues,
    required MembershipRepository memberships,
  }) {
    // Assigned in the body rather than through private initializing formals:
    // the parameter names are part of the wiring contract (`service:`,
    // `events:` …) and cannot be renamed to match the fields. The fields are
    // effectively final — private, assigned exactly once, here.
    _service = service;
    _events = events;
    _performers = performers;
    _venues = venues;
    _memberships = memberships;
  }

  /// How long to wait for the burst of messages that follows one user action
  /// before refetching.
  static const Duration _debounce = Duration(milliseconds: 500);

  /// Delay before re-subscribing if the stream ends while we are still meant to
  /// be running. The service already reconnects internally; this only covers
  /// the stream being closed outright, and the delay keeps a failure that
  /// completes instantly from turning into a hot loop.
  static const Duration _resubscribeDelay = Duration(seconds: 5);

  late final PocketBaseService _service;
  late final EventRepository _events;
  late final PerformerRepository _performers;
  late final VenueRepository _venues;
  late final MembershipRepository _memberships;

  StreamSubscription<RealtimeEvent>? _subscription;
  Timer? _debounceTimer;
  Timer? _resubscribeTimer;
  Set<_Watched> _dirty = {};
  bool _running = false;
  bool _disposed = false;

  /// Starts listening. Idempotent: the app calls it once at startup, and a
  /// duplicate call must not open a second SSE connection.
  void start() {
    if (_disposed || _running) return;
    _running = true;
    _subscribe();
  }

  /// Stops listening and releases the server-side subscription.
  void stop() {
    _running = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = null;
    _dirty = {};
    _subscription?.cancel();
    _subscription = null;
  }

  /// [stop] plus a tombstone: a disposed instance never listens again.
  void dispose() {
    _disposed = true;
    stop();
  }

  void _subscribe() {
    _subscription = _service
        .realtime(const ['events', 'venues', 'performers', 'memberships'])
        .listen(
          _onEvent,
          // The service classifies and reconnects on its own; an error here is
          // already being handled by the reconnect loop.
          onError: (_) {},
          onDone: _onDone,
        );
  }

  void _onDone() {
    _subscription = null;
    if (!_running) return;
    _resubscribeTimer?.cancel();
    _resubscribeTimer = Timer(_resubscribeDelay, () {
      if (_running) _subscribe();
    });
  }

  void _onEvent(RealtimeEvent event) {
    _dirty.add(_watchedFor(event.collection));
    // One timer for the whole burst: each arriving message pushes the reload
    // out, so a series create refetches once instead of once per instance.
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, _flush);
  }

  Future<void> _flush() async {
    _debounceTimer = null;
    final dirty = _dirty;
    _dirty = {};
    if (dirty.isEmpty) return;
    // An unlabelled message cannot be attributed to one collection, so it has
    // to be treated as "everything may have changed".
    final all = dirty.contains(_Watched.all);

    // Sequential: these are bursts of one refetch each, and firing them all at
    // once would only add load to the server that just pushed the change.
    if (all || dirty.contains(_Watched.events)) {
      await _guard(_events.refreshLoaded());
    }
    if (all || dirty.contains(_Watched.performers)) {
      await _guard(_performers.load(force: true));
    }
    if (all || dirty.contains(_Watched.venues)) {
      await _guard(_venues.load(force: true));
    }
    if (all || dirty.contains(_Watched.memberships)) {
      await _guard(_memberships.load(force: true));
    }
  }

  /// A failed refresh is not fatal: the repository keeps the previous records
  /// (marked stale) and the next realtime message or pull-to-refresh retries.
  Future<void> _guard(Future<void> work) async {
    try {
      await work;
    } catch (_) {
      // Intentionally swallowed; see above.
    }
  }

  /// Maps a record's collection name onto what has to be reloaded.
  ///
  /// Anything unrecognised (including a payload the server did not label)
  /// reloads everything: showing slightly stale data is worse than one extra
  /// refetch.
  static _Watched _watchedFor(String collection) => switch (collection) {
    'events' => _Watched.events,
    'performers' => _Watched.performers,
    'venues' => _Watched.venues,
    'memberships' => _Watched.memberships,
    _ => _Watched.all,
  };
}

/// Something a realtime message can invalidate.
enum _Watched { events, performers, venues, memberships, all }
