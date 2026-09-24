import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/event.dart';
import '../models/membership.dart';
import '../models/performer.dart';
import '../models/user_lookup.dart';
import '../models/venue.dart';

/// Base URL of the PocketBase backend.
///
/// Empty by default, i.e. *same-origin*: `/api/...` resolves against whatever
/// host served the Flutter web bundle, which is how the app is deployed (the
/// web server proxies PocketBase) and how `flutter run` reaches a local
/// backend. An absolute origin is still honoured for split deployments:
///
///   flutter run --dart-define=PB_URL=http://192.168.1.10:8090
///   flutter build web --dart-define=PB_URL=https://api.example.com
///
/// For Flutter web the URL is resolved by the *browser*, so it must be
/// reachable from the client, not from the container.
const String kPocketBaseUrl = String.fromEnvironment(
  'PB_URL',
  defaultValue: '',
);

/// Classification of a failure, so screens can pick their own wording without
/// matching on server prose.
///
/// [PocketBaseException.message] carries the server's own explanation, but a
/// transport failure has none: it must be shown as localized text, which is
/// only possible if the *kind* of failure survives the throw.
enum PbErrorKind {
  network,
  timeout,
  auth,
  forbidden,
  notFound,
  validation,
  conflict,
  server,
  unknown,
}

/// Failure reported by PocketBase for a rejected request, or by the http layer
/// for a request that never reached it.
///
/// PocketBase answers a failed write with a JSON envelope such as
/// `{"data":{},"message":"Schedule conflict: venue already booked in this time
/// range.","status":400}`; [message] carries that human-readable text so
/// screens can surface the server's own explanation instead of guessing the
/// rule client-side. Bodies that are not JSON are kept verbatim.
class PocketBaseException implements Exception {
  PocketBaseException(this.statusCode, this.message, {PbErrorKind? kind})
    : kind = kind ?? _kindFor(statusCode, message);

  /// Builds an exception from a PocketBase error body.
  factory PocketBaseException.fromBody(int statusCode, String body) {
    final message = _messageFromBody(body);
    return PocketBaseException(statusCode, message);
  }

  /// HTTP status reported by the server; `0` for transport and timeout
  /// failures, which never produced a status.
  final int statusCode;

  /// Human-readable reason from the server, e.g. "Schedule conflict: venue
  /// already booked in this time range.".
  final String message;

  final PbErrorKind kind;

  /// True when the server rejected the request because the session is missing
  /// or expired; callers use this to sign the user out instead of showing an
  /// error they cannot act on.
  bool get isAuthFailure => kind == PbErrorKind.auth;

  @override
  String toString() => message.isEmpty
      ? 'PocketBaseException($statusCode)'
      : 'PocketBaseException($statusCode): $message';

  /// The most specific explanation the body carries.
  ///
  /// PocketBase wraps a validation failure in two layers: a field-level message
  /// that names the actual problem, and an envelope message that says only that
  /// something failed to validate:
  ///
  /// ```
  /// {"data":{"token":{"code":"validation_invalid_token",
  ///                   "message":"Invalid or expired token."}},
  ///  "message":"An error occurred while validating the submitted data.",
  ///  "status":400}
  /// ```
  ///
  /// Reading only `message` showed the user the envelope — so an expired
  /// password-reset link, the single most likely failure in that flow, reported
  /// "An error occurred while validating the submitted data." instead of "Invalid
  /// or expired token."; a sign-up that reuses an address reported "Failed to
  /// create record." instead of naming the address. A field message is always
  /// more specific than the envelope, so it wins whenever one is present.
  ///
  /// Field order decides between several, which is the order PocketBase
  /// serialises the schema in — deterministic, and the first problem is a
  /// reasonable one to report when a request had more than one.
  static String _messageFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final data = decoded['data'];
        if (data is Map) {
          for (final value in data.values) {
            if (value is Map) {
              final field = value['message']?.toString();
              if (field != null && field.isNotEmpty) return field;
            }
          }
        }
        final message = decoded['message']?.toString();
        if (message != null && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Not JSON: fall back to the raw body.
    }
    return body;
  }

  static PbErrorKind _kindFor(int statusCode, String message) {
    if (statusCode == 0) return PbErrorKind.network;
    if (statusCode == 401) return PbErrorKind.auth;
    if (statusCode == 403) return PbErrorKind.forbidden;
    if (statusCode == 404) return PbErrorKind.notFound;
    if (statusCode >= 500) return PbErrorKind.server;
    // 409 is what `POST /api/agenda/claim` answers when the entity already has
    // a manager. It is a conflict about the request, not about a field, so it
    // gets its own kind and the screen shows the server's own explanation.
    if (statusCode == 409) return PbErrorKind.conflict;
    if (statusCode == 400 || statusCode == 422) {
      // The double-booking guard answers 400 with a "Schedule conflict: …"
      // body. That is a conflict the calendar can explain, not a field error,
      // so it gets its own kind even though the status is the same.
      return message.trimLeft().toLowerCase().startsWith('schedule conflict')
          ? PbErrorKind.conflict
          : PbErrorKind.validation;
    }
    return PbErrorKind.unknown;
  }
}

/// One message from PocketBase's realtime (SSE) stream.
class RealtimeEvent {
  const RealtimeEvent({
    required this.action,
    required this.collection,
    required this.record,
  });

  /// `create`, `update` or `delete`.
  final String action;

  /// Collection the changed record belongs to, or `''` when the server did not
  /// name it (subscribers then have to assume anything may have changed).
  final String collection;

  final Map<String, dynamic> record;
}

/// One raw server-sent event: its `event:` name and joined `data:` payload.
///
/// Kept as a pair rather than a bare payload because the name is what
/// distinguishes the `PB_CONNECT` handshake frame from a change notification.
class _SseFrame {
  const _SseFrame({this.event, required this.data});

  final String? event;
  final String data;
}

/// Thin REST client for the app's PocketBase instance.
///
/// Only the collections this app talks to are modelled, and all of them go
/// through the same request/pagination/exception machinery: one place decides
/// how a failure is classified, how pages are followed and which requests may
/// be retried.
class PocketBaseService {
  PocketBaseService({String? baseUrl, http.Client? client})
    : baseUrl = _normalizeBase(baseUrl ?? kPocketBaseUrl),
      _client = client ?? http.Client(),
      // A caller-supplied client (tests, or a client with custom
      // interception) is owned by that caller: closing or replacing it here
      // would break it.
      _ownsClient = client == null;

  /// App-wide shared instance. Screens use this instead of constructing new
  /// instances so the auth token and cookie survive navigation.
  static final PocketBaseService shared = PocketBaseService();

  /// Origin of the backend, without a trailing slash.
  final String baseUrl;

  final http.Client _client;
  final bool _ownsClient;

  String? _authToken;
  String? _cookieHeader;

  String? get authToken => _authToken;
  String? get authCookie => _cookieHeader;

  static const Duration _requestTimeout = Duration(seconds: 15);

  /// Backoff between the automatic retries of an idempotent GET.
  static const List<Duration> _retryDelays = [
    Duration(milliseconds: 250),
    Duration(seconds: 1),
  ];

  /// Closes the http client. Only the client this service created is closed:
  /// an injected one belongs to its creator.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// Restores a previously persisted session (token + cookie) without a
  /// network round-trip.
  void restoreAuth(String? token, String? cookie) {
    _authToken = token;
    _cookieHeader = cookie;
  }

  // ---------------------------------------------------------------- auth

  /// Signs in and returns the `users` record.
  ///
  /// Throws [PocketBaseException] for every rejection, including bad
  /// credentials — [SessionController] is the layer that decides a rejected
  /// password is not an error worth showing.
  Future<Map<String, dynamic>> login(String email, String password) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/users/auth-with-password'),
      body: {'identity': email, 'password': password},
    );
    final data = _decodeMap(resp);
    _captureSession(resp, data);
    final record = data['record'] ?? data['user'];
    if (record is! Map) {
      // A 2xx without a user record means the server contract changed; failing
      // loudly beats reporting a signed-in session with an empty user.
      throw PocketBaseException(
        0,
        'Login response did not include a user record',
        kind: PbErrorKind.unknown,
      );
    }
    return Map<String, dynamic>.from(record);
  }

  /// Creates a `users` record (public signup) and adopts the session
  /// PocketBase returns so the caller is signed in immediately.
  Future<Map<String, dynamic>> signUp({
    required String email,
    required String password,
    required String passwordConfirm,
    String? name,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/users/records'),
      body: {
        'email': email,
        'password': password,
        'passwordConfirm': passwordConfirm,
        if (name != null && name.isNotEmpty) 'name': name,
      },
    );
    final created = _decodeMap(resp);
    // The record exists but the response carries no token; authenticate to get
    // one. If that call fails the account is still valid, so the created
    // record is a better answer than an error.
    try {
      return await login(email, password);
    } on PocketBaseException {
      return created;
    }
  }

  /// Asks PocketBase to email a password-reset link to [email].
  ///
  /// Answers 204 with an empty body for every input — an address with an
  /// account, one without, and a server with no mailer configured alike.
  /// PocketBase refuses to answer differently because "no such account" and
  /// "sent" must be indistinguishable; otherwise the endpoint is an
  /// email-enumeration oracle. So a normal return means only "the request was
  /// accepted", never "an email is on its way". Whether delivery is even
  /// possible is a separate question, which [mailEnabled] answers.
  Future<void> requestPasswordReset(String email) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/users/request-password-reset'),
      body: {'email': email},
    );
    _ensureSuccess(resp);
  }

  /// Sets a new password from the token in a reset email.
  ///
  /// A stale, reused or forged token is refused with 400 and the server's own
  /// wording ("Invalid or expired token."), which reaches the screen as
  /// [PocketBaseException.message]. The three cases are deliberately not
  /// distinguished -- the server cannot tell them apart either.
  Future<void> confirmPasswordReset({
    required String token,
    required String password,
    required String passwordConfirm,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/users/confirm-password-reset'),
      body: {
        'token': token,
        'password': password,
        'passwordConfirm': passwordConfirm,
      },
    );
    _ensureSuccess(resp);
  }

  /// Whether this server has a usable SMTP configuration.
  ///
  /// `GET /api/agenda/mail-status`. The reset form asks this before promising
  /// anything: with no mailer a reset request still answers 204 and no email is
  /// ever sent, so the honest message is "recovery is not available here, ask an
  /// administrator" rather than an inbox that will stay empty forever.
  ///
  /// A failure to ask reads as unavailable. That is the safe direction — it
  /// points at the administrator path, which always works, instead of at an
  /// email that will never arrive.
  Future<bool> mailEnabled() async {
    try {
      final resp = await _send(
        'GET',
        _uri('/api/agenda/mail-status'),
        retry: true,
      );
      return _decodeMap(resp)['enabled'] == true;
    } on PocketBaseException {
      return false;
    }
  }

  /// Whether this server offers guest sign-in.
  ///
  /// `GET /api/agenda/guest-status`, backed by `PB_GUEST_LOGIN` (see
  /// `pb_hooks/guest.pb.js`). The sign-in page asks this and draws the guest
  /// button only when the answer is yes, so a deployment with the switch off
  /// never shows a button that cannot work.
  ///
  /// A failure to ask reads as unavailable — the same defensible direction
  /// [mailEnabled] takes, and the one that matters more here: a button offered
  /// on a false positive fails in the user's face, while a button withheld on a
  /// false negative leaves the ordinary signup form, which is always there.
  Future<bool> guestEnabled() async {
    try {
      final resp = await _send(
        'GET',
        _uri('/api/agenda/guest-status'),
        retry: true,
      );
      return _decodeMap(resp)['enabled'] == true;
    } on PocketBaseException {
      return false;
    }
  }

  /// Creates a throwaway account and signs in, for demoing without an address.
  ///
  /// The credentials are generated here rather than by the server, and the
  /// account is created through [signUp] — the same public endpoint a
  /// self-service registration uses. That is the whole point: a guest is an
  /// ordinary account, so there is one creation path to reason about, and the
  /// server's own rules and rate limits apply unchanged. See
  /// `pb_hooks/guest.pb.js` for why the server only reports the capability.
  ///
  /// The address uses the reserved `.invalid` TLD, which can never resolve and
  /// can never be owned, so a guest address can never collide with a real one or
  /// be used to receive mail.
  ///
  /// Throws [PocketBaseException] if the account cannot be created (guest login
  /// disabled server-side, rate limited) — the screen shows the server's own
  /// wording, since "why can I not get in" is exactly what the user needs.
  Future<Map<String, dynamic>> signInAsGuest({String? name}) async {
    final random = Random.secure();
    String token(String alphabet, int length) => List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();

    // Alphanumeric only, and not the password's alphabet: this is an *address*,
    // so it goes through email-format validation and appears in URLs and logs.
    // Symbols there are a needless risk (a `&` or `#` in a local part is legal
    // by RFC 5322 and still confusing to every tool that meets it), and there is
    // nothing to gain — nobody types either of these.
    final suffix =
        '${DateTime.now().millisecondsSinceEpoch}'
        '${token(_addressAlphabet, 8)}';
    final email = 'guest-$suffix@guest.invalid';
    // 24 characters from a 32-symbol alphabet, so ~120 bits: far past guessing,
    // and it never leaves this function — the caller only ever holds the
    // resulting session.
    final password = token(_guestAlphabet, 24);
    // `signUp` adopts the session it gets back, or falls back to the created
    // record when the follow-up sign-in fails. Either way a returned record
    // means the account exists and the caller is signed in.
    return signUp(
      email: email,
      password: password,
      passwordConfirm: password,
      name: name,
    );
  }

  /// Characters a guest *address* token is drawn from.
  ///
  /// Lowercase alphanumerics with the lookalikes (`l`, `o`, `0`, `1`) removed,
  /// so a `guest-...@guest.invalid` in a log or a database row is unambiguous if
  /// anybody ever has to read one.
  static const String _addressAlphabet = 'abcdefghijkmnpqrstuvwxyz23456789';

  /// Characters a generated guest password is drawn from.
  ///
  /// Deliberately includes mixed case, digits and symbols: PocketBase enforces a
  /// minimum password length on the `users` collection, and a generator that
  /// could produce a rejected password would make guest sign-in fail
  /// intermittently — the kind of bug that only shows up in front of an audience.
  /// The password is never typed by a human, so nothing is gained by making it
  /// memorable.
  static const String _guestAlphabet =
      'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#%^&*-_';

  void _captureSession(http.Response resp, Map<String, dynamic> data) {
    final token = data['token']?.toString();
    if (token != null && token.isNotEmpty) _authToken = token;
    final setCookie = resp.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      final pairs = <String>[];
      for (final match in RegExp(
        r'([^=;\s]+)=([^;\s]+)',
      ).allMatches(setCookie)) {
        pairs.add('${match.group(1)}=${match.group(2)}');
      }
      if (pairs.isNotEmpty) _cookieHeader = pairs.join('; ');
    }
  }

  // -------------------------------------------------------------- events

  /// Fetches every event record matching [filter], following pagination until
  /// the collection is exhausted.
  ///
  /// Related venue/performer records are expanded inline so callers do not need
  /// a second lookup per event.
  Future<List<Event>> getEvents({String? filter, int perPage = 200}) async {
    final records = await _fetchAll(
      'events',
      perPage: perPage,
      filter: filter,
      extra: const {'expand': 'venueId,performers', 'sort': 'start'},
    );
    return [
      for (final record in records)
        Event.fromMap(record, record['id']?.toString()),
    ];
  }

  /// Events that have not finished by [from], soonest first.
  ///
  /// The bound is on `end`, not `start`: a booking that began an hour ago and
  /// runs for another hour is the most immediate thing on the schedule, and
  /// asking only for future *starts* would hide it until it was over.
  ///
  /// One indexed query answers "what is next" for the whole collection, which is
  /// why the upcoming view does not have to guess a horizon in months.
  Future<List<Event>> getUpcoming(DateTime from, {int perPage = 200}) =>
      getEvents(filter: 'end > ${_quotedDate(from)}', perPage: perPage);

  /// Every instance of one recurrence, soonest first.
  ///
  /// A series has no server-side grouping beyond this field, so the caller
  /// resolves the instances through it rather than by guessing at dates.
  Future<List<Event>> getSeries(String seriesId, {int perPage = 200}) =>
      getEvents(filter: 'seriesId = ${_quoted(seriesId)}', perPage: perPage);

  /// A filter operand for a date: quoted, UTC, and in the ISO-8601 shape the
  /// server stores its own autodates in.
  static String _quotedDate(DateTime value) =>
      _quoted(value.toUtc().toIso8601String());

  /// A filter operand for a string, quoted and escaped.
  ///
  /// The filter grammar escapes quotes and backslashes with a backslash; the URL
  /// encoding of the filter itself is handled by `_uri`.
  static String _quoted(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  Future<Event> createEvent(Event event) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/events/records'),
      body: event.toMap(),
    );
    final data = _decodeMap(resp);
    return Event.fromMap(data, data['id']?.toString());
  }

  Future<void> updateEvent(String id, Map<String, dynamic> updates) async {
    final resp = await _send(
      'PATCH',
      _uri('/api/collections/events/records/$id'),
      body: updates,
    );
    _ensureSuccess(resp);
  }

  Future<void> deleteEvent(String id) async {
    final resp = await _send(
      'DELETE',
      _uri('/api/collections/events/records/$id'),
    );
    _ensureSuccess(resp);
  }

  // -------------------------------------------------------------- venues

  /// All venues, optionally narrowed server-side by a name substring.
  ///
  /// Ordered by name: the pickers show this list as-is, and `-created` would
  /// shuffle it every time an unrelated venue is added.
  Future<List<Venue>> getVenues({String? search}) async {
    final records = await _fetchAll(
      'venues',
      filter: _nameSearchFilter(search),
      extra: const {'sort': 'name'},
    );
    return [for (final record in records) Venue.fromMap(record)];
  }

  Future<Venue> createVenue(Map<String, dynamic> body) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/venues/records'),
      body: body,
    );
    return Venue.fromMap(_decodeMap(resp));
  }

  Future<void> updateVenue(String id, Map<String, dynamic> updates) async {
    final resp = await _send(
      'PATCH',
      _uri('/api/collections/venues/records/$id'),
      body: updates,
    );
    _ensureSuccess(resp);
  }

  Future<void> deleteVenue(String id) async {
    final resp = await _send(
      'DELETE',
      _uri('/api/collections/venues/records/$id'),
    );
    _ensureSuccess(resp);
  }

  // ---------------------------------------------------------- performers

  /// All performers, optionally narrowed server-side by a name substring.
  Future<List<Performer>> getPerformers({String? search}) async {
    final records = await _fetchAll(
      'performers',
      filter: _nameSearchFilter(search),
      extra: const {'sort': 'name'},
    );
    return [for (final record in records) Performer.fromMap(record)];
  }

  Future<Performer> createPerformer(Map<String, dynamic> body) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/performers/records'),
      body: body,
    );
    return Performer.fromMap(_decodeMap(resp));
  }

  Future<void> updatePerformer(String id, Map<String, dynamic> updates) async {
    final resp = await _send(
      'PATCH',
      _uri('/api/collections/performers/records/$id'),
      body: updates,
    );
    _ensureSuccess(resp);
  }

  Future<void> deletePerformer(String id) async {
    final resp = await _send(
      'DELETE',
      _uri('/api/collections/performers/records/$id'),
    );
    _ensureSuccess(resp);
  }

  // --------------------------------------------------------- memberships

  /// Memberships visible to the authenticated user: the rows they hold plus
  /// the invitations addressed to their email address.
  ///
  /// `memberships.listRule` is self-only, so this is deliberately *not* a
  /// roster: a manager cannot read the people they manage through the
  /// collection, which is why [getRoster] exists. Anything other than the
  /// caller's own rows has to come from there.
  Future<List<Membership>> getMemberships({String? filter}) async {
    final records = await _fetchAll('memberships', filter: filter);
    return [for (final record in records) Membership.fromMap(record)];
  }

  /// The full roster of [targetId]: every active and pending membership, with
  /// each member's name and email resolved server-side.
  ///
  /// Served by a dedicated route rather than the collection. The collection's
  /// rule is self-only, and a PocketBase rule cannot express "a row exists
  /// where I am an active manager" — which is exactly the question a manager
  /// opening the roster is asking. The route answers it with its own
  /// authorization check.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.forbidden] when the caller
  /// does not manage the target (a plain `member` included). That 403 is
  /// intentional and has to reach the screen: showing an empty roster to
  /// somebody who may not read one would disguise an authorization failure as
  /// "no team".
  Future<List<Membership>> getRoster({
    required TargetType targetType,
    required String targetId,
  }) async {
    final resp = await _send(
      'GET',
      _uri('/api/agenda/roster', {
        'targetType': targetTypeWire(targetType),
        'targetId': targetId,
      }),
      retry: true,
    );
    final data = _decodeMap(resp);
    final raw = data['items'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Membership.fromMap(Map<String, dynamic>.from(item)),
    ];
  }

  /// Every join request awaiting the caller's decision.
  ///
  /// Fills the gap [getMemberships] cannot: the collection's rule is self-only,
  /// so the rows where *somebody else* asks to join an entity the caller
  /// manages are not in the caller's list. A PocketBase rule cannot express
  /// "does an active manager row exist for this target" either — `targetId` and
  /// `targetType` are a polymorphic pair of text columns with nothing to join
  /// back through — so the question is answered by this route, server-side,
  /// with the same roster-shaped rows as [getRoster].
  ///
  /// Returns an empty list, not a 403, when the caller manages nothing: "nobody
  /// has asked to join what you manage" is the honest answer there, and a
  /// forbidden would make the dashboard render an authorization failure over an
  /// account that is simply not a manager yet.
  Future<List<Membership>> getIncomingRequests() async {
    final resp = await _send('GET', _uri('/api/agenda/requests'), retry: true);
    final data = _decodeMap(resp);
    final raw = data['items'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Membership.fromMap(Map<String, dynamic>.from(item)),
    ];
  }

  /// Accepts or declines the invitation [membershipId].
  ///
  /// This is the one membership write a non-manager may make, and only for a
  /// row addressed to them — the server enforces both. `accept` flips the row
  /// to `active`; `decline` deletes it, so a declined invitation leaves no row
  /// behind to trip the duplicate-email check on a later re-invite.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.validation] for a row that
  /// is already active (accept) or already gone, and [PbErrorKind.forbidden]
  /// for anybody who is not the invitee.
  Future<void> respondToInvite({
    required String membershipId,
    required bool accept,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/agenda/invite/respond'),
      body: {
        'membershipId': membershipId,
        'action': accept ? 'accept' : 'decline',
      },
    );
    _ensureSuccess(resp);
  }

  /// Adopts an existing venue or performer for the authenticated user.
  ///
  /// Goes through a dedicated route rather than the `memberships` collection:
  /// its create rule requires you to already manage the target, and the whole
  /// point of a claim is that nobody manages it yet.
  ///
  /// Succeeds both when the entity was just claimed and when the caller already
  /// managed it — the server treats the second as idempotent, so a double-tap
  /// or a retry after a flaky response is not an error.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.conflict] when somebody else
  /// manages the entity, carrying the server's own wording.
  Future<void> claimEntity({
    required TargetType targetType,
    required String targetId,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/agenda/claim'),
      body: {'targetType': targetTypeWire(targetType), 'targetId': targetId},
    );
    _ensureSuccess(resp);
  }

  /// Asks to join [targetType]/[targetId] on the caller's own behalf.
  ///
  /// The counterpart of [createMembership] for somebody who does *not* manage
  /// the entity: a musician who found their venue in the public list can raise
  /// their hand without waiting to be noticed. The row it creates is
  /// **pending** with `initiatedBy = request`, so it grants nothing at all —
  /// not event access, not admin rights — until an active manager of the target
  /// approves it. That is deliberate: self-service has to be a request for
  /// consent, never a way to take ownership.
  ///
  /// Goes through a dedicated route rather than the `memberships` collection.
  /// The collection's create rule is manager-only (an invitation), which is the
  /// trap this avoids: a direct POST of the caller's own active row has to stay
  /// impossible, and a route is where "pending, whoever asks" can actually be
  /// enforced. [role] is `member` or `manager` and the server rejects anything
  /// else; neither value is ever granted directly.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.validation] — carrying the
  /// server's own wording — when the caller already holds an active row, when
  /// an earlier request is still unanswered, and when the caller already
  /// manages the target. The three are separate messages on purpose: each one
  /// tells the user something different about why the button should not have
  /// been there.
  Future<void> requestToJoin({
    required TargetType targetType,
    required String targetId,
    String role = 'member',
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/agenda/join'),
      body: {
        'targetType': targetTypeWire(targetType),
        'targetId': targetId,
        'role': role,
      },
    );
    _ensureSuccess(resp);
  }

  /// Approves or rejects the join request [membershipId].
  ///
  /// Approving flips the row to `active` with the role the requester asked for;
  /// rejecting deletes it, so a rejected request leaves nothing behind to trip
  /// the duplicate-request check on a later attempt.
  ///
  /// Only an **active manager** of the row's target may decide, and the route
  /// refuses the requester themselves — approving your own request is exactly
  /// the privilege escalation this endpoint must not allow, so the 403 has to
  /// be enforced server-side rather than by hiding the button.
  ///
  /// [approve] works on a pending row of *either* origin, so a manager can also
  /// use it to push an unclaimed invitation through. That is deliberate: there
  /// is no email channel and no notification beyond an in-app count, so an
  /// invitee who never signs in would otherwise leave the invitation — and the
  /// entity's roster — stuck forever. This is the only recovery path.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.forbidden] for a caller who
  /// does not manage the target (requester included), [PbErrorKind.validation]
  /// for a row that is not pending and [PbErrorKind.notFound] for a row that
  /// does not exist.
  Future<void> decideRequest({
    required String membershipId,
    required bool approve,
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/agenda/roster/decide'),
      body: {
        'membershipId': membershipId,
        'action': approve ? 'approve' : 'reject',
      },
    );
    _ensureSuccess(resp);
  }

  // --------------------------------------------------------- user lookup

  /// Asks whether [email] already has an account, for the invite form's hint.
  ///
  /// A courtesy, not a gate: the answer only changes the helper text next to
  /// the field ("they already have an account and will be asked to accept" vs
  /// "no account yet"). A caller who does not manage anything gets a 403 —
  /// without that check the endpoint would answer "does this address have an
  /// account?" for every address in the user table, to any signed-in account.
  ///
  /// The response is [UserLookup] and nothing else, so no other account field
  /// can leak through it. Retries like any other GET, because it is one: a
  /// retried hint is a second question, not a second invitation.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.forbidden] when the caller
  /// manages no venue or performer, and [PbErrorKind.validation] for an empty
  /// address.
  Future<UserLookup> lookupUser(String email) async {
    final resp = await _send(
      'GET',
      _uri('/api/agenda/user-lookup', {'email': email}),
      retry: true,
    );
    return UserLookup.fromMap(_decodeMap(resp));
  }

  /// Invites [email] to [targetId], or links [userId] directly when it is
  /// already known.
  ///
  /// Both identifiers are accepted because the server resolves whichever one
  /// is present. The new row is **pending** either way: when [email] matches an
  /// existing account the server fills `userId` but keeps the row pending, so
  /// the invite grants nothing until the invitee accepts it. `initiatedBy` is
  /// set by the server and a client value is ignored.
  Future<Membership> createMembership({
    required String targetId,
    required TargetType targetType,
    String? userId,
    String? email,
    String role = 'manager',
  }) async {
    final resp = await _send(
      'POST',
      _uri('/api/collections/memberships/records'),
      body: {
        'targetId': targetId,
        'targetType': targetTypeWire(targetType),
        'role': role,
        if (userId != null && userId.isNotEmpty) 'userId': userId,
        if (email != null && email.isNotEmpty) 'pendingEmail': email,
      },
    );
    return Membership.fromMap(_decodeMap(resp));
  }

  /// Changes [id]'s `role` and/or `status` — the only two fields the server
  /// lets a client update.
  ///
  /// Only the fields the caller supplies are sent: on any membership update the
  /// server forces `targetId`, `targetType`, `userId`, `pendingEmail` and
  /// `createdBy` back to their stored values, so a manager of venue A cannot
  /// re-point a row belonging to venue B at A and inherit B's members. Sending
  /// an identity field here would therefore be silently ignored, not honoured.
  ///
  /// Throws [PocketBaseException] with [PbErrorKind.validation] — carrying the
  /// server's own wording — when the change would leave the target with no
  /// active manager, which includes demoting or removing the last one (and
  /// self-removal).
  Future<void> updateMembership(
    String id, {
    String? role,
    MembershipStatus? status,
  }) async {
    final body = <String, dynamic>{
      'role': ?role,
      if (status != null) 'status': membershipStatusWire(status),
    };
    // Nothing was asked for: skip the round-trip rather than send an empty
    // patch the server would treat as a no-op update it still has to validate.
    if (body.isEmpty) return;
    final resp = await _send(
      'PATCH',
      _uri('/api/collections/memberships/records/$id'),
      body: body,
    );
    _ensureSuccess(resp);
  }

  Future<void> deleteMembership(String id) async {
    final resp = await _send(
      'DELETE',
      _uri('/api/collections/memberships/records/$id'),
    );
    _ensureSuccess(resp);
  }

  // ------------------------------------------------------------- content

  /// Subscribes to the server's realtime stream for [collections].
  ///
  /// PocketBase's realtime protocol is **server-first**: the long-lived
  /// `GET /api/realtime` is opened first and answers with a `PB_CONNECT` frame
  /// carrying the `clientId`; only then does a `POST /api/realtime` register the
  /// subscriptions against that id. Doing it the other way round looks
  /// symmetrical and is silently broken — there is no clientId to POST, the
  /// server answers `204` with no body, and no change notification ever
  /// arrives.
  ///
  /// Every reconnect repeats the whole sequence, because a new connection gets a
  /// new clientId. The stream reconnects on its own with exponential backoff
  /// (1 s → 30 s) and stops for good when the subscription is cancelled.
  Stream<RealtimeEvent> realtime(List<String> collections) {
    // The SSE response body stays open for the life of the subscription, so it
    // gets its own connection: closing the client used for ordinary requests
    // to cancel the stream would abort every other in-flight request. An
    // injected client is reused and never closed here — it belongs to whoever
    // injected it.
    final client = _ownsClient ? http.Client() : _client;
    var cancelled = false;
    var failures = 0;
    late final StreamController<RealtimeEvent> controller;

    Future<void> pump() async {
      while (!cancelled) {
        try {
          final request = http.Request('GET', _uri('/api/realtime'));
          request.headers.addAll(_buildHeaders(json: false));
          request.headers['Accept'] = 'text/event-stream';
          final response = await client.send(request);
          if (response.statusCode < 200 || response.statusCode >= 300) {
            final body = await response.stream.bytesToString();
            throw PocketBaseException.fromBody(response.statusCode, body);
          }
          await for (final frame in _sseFrames(response.stream)) {
            if (cancelled) break;
            if (frame.event == 'PB_CONNECT') {
              final clientId = _connectClientId(frame.data);
              if (clientId == null) continue;
              // Connected and identified: register the subscriptions, then
              // start the backoff over because the next drop is a fresh one.
              await _subscribe(clientId, collections);
              failures = 0;
              continue;
            }
            final event = _parseRealtimeFrame(frame);
            if (event != null) controller.add(event);
          }
        } catch (_) {
          // Transport failure, refused connection or the server closing the
          // stream: all of them are handled by the reconnect below rather than
          // killing the subscription.
        }
        if (cancelled) break;
        await Future<void>.delayed(_realtimeBackoff(failures));
        failures++;
      }
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<RealtimeEvent>(
      onListen: () => unawaited(pump()),
      onCancel: () {
        cancelled = true;
        // Closing the SSE connection unblocks `pump`'s `await for`, which is
        // what lets the loop notice `cancelled` and close the controller.
        if (_ownsClient) client.close();
      },
    );
    return controller.stream;
  }

  /// Extracts the `clientId` from a `PB_CONNECT` frame's payload.
  static String? _connectClientId(String data) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map) {
        final id = decoded['clientId']?.toString();
        if (id != null && id.isNotEmpty) return id;
      }
    } catch (_) {
      // Malformed connect frame: treat as "not connected" and let the
      // reconnect path handle it.
    }
    return null;
  }

  /// Registers [collections] on an open connection. Answers `204` with no body.
  Future<void> _subscribe(String clientId, List<String> collections) async {
    final resp = await _send(
      'POST',
      _uri('/api/realtime'),
      body: {'clientId': clientId, 'subscriptions': collections},
    );
    _ensureSuccess(resp);
  }

  static Duration _realtimeBackoff(int failures) {
    final step = failures < 5 ? failures : 5;
    final seconds = 1 << step; // 1, 2, 4, 8, 16, 32
    return Duration(seconds: seconds > 30 ? 30 : seconds);
  }

  /// Splits an SSE byte stream into frames.
  ///
  /// Frames are blank-line delimited. The `event:` field is kept because it is
  /// the only way to tell the connection handshake (`PB_CONNECT`) apart from a
  /// change notification, and it also names the collection a notification came
  /// from. `:` keep-alives and the `id:`/`retry:` fields carry nothing this
  /// client needs. Multiple `data:` lines in one frame are joined with a
  /// newline, which JSON tolerates.
  static Stream<_SseFrame> _sseFrames(Stream<List<int>> body) async* {
    String? event;
    final data = StringBuffer();
    await for (final line
        in body.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield _SseFrame(event: event, data: data.toString());
          data.clear();
        }
        event = null;
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }
  }

  /// Parses one frame, returning null for anything that is not a change
  /// notification (the connect frame, a keep-alive body, a truncated frame).
  static RealtimeEvent? _parseRealtimeFrame(_SseFrame frame) {
    try {
      final decoded = jsonDecode(frame.data);
      if (decoded is! Map) return null;
      final record = decoded['record'];
      final recordMap = record is Map
          ? Map<String, dynamic>.from(record)
          : <String, dynamic>{};
      // The `event:` field names the collection authoritatively; the record's
      // own `collectionName` is the fallback for a server that omits it.
      final collection = (frame.event != null && frame.event!.isNotEmpty)
          ? frame.event!
          : (recordMap['collectionName'] ?? decoded['collection'] ?? '')
                .toString();
      return RealtimeEvent(
        action: (decoded['action'] ?? '').toString(),
        collection: collection,
        record: recordMap,
      );
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------- request

  /// Sends one request, optionally retrying transport failures and 5xx.
  ///
  /// [retry] is only ever set for GETs: a retried write could be applied twice,
  /// and this app cannot tell a duplicate booking from a deliberate one.
  Future<http.Response> _send(
    String method,
    Uri url, {
    Object? body,
    bool retry = false,
  }) async {
    final attempts = retry ? _retryDelays.length + 1 : 1;
    for (var attempt = 1; ; attempt++) {
      try {
        final resp = await _dispatch(
          method,
          url,
          body,
        ).timeout(_requestTimeout);
        if (retry && attempt < attempts && resp.statusCode >= 500) {
          await Future<void>.delayed(_retryDelays[attempt - 1]);
          continue;
        }
        return resp;
      } catch (error, stack) {
        if (error is PocketBaseException) rethrow;
        if (!retry || attempt >= attempts) {
          Error.throwWithStackTrace(_transportFailure(error), stack);
        }
        await Future<void>.delayed(_retryDelays[attempt - 1]);
      }
    }
  }

  Future<http.Response> _dispatch(String method, Uri url, Object? body) {
    final headers = _buildHeaders(json: body != null);
    final encoded = body == null ? null : jsonEncode(body);
    return switch (method) {
      'GET' => _client.get(url, headers: headers),
      'POST' => _client.post(url, headers: headers, body: encoded),
      'PATCH' => _client.patch(url, headers: headers, body: encoded),
      'DELETE' => _client.delete(url, headers: headers),
      _ => throw ArgumentError.value(
        method,
        'method',
        'Unsupported HTTP method',
      ),
    };
  }

  Map<String, String> _buildHeaders({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (_cookieHeader != null && _cookieHeader!.isNotEmpty) {
      headers['Cookie'] = _cookieHeader!;
    }
    if (_authToken != null && _authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_authToken!}';
    }
    return headers;
  }

  /// Maps a http-layer failure onto the taxonomy.
  ///
  /// `SocketException` is a `dart:io` type and `dart:io` does not exist on the
  /// web, so it is matched by name: on the VM a dropped connection arrives as
  /// `SocketException`, in the browser as [http.ClientException]. A
  /// [FormatException] here is a body that could not be decoded, which is a
  /// transport-level failure rather than a server rejection.
  static PocketBaseException _transportFailure(Object error) {
    if (error is TimeoutException) {
      return PocketBaseException(
        0,
        'Request timed out',
        kind: PbErrorKind.timeout,
      );
    }
    final name = error.runtimeType.toString();
    if (error is http.ClientException ||
        error is FormatException ||
        name.contains('SocketException')) {
      return PocketBaseException(
        0,
        error.toString(),
        kind: PbErrorKind.network,
      );
    }
    return PocketBaseException(0, error.toString(), kind: PbErrorKind.unknown);
  }

  /// The single pagination path for every collection.
  ///
  /// Follows pages until the server reports that everything has been returned:
  /// a size check alone would stop early on a filtered collection whose last
  /// page happens to be full, and a `totalItems` check alone would hang on a
  /// server that does not report it. Both are therefore used.
  Future<List<Map<String, dynamic>>> _fetchAll(
    String collection, {
    int perPage = 200,
    String? filter,
    Map<String, String> extra = const {},
  }) async {
    final all = <Map<String, dynamic>>[];
    var page = 1;
    while (true) {
      final resp = await _send(
        'GET',
        _uri('/api/collections/$collection/records', {
          'page': '$page',
          'perPage': '$perPage',
          if (filter != null && filter.isNotEmpty) 'filter': filter,
          ...extra,
        }),
        retry: true,
      );
      final data = _decodeMap(resp);
      final raw = data['items'];
      final parsed = raw is List
          ? [
              for (final item in raw)
                if (item is Map) Map<String, dynamic>.from(item),
            ]
          : const <Map<String, dynamic>>[];
      all.addAll(parsed);
      final total = (data['totalItems'] as num?)?.toInt();
      if (parsed.isEmpty) break;
      if (total != null && all.length >= total) break;
      if (parsed.length < perPage) break;
      page++;
    }
    return all;
  }

  void _ensureSuccess(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) return;
    throw PocketBaseException.fromBody(resp.statusCode, resp.body);
  }

  Map<String, dynamic> _decodeMap(http.Response resp) {
    _ensureSuccess(resp);
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Handled below: an unreadable 2xx body is reported like a transport
      // failure, because no server rejection is involved.
    }
    throw PocketBaseException(
      0,
      resp.body.isEmpty ? 'Empty response body' : resp.body,
      kind: PbErrorKind.network,
    );
  }

  /// Builds the query [Uri] for [path], with the base URL as the origin.
  ///
  /// Every query string in this client is assembled here, through
  /// `Uri(queryParameters:)`, so values are percent-encoded exactly once and a
  /// filter containing quotes or `&&` cannot corrupt the URL. A base URL that
  /// carries a path (a backend mounted behind a reverse proxy, e.g.
  /// `https://example.com/pocketbase`) is kept: replacing the path outright
  /// would silently point every request at the proxy root.
  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(
      path: '$prefix$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  static String _normalizeBase(String raw) {
    var value = raw.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// PocketBase filter selecting records whose `name` contains [search].
  static String? _nameSearchFilter(String? search) {
    final term = (search ?? '').trim();
    if (term.isEmpty) return null;
    // The filter grammar escapes quotes and backslashes with a backslash; the
    // URL encoding of the filter itself is handled by `_uri`.
    return 'name ~ ${_quoted(term)}';
  }
}
