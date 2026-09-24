import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Minimal in-memory PocketBase.
///
/// Requests go through a real [MockClient], so the repositories exercise the
/// actual URL building, pagination loop, error classification and retry policy
/// instead of a hand-written stub that could drift away from them. [intercept]
/// is the hook tests use to stall, fail or reshape one specific request, and
/// [log] records every round-trip so tests can assert how many a load made.
class FakePb {
  FakePb();

  final Map<String, List<Map<String, dynamic>>> _collections = {};

  /// The record `users/auth-with-password` answers with. Null answers 401.
  Map<String, dynamic>? authRecord;
  String authToken = 'token-1';

  /// Whether this fake server has a usable mailer, for `/api/agenda/mail-status`
  /// (see `PbMailStatus`, and `pb_hooks/mail.pb.js` on the real backend).
  bool mailEnabled = true;

  /// Whether this fake server offers guest sign-in, for
  /// `/api/agenda/guest-status` (see `pb_hooks/guest.pb.js`).
  ///
  /// Defaults to the real switch's default — off — so a test that wants the
  /// guest button has to say so, the same way the deployment does.
  bool guestEnabled = false;

  /// Answers a request instead of the default handler; return null to fall
  /// through.
  Future<http.Response?> Function(http.Request request)? intercept;

  /// `'<METHOD> <collection>'` for every request, in order.
  final List<String> log = [];

  /// The requests themselves, in the same order as [log].
  ///
  /// [log] answers "how many writes did the screen send"; a test that has to
  /// assert the wire payload a write contractually carries — explicit UTC
  /// instants, a real `performers` array, the absence of a server-set
  /// `ownerId` — reads the received request instead of reaching into the
  /// client that built it.
  final List<http.Request> requests = [];

  List<Map<String, dynamic>> records(String collection) =>
      _collections.putIfAbsent(collection, () => []);

  int count(String methodAndCollection) =>
      log.where((entry) => entry == methodAndCollection).length;

  /// Requests that targeted [collection], in order.
  List<http.Request> requestsTo(String collection) => [
    for (final request in requests)
      if (_collectionOf(request) == collection) request,
  ];

  MockClient client() => MockClient((request) async {
    log.add('${request.method} ${_collectionOf(request)}');
    requests.add(request);
    final overridden = await intercept?.call(request);
    if (overridden != null) return overridden;
    return _handle(request);
  });

  static String _collectionOf(http.Request request) {
    final segments = request.url.pathSegments;
    return segments.length > 2 ? segments[2] : '';
  }

  Future<http.Response> _handle(http.Request request) async {
    final segments = request.url.pathSegments;
    final collection = _collectionOf(request);
    final last = segments.isEmpty ? '' : segments.last;

    if (collection == 'users' && last == 'auth-with-password') {
      final record = authRecord;
      if (record == null) {
        return json(401, {'message': 'Failed to authenticate.'});
      }
      return json(200, {'token': authToken, 'record': record});
    }

    // The claim route does not live under `/records`, so it is matched on its
    // own path: `_collectionOf` reads position 2 and would report `claim`.
    // The 409 "somebody else already manages it" answer depends on
    // server-side ownership the fake does not model, so a test that needs it
    // overrides this through [intercept], like the delete-refusal test.
    if (request.method == 'POST' && request.url.path == '/api/agenda/claim') {
      return _claim(request);
    }

    // A second route outside `/records`, matched on its own path for the same
    // reason as the claim route: the membership row a request writes has to be
    // created for a caller who manages nothing, which the collection's
    // manager-only create rule cannot express.
    if (request.method == 'POST' && request.url.path == '/api/agenda/join') {
      return _join(request);
    }

    // The two password-recovery endpoints. Both are outside `/records` and both
    // answer with an EMPTY body and no JSON envelope — 204 for a reset request,
    // 204 for a spent token — so a caller that tries to decode them fails. That
    // is the real server's contract (`_ensureSuccess`, not `_decodeMap`), and the
    // reason these are modelled rather than left to the 404 fallback.
    if (request.url.path.endsWith('/request-password-reset')) {
      return http.Response('', 204);
    }
    if (request.url.path.endsWith('/confirm-password-reset')) {
      return http.Response('', 204);
    }

    // Whether the deployment can send mail at all. Defaults to true so the reset
    // form renders; a test about the no-mailer case overrides it, because that
    // path is the one that has to be asked for explicitly.
    if (request.url.path == '/api/agenda/mail-status') {
      return json(200, {'enabled': mailEnabled});
    }

    // Same shape as mail-status: one bit about server configuration, which the
    // sign-in page asks before drawing a button it cannot honour.
    if (request.url.path == '/api/agenda/guest-status') {
      return json(200, {'enabled': guestEnabled});
    }

    // The roster is served by its own route too (the memberships collection's
    // list rule is self-only, so it cannot answer "every row of an entity I
    // manage"). Modelled with the endpoint's own authorization: a caller with no
    // active manager row for the target gets the 403 the screen checks for.
    if (request.method == 'GET' && request.url.path == '/api/agenda/roster') {
      return _roster(request);
    }

    final recordsAt = segments.indexOf('records');
    if (recordsAt < 0) return json(404, {'message': 'Unknown path'});
    final id = segments.length > recordsAt + 1 ? segments[recordsAt + 1] : null;

    switch (request.method) {
      case 'GET':
        return _list(collection, request);
      case 'POST':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final created = <String, dynamic>{
          ...body,
          'id': '${collection}_${records(collection).length + 1}',
          'created': '2026-01-01T00:00:00.000Z',
        };
        records(collection).add(created);
        return json(200, created);
      case 'PATCH':
        final index = records(
          collection,
        ).indexWhere((record) => record['id'] == id);
        if (index < 0) return json(404, {'message': 'Not found'});
        records(collection)[index] = {
          ...records(collection)[index],
          ...jsonDecode(request.body) as Map<String, dynamic>,
        };
        return json(200, records(collection)[index]);
      case 'DELETE':
        records(collection).removeWhere((record) => record['id'] == id);
        return json(204, null);
      default:
        return json(405, {'message': 'Method not allowed'});
    }
  }

  /// Answers `POST /api/agenda/claim`.
  ///
  /// Models the hook's contract closely enough for the client's own logic to be
  /// exercised: the target must exist and `targetType` must be one of the two
  /// kinds, otherwise the same 400/404 the server sends comes back. It always
  /// answers `claimed`, because the fake models no ownership; the 409 path — the
  /// interesting one for the UI — is a per-test override through [intercept].
  http.Response _claim(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final type = body['targetType'];
    if (type != 'venue' && type != 'performer') {
      return json(400, {'message': 'Unknown targetType', 'status': 400});
    }
    final collection = type == 'venue' ? 'venues' : 'performers';
    final id = body['targetId'];
    if (id is! String ||
        !records(collection).any((record) => record['id'] == id)) {
      return json(404, {'message': 'Target not found', 'status': 404});
    }
    return json(200, {'status': 'claimed'});
  }

  /// Answers `POST /api/agenda/join`.
  ///
  /// Models the hook's contract closely enough for the client's own logic to be
  /// exercised: the target must exist, `targetType` and `role` must be the
  /// values the client may send, and a caller who already has a row for the
  /// pair gets the hook's own refusal rather than a second row. A successful
  /// request writes the `pending`/`request` row it promises — addressed to the
  /// *caller*, which is what makes the browse screen show "waiting for
  /// approval" on the next read instead of offering the button again.
  http.Response _join(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final type = body['targetType'];
    if (type != 'venue' && type != 'performer') {
      return json(400, {
        'message': "targetType must be 'venue' or 'performer'.",
        'status': 400,
      });
    }
    final role = (body['role'] ?? 'member').toString();
    if (role != 'member' && role != 'manager') {
      return json(400, {
        'message': "role must be 'member' or 'manager'.",
        'status': 400,
      });
    }
    final targetId = body['targetId'];
    final collection = type == 'venue' ? 'venues' : 'performers';
    if (targetId is! String ||
        !records(collection).any((record) => record['id'] == targetId)) {
      return json(404, {
        'message': 'That $type no longer exists.',
        'status': 404,
      });
    }

    final me = authRecord?['id']?.toString() ?? '';
    final mine = [
      for (final row in records('memberships'))
        if (row['userId']?.toString() == me &&
            row['targetId'] == targetId &&
            row['targetType'] == type)
          row,
    ];
    // The four refusals are the hook's, in its order: managing the target is
    // checked before "already a member", because a manager necessarily holds an
    // active row and the sentence has to be about managing.
    if (mine.any(
      (row) => row['status'] == 'active' && row['role'] == 'manager',
    )) {
      return json(400, {
        'message': 'You already manage this $type.',
        'status': 400,
      });
    }
    if (mine.any((row) => row['status'] == 'active')) {
      return json(400, {
        'message': 'You are already a member of this $type.',
        'status': 400,
      });
    }
    if (mine.any(
      (row) => row['status'] == 'pending' && row['initiatedBy'] == 'request',
    )) {
      return json(400, {
        'message': 'Your request is already waiting for approval.',
        'status': 400,
      });
    }
    if (mine.any((row) => row['status'] == 'pending')) {
      return json(400, {
        'message': 'You already have an invitation. Answer it first.',
        'status': 400,
      });
    }

    final created = <String, dynamic>{
      'id': 'membership_${records('memberships').length + 1}',
      'userId': me,
      'pendingEmail': '',
      'targetId': targetId,
      'targetType': type,
      'role': role,
      'status': 'pending',
      'initiatedBy': 'request',
      'created': '2026-01-01T00:00:00.000Z',
    };
    records('memberships').add(created);
    return json(200, {'status': 'requested', 'membershipId': created['id']});
  }

  /// Answers `GET /api/agenda/roster`.
  ///
  /// Returns the membership rows for one target and resolves what the screen
  /// renders: `isSelf` for the caller's own row (a claimed one by user id, or a
  /// pending invitation addressed to the caller's email), and a display `name`
  /// or `email` where the seed did not already supply one. A seed can set
  /// `name`/`email` directly to stand in for another account the fake has no
  /// users record for.
  http.Response _roster(http.Request request) {
    final query = request.url.queryParameters;
    final type = query['targetType'];
    final targetId = query['targetId'];
    if (type != 'venue' && type != 'performer') {
      return json(400, {'message': 'Unknown targetType', 'status': 400});
    }
    final me = authRecord?['id']?.toString() ?? '';
    final myEmail = (authRecord?['email'] ?? '').toString().toLowerCase();
    final rows = [
      for (final row in records('memberships'))
        if (row['targetId'] == targetId && row['targetType'] == type) row,
    ];
    // Only an active manager may read the roster; anything else is the 403 the
    // screen's local role check exists to avoid provoking.
    final manages = rows.any(
      (row) =>
          (row['userId']?.toString() ?? '') == me &&
          me.isNotEmpty &&
          (row['role'] ?? 'manager') == 'manager' &&
          (row['status'] ?? 'pending') == 'active',
    );
    if (!manages) return json(403, {'message': 'Forbidden', 'status': 403});

    return json(200, {
      'items': [
        for (final row in rows)
          {...row, ..._rosterIdentity(row, me: me, myEmail: myEmail)},
      ],
    });
  }

  /// The `isSelf`/`name`/`email` the roster endpoint resolves per row.
  Map<String, dynamic> _rosterIdentity(
    Map<String, dynamic> row, {
    required String me,
    required String myEmail,
  }) {
    final userId = row['userId']?.toString() ?? '';
    final pendingEmail = (row['pendingEmail'] ?? '').toString();
    final self =
        (userId.isNotEmpty && userId == me) ||
        (pendingEmail.isNotEmpty && pendingEmail.toLowerCase() == myEmail);

    final resolved = <String, dynamic>{'isSelf': self};
    if (row['name'] != null) resolved['name'] = row['name'];
    if (row['email'] != null) resolved['email'] = row['email'];
    // The caller's own name comes from the account the fake authenticated.
    if (self && resolved['name'] == null) {
      resolved['name'] = (authRecord?['name'] ?? '').toString();
    }
    // A pending row identifies its invitee by the address it was sent to.
    if (resolved['email'] == null && pendingEmail.isNotEmpty) {
      resolved['email'] = pendingEmail;
    }
    return resolved;
  }

  http.Response _list(String collection, http.Request request) {
    final query = request.url.queryParameters;
    final page = int.tryParse(query['page'] ?? '1') ?? 1;
    final size = int.tryParse(query['perPage'] ?? '200') ?? 200;
    final all = _applySort(
      _applyFilter(records(collection), query['filter'] ?? ''),
      query['sort'] ?? '',
    );
    final start = (page - 1) * size;
    final slice = start >= all.length
        ? const <Map<String, dynamic>>[]
        : all.sublist(start, (start + size).clamp(0, all.length));
    return json(200, {
      'page': page,
      'perPage': size,
      'totalItems': all.length,
      'totalPages': (all.length / size).ceil(),
      'items': slice,
    });
  }

  /// Honours `sort=<field>` (`-<field>` for descending), which the client relies
  /// on for the two lists whose order is part of their contract: the upcoming
  /// query (`start`, soonest first) and the entity pickers (`name`). Without it
  /// the fake answers in insertion order and a test of that ordering would pass
  /// by coincidence, or fail on a fixture written in a different order.
  ///
  /// Compares as strings, which is exact for the ISO-8601 instants the server
  /// stores and for names.
  static List<Map<String, dynamic>> _applySort(
    List<Map<String, dynamic>> all,
    String sort,
  ) {
    if (sort.isEmpty) return all;
    final descending = sort.startsWith('-');
    final field = descending ? sort.substring(1) : sort;
    final sorted = [...all]
      ..sort((a, b) {
        final result = (a[field] ?? '').toString().compareTo(
          (b[field] ?? '').toString(),
        );
        return descending ? -result : result;
      });
    return sorted;
  }

  /// Honours the two filters this client builds: the half-open month range
  /// `start < "…" && end > "…"`, and the single `end > "…"` the upcoming list
  /// asks with. A fake that ignored them would hand every query the same events
  /// and make the month-cache and upcoming tests pass for no reason.
  static List<Map<String, dynamic>> _applyFilter(
    List<Map<String, dynamic>> all,
    String filter,
  ) {
    final range = RegExp(
      r'start < "([^"]+)" && end > "([^"]+)"',
    ).firstMatch(filter);
    if (range != null) {
      final before = DateTime.parse(range.group(1)!);
      final after = DateTime.parse(range.group(2)!);
      return [
        for (final record in all)
          if (_instant(record['start'])?.isBefore(before) == true &&
              _instant(record['end'])?.isAfter(after) == true)
            record,
      ];
    }
    final notEnded = RegExp(r'^end > "([^"]+)"$').firstMatch(filter);
    if (notEnded != null) {
      final after = DateTime.parse(notEnded.group(1)!);
      return [
        for (final record in all)
          if (_instant(record['end'])?.isAfter(after) == true) record,
      ];
    }
    final series = RegExp(r'^seriesId = "([^"]+)"$').firstMatch(filter);
    if (series != null) {
      final id = series.group(1)!;
      return [
        for (final record in all)
          if (record['seriesId'] == id) record,
      ];
    }
    return all;
  }

  static DateTime? _instant(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  static http.Response json(int status, Object? body) => http.Response(
    body == null ? '' : jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}
