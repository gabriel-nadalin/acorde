#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Seed performers and venues into PocketBase.
/// Usage:
///   PB_URL=http://127.0.0.1:8090 PB_ADMIN_EMAIL=admin@example.com PB_ADMIN_PASSWORD=secret \
///     dart run scripts/seed_pocketbase_data.dart
///
/// Optional:
///   PB_COOKIE=.pb_cookie
Future<int> main(List<String> args) async {
  final pbUrl = Platform.environment['PB_URL'] ?? 'http://127.0.0.1:8090';
  final adminEmail = Platform.environment['PB_ADMIN_EMAIL'];
  final adminPass = Platform.environment['PB_ADMIN_PASSWORD'];
  final cookieFilePath = Platform.environment['PB_COOKIE'] ?? '.pb_cookie';

  String? adminToken;
  if (adminEmail != null && adminPass != null) {
    final loginUrl = Uri.parse(
      '$pbUrl/api/collections/_superusers/auth-with-password',
    );
    final resp = await http.post(
      loginUrl,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'identity': adminEmail, 'password': adminPass}),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      try {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        adminToken = body['token'] as String?;
      } catch (_) {}
      if (adminToken != null) {
        stdout.writeln('Login succeeded (token present).');
      }
    } else {
      stderr.writeln('Admin login failed: ${resp.statusCode} ${resp.body}');
    }
  }

  String cookieHeader = '';
  final cookieFile = File(cookieFilePath);
  if (cookieFile.existsSync()) {
    cookieHeader = _cookieHeaderFromNetscape(cookieFile.readAsStringSync());
    if (cookieHeader.isNotEmpty) {
      stdout.writeln('Using cookie file $cookieFilePath for auth.');
    }
  }

  if (adminToken == null && cookieHeader.isEmpty) {
    stderr.writeln('Error: No admin token and no cookie available.');
    stderr.writeln(
      'Provide PB_ADMIN_EMAIL/PB_ADMIN_PASSWORD or create a .pb_cookie file.',
    );
    return 1;
  }

  final client = http.Client();

  /// Re-issues the same request with different headers, so the retry ladder
  /// above does not repeat the method dispatch three times.
  Future<http.Response> repeatRequest(
    String method,
    Uri url,
    Map<String, String> headers,
    String? payload,
  ) async {
    switch (method) {
      case 'GET':
        return client.get(url, headers: headers);
      case 'POST':
        return client.post(url, headers: headers, body: payload);
      case 'PATCH':
        return client.patch(url, headers: headers, body: payload);
      case 'DELETE':
        return client.delete(url, headers: headers);
      default:
        throw Exception('Unsupported method $method');
    }
  }

  Future<http.Response> pbRequest(
    String method,
    Uri url, {
    Map<String, dynamic>? body,
  }) async {
    var headers = <String, String>{'Content-Type': 'application/json'};
    if (cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }
    // `Bearer` is the scheme PocketBase >= 0.23 expects. This used to send
    // `Authorization: Admin <token>` (the pre-0.23 scheme), which 0.38.2 does
    // NOT recognise: the request then arrives unauthenticated, the collection
    // rule rejects the create, and the answer is a 400 "Failed to create
    // record." — not the 401 the retry ladder below keys off. Venues and
    // performers could therefore never be seeded at all, silently, while
    // `users` kept working because its createRule is public.
    if (adminToken != null) {
      headers['Authorization'] = 'Bearer $adminToken';
    }

    final payload = body == null ? null : jsonEncode(body);

    http.Response resp;
    if (method == 'GET') {
      resp = await client.get(url, headers: headers);
    } else if (method == 'POST') {
      resp = await client.post(url, headers: headers, body: payload);
    } else if (method == 'PATCH') {
      resp = await client.patch(url, headers: headers, body: payload);
    } else if (method == 'DELETE') {
      resp = await client.delete(url, headers: headers);
    } else {
      throw Exception('Unsupported method $method');
    }

    // Fallbacks for an instance that wants a different credential shape: drop
    // the cookie and retry, then send the token with no scheme at all.
    // Snapshot into a `final` local rather than asserting on the outer
    // variable. Whether Dart promotes a mutable local that a closure also
    // touches is exactly the kind of thing that changes between SDK versions:
    // the pinned toolchain in CI promotes it here and calls the `!` redundant,
    // while a newer one does not promote it and requires the `!`. A final local
    // reads as non-null on both, so neither has an opinion to offer.
    final token = adminToken;
    if ((resp.statusCode == 401 || resp.statusCode == 403) && token != null) {
      final authHeaders = Map<String, String>.from(headers);
      authHeaders.remove('Cookie');
      resp = await repeatRequest(method, url, authHeaders, payload);

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        authHeaders['Authorization'] = token;
        resp = await repeatRequest(method, url, authHeaders, payload);
      }
    }
    return resp;
  }

  Future<Map<String, dynamic>?> findByName(
    String collection,
    String name,
  ) async {
    final filter = Uri.encodeComponent('name="$name"');
    final url = Uri.parse(
      '$pbUrl/api/collections/$collection/records?perPage=1&filter=$filter',
    );
    final resp = await pbRequest('GET', url);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      if (items is List && items.isNotEmpty) {
        return Map<String, dynamic>.from(items.first as Map);
      }
      return null;
    }
    stderr.writeln(
      'Lookup failed for $collection "$name": ${resp.statusCode} ${resp.body}',
    );
    return null;
  }

  Future<Map<String, dynamic>?> findByField(
    String collection,
    String field,
    String value,
  ) async {
    final filter = Uri.encodeComponent('$field="$value"');
    final url = Uri.parse(
      '$pbUrl/api/collections/$collection/records?perPage=1&filter=$filter',
    );
    final resp = await pbRequest('GET', url);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      if (items is List && items.isNotEmpty) {
        return Map<String, dynamic>.from(items.first as Map);
      }
      return null;
    }
    stderr.writeln(
      'Lookup failed for $collection $field="$value": ${resp.statusCode} ${resp.body}',
    );
    return null;
  }

  Future<String?> createIfMissing(
    String collection,
    Map<String, dynamic> record, {
    String uniqueField = 'name',
  }) async {
    final uniqueValue = record[uniqueField]?.toString() ?? '';
    if (uniqueValue.isEmpty) {
      return null;
    }
    Map<String, dynamic>? existing;
    if (uniqueField == 'name') {
      existing = await findByName(collection, uniqueValue);
    } else {
      existing = await findByField(collection, uniqueField, uniqueValue);
    }
    if (existing != null) {
      stdout.writeln('Skip $collection "$uniqueValue" (already exists).');
      return existing['id']?.toString();
    }

    final url = Uri.parse('$pbUrl/api/collections/$collection/records');
    final resp = await pbRequest('POST', url, body: record);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      stdout.writeln('Created $collection "$uniqueValue" (id=${body['id']}).');
      return body['id']?.toString();
    } else {
      stderr.writeln(
        'Failed to create $collection "$uniqueValue": ${resp.statusCode} ${resp.body}',
      );
      return null;
    }
  }

  /// Records [createdBy] on the entity when it does not have a creator yet.
  ///
  /// `createdBy` is server-set by entities.guard.pb.js and never client-writable
  /// for an app user, but this script is a superuser: the guard lets a superuser
  /// set it so tooling can record provenance on an entity created from the admin
  /// side (where there is no `users` id to attribute it to).
  ///
  /// It is PROVENANCE ONLY — it grants no access, and the manager rows written
  /// by `ensureMembership` are what make the seeded data administrable. It is
  /// still worth writing: the backfill in 1790250200 derives a manager row from
  /// it, and an entity with neither a creator nor a manager can only be rescued
  /// through `POST /api/agenda/claim`.
  Future<void> ensureCreatedBy(
    String collection,
    Map<String, dynamic> record,
    String createdBy,
  ) async {
    if (createdBy.isEmpty) {
      return;
    }
    if ((record['createdBy'] ?? '').toString().isNotEmpty) {
      return;
    }
    final resp = await pbRequest(
      'PATCH',
      Uri.parse('$pbUrl/api/collections/$collection/records/${record['id']}'),
      body: {'createdBy': createdBy},
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      stdout.writeln(
        'Set $collection "${record['name']}" createdBy=$createdBy',
      );
    } else {
      stderr.writeln(
        'Failed to set $collection "${record['name']}" createdBy: '
        '${resp.statusCode} ${resp.body}',
      );
    }
  }

  /// Creates a `memberships` row unless an identical one already exists.
  ///
  /// `createIfMissing` cannot be reused here: it keys off a unique field
  /// (`name`/`email`) and a membership has no such field — its identity is the
  /// (user, target, type) triple. Seeding is expected to be re-runnable, so
  /// without this lookup a second run would double every membership.
  Future<void> ensureMembership({
    required String userId,
    required String targetId,
    required String targetType,
    required String role,
  }) async {
    final filter = Uri.encodeComponent(
      'userId="$userId" && targetId="$targetId" && targetType="$targetType"',
    );
    final lookup = await pbRequest(
      'GET',
      Uri.parse(
        '$pbUrl/api/collections/memberships/records?perPage=1&filter=$filter',
      ),
    );
    if (lookup.statusCode >= 200 && lookup.statusCode < 300) {
      final data = jsonDecode(lookup.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      if (items is List && items.isNotEmpty) {
        stdout.writeln(
          'Skip memberships $targetType "$targetId" for $userId (already exists).',
        );
        return;
      }
    } else {
      stderr.writeln(
        'Membership lookup failed: ${lookup.statusCode} ${lookup.body}',
      );
      return;
    }

    // `status: active` because a seed is data that is already in effect: these
    // rows stand for assignments that exist, not for invitations waiting on an
    // answer. A `pending` row would grant the seeded user nothing — the event
    // guard and `canAdminister` both require `status = "active"` — and the whole
    // dataset would look empty in the app. `initiatedBy` is server-owned
    // (entities.guard.pb.js overwrites it with `invite`), so it is not sent.
    final resp = await pbRequest(
      'POST',
      Uri.parse('$pbUrl/api/collections/memberships/records'),
      body: {
        'userId': userId,
        'targetId': targetId,
        'targetType': targetType,
        'role': role,
        'status': 'active',
      },
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      stdout.writeln(
        'Created membership $targetType "$targetId" for $userId (role=$role).',
      );
    } else {
      stderr.writeln(
        'Failed to create membership $targetType "$targetId" for $userId: '
        '${resp.statusCode} ${resp.body}',
      );
    }
  }

  final performers = <Map<String, dynamic>>[
    {'name': 'Radiohead', 'type': 'band', 'contact': 'radio@head.example'},
    {
      'name': 'Arctic Monkeys',
      'type': 'band',
      'contact': 'monkeys@arctic.example',
    },
    {'name': 'Thom Yorke', 'type': 'solo', 'contact': 'thom.yorke@example.com'},
  ];

  final venues = <Map<String, dynamic>>[
    {
      'name': 'Harbor Hall',
      'address': '12 Dock St',
      'capacity': 300,
      'timezone': 'America/New_York',
      'contact': 'events@harborhall.example',
    },
    {
      'name': 'Bluebird Club',
      'address': '78 Main Ave',
      'capacity': 150,
      'timezone': 'America/Chicago',
      'contact': 'booking@bluebird.example',
    },
    {
      'name': 'Eastside Loft',
      'address': '410 East St',
      'capacity': 220,
      'timezone': 'America/Los_Angeles',
      'contact': 'stage@eastside.example',
    },
  ];

  final users = <Map<String, dynamic>>[
    {
      'name': 'Thom Yorke',
      'email': 'thom.yorke@example.com',
      'password': 'tvbrain123',
    },
    {
      'name': 'Alex Turner',
      'email': 'alex.turner@example.com',
      'password': 'propeller1',
    },
    {
      'name': 'Jonny Greenwood',
      'email': 'jonny.greenwood@example.com',
      'password': 'jonny1234',
    },
  ];

  for (final p in performers) {
    await createIfMissing('performers', p);
  }

  for (final v in venues) {
    await createIfMissing('venues', v);
  }

  // Create users and capture ids directly to avoid an extra lookup
  final usersByEmail = <String, String>{};
  for (final u in users) {
    if (u.containsKey('password') && !u.containsKey('passwordConfirm')) {
      u['passwordConfirm'] = u['password'];
    }
    final email = u['email']?.toString() ?? '';
    final id = await createIfMissing('users', u, uniqueField: 'email');
    if (id != null && email.isNotEmpty) {
      usersByEmail[email] = id;
      stdout.writeln('User $email -> id=$id');
    } else if (email.isNotEmpty) {
      final rec = await findByField('users', 'email', email);
      if (rec != null && rec['id'] != null) {
        usersByEmail[email] = rec['id'].toString();
        stdout.writeln('User $email -> id=${rec['id']} (found)');
      } else {
        stderr.writeln('Could not locate created user for $email');
      }
    }
  }

  // Assign users to performers and venues.
  //
  // This used to write `performers.memberIds` / `venues.managerIds`, two text
  // columns holding a JSON-encoded array of user ids. Those columns are gone:
  // a user's access is now a `memberships` row
  // (`{userId, targetId, targetType, role}`), which is the only shape the
  // guards, the collection rules and the client repositories understand.
  //
  // `createdBy` on the entity IS written here (as a superuser, the only caller
  // allowed to) so the seeded data records a creator. It grants nothing: access
  // comes from the manager rows written below, which is why they carry
  // `status: active`.
  final performerAssignments = <String, List<String>>{
    'Radiohead': ['thom.yorke@example.com', 'jonny.greenwood@example.com'],
    'Arctic Monkeys': ['alex.turner@example.com'],
    'Thom Yorke': ['thom.yorke@example.com'],
  };

  for (final entry in performerAssignments.entries) {
    final name = entry.key;
    final rec = await findByName('performers', name);
    if (rec == null) {
      stderr.writeln('Performer not found: $name');
      continue;
    }
    // Resolve every id first, then record the creator before writing any
    // membership, so a partially-seeded run still leaves provenance behind.
    final memberIds = <String>[];
    for (final email in entry.value) {
      final id = usersByEmail[email];
      if (id == null) {
        stderr.writeln('No user id for $email; skipping for performer $name');
        continue;
      }
      memberIds.add(id);
    }
    if (memberIds.isNotEmpty) {
      await ensureCreatedBy('performers', rec, memberIds.first);
    }
    // The first assigned user is the act's manager; the rest merely work for
    // it. A performer used to be seeded member-only, which was survivable while
    // `createdBy` still granted administration — with that shortcut gone, a
    // performer whose every row is a `member` row has no manager at all: nobody
    // can rename or delete it, and a claim is refused because its recorded
    // creator is somebody else. That is exactly the state migration 1790250200
    // backfills away, so the seed must not re-create it. (A membership is one
    // row per (user, target), so this is a role choice per user rather than an
    // extra row.)
    for (final id in memberIds) {
      await ensureMembership(
        userId: id,
        targetId: rec['id'].toString(),
        targetType: 'performer',
        role: id == memberIds.first ? 'manager' : 'member',
      );
    }
  }

  final venueAssignments = <String, List<String>>{
    'Harbor Hall': ['thom.yorke@example.com'],
    'Bluebird Club': ['alex.turner@example.com'],
    'Eastside Loft': ['thom.yorke@example.com', 'jonny.greenwood@example.com'],
  };

  for (final entry in venueAssignments.entries) {
    final name = entry.key;
    final rec = await findByName('venues', name);
    if (rec == null) {
      stderr.writeln('Venue not found: $name');
      continue;
    }
    // Creator before memberships, for the same reason as above.
    final managerIds = <String>[];
    for (final email in entry.value) {
      final id = usersByEmail[email];
      if (id == null) {
        stderr.writeln('No user id for $email; skipping for venue $name');
        continue;
      }
      managerIds.add(id);
    }
    if (managerIds.isNotEmpty) {
      await ensureCreatedBy('venues', rec, managerIds.first);
    }
    for (final id in managerIds) {
      await ensureMembership(
        userId: id,
        targetId: rec['id'].toString(),
        targetType: 'venue',
        role: 'manager',
      );
    }
  }

  client.close();
  stdout.writeln('Seed complete.');
  return 0;
}

String _cookieHeaderFromNetscape(String content) {
  final lines = LineSplitter.split(content);
  final cookies = <String>[];
  for (final line in lines) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('#')) {
      continue;
    }
    final parts = l.split(RegExp(r'\s+'));
    if (parts.length >= 7) {
      final name = parts[5];
      final value = parts.sublist(6).join(' ');
      cookies.add('$name=$value');
    }
  }
  return cookies.join('; ');
}
