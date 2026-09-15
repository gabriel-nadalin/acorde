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
    final loginUrl = Uri.parse('$pbUrl/api/collections/_superusers/auth-with-password');
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
      if (adminToken != null) print('Login succeeded (token present).');
    } else {
      stderr.writeln('Admin login failed: ${resp.statusCode} ${resp.body}');
    }
  }

  String cookieHeader = '';
  final cookieFile = File(cookieFilePath);
  if (cookieFile.existsSync()) {
    cookieHeader = _cookieHeaderFromNetscape(cookieFile.readAsStringSync());
    if (cookieHeader.isNotEmpty) print('Using cookie file $cookieFilePath for auth.');
  }

  if (adminToken == null && cookieHeader.isEmpty) {
    stderr.writeln('Error: No admin token and no cookie available.');
    stderr.writeln('Provide PB_ADMIN_EMAIL/PB_ADMIN_PASSWORD or create a .pb_cookie file.');
    return 1;
  }

  final client = http.Client();

  Future<http.Response> pbRequest(String method, Uri url, {Map<String, dynamic>? body}) async {
    var headers = <String, String>{'Content-Type': 'application/json'};
    if (cookieHeader.isNotEmpty) headers['Cookie'] = cookieHeader;
    if (adminToken != null) headers['Authorization'] = 'Admin $adminToken';

    final payload = body == null ? null : jsonEncode(body);

    http.Response resp;
    if (method == 'GET') {
      resp = await client.get(url, headers: headers);
    } else if (method == 'POST') resp = await client.post(url, headers: headers, body: payload);
    else if (method == 'PATCH') resp = await client.patch(url, headers: headers, body: payload);
    else throw Exception('Unsupported method $method');

    if ((resp.statusCode == 401 || resp.statusCode == 403) && adminToken != null) {
      final authHeaders = Map<String, String>.from(headers);
      authHeaders.remove('Cookie');
      authHeaders['Authorization'] = 'Bearer $adminToken';
      if (method == 'GET') {
        resp = await client.get(url, headers: authHeaders);
      } else if (method == 'POST') resp = await client.post(url, headers: authHeaders, body: payload);
      else if (method == 'PATCH') resp = await client.patch(url, headers: authHeaders, body: payload);

      if (resp.statusCode == 401 || resp.statusCode == 403) {
        authHeaders['Authorization'] = adminToken!;
        if (method == 'GET') {
          resp = await client.get(url, headers: authHeaders);
        } else if (method == 'POST') resp = await client.post(url, headers: authHeaders, body: payload);
        else if (method == 'PATCH') resp = await client.patch(url, headers: authHeaders, body: payload);
      }
    }
    return resp;
  }

  Future<Map<String, dynamic>?> findByName(String collection, String name) async {
    final filter = Uri.encodeComponent('name="$name"');
    final url = Uri.parse('$pbUrl/api/collections/$collection/records?perPage=1&filter=$filter');
    final resp = await pbRequest('GET', url);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      if (items is List && items.isNotEmpty) {
        return Map<String, dynamic>.from(items.first as Map);
      }
      return null;
    }
    stderr.writeln('Lookup failed for $collection "$name": ${resp.statusCode} ${resp.body}');
    return null;
  }

  Future<Map<String, dynamic>?> findByField(String collection, String field, String value) async {
    final filter = Uri.encodeComponent('$field="$value"');
    final url = Uri.parse('$pbUrl/api/collections/$collection/records?perPage=1&filter=$filter');
    final resp = await pbRequest('GET', url);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = data['items'] ?? data['data'] ?? [];
      if (items is List && items.isNotEmpty) {
        return Map<String, dynamic>.from(items.first as Map);
      }
      return null;
    }
    stderr.writeln('Lookup failed for $collection $field="$value": ${resp.statusCode} ${resp.body}');
    return null;
  }

  Future<String?> createIfMissing(String collection, Map<String, dynamic> record, {String uniqueField = 'name'}) async {
    final uniqueValue = record[uniqueField]?.toString() ?? '';
    if (uniqueValue.isEmpty) return null;
    Map<String, dynamic>? existing;
    if (uniqueField == 'name') {
      existing = await findByName(collection, uniqueValue);
    } else {
      existing = await findByField(collection, uniqueField, uniqueValue);
    }
    if (existing != null) {
      print('Skip $collection "$uniqueValue" (already exists).');
      return existing['id']?.toString();
    }

    final url = Uri.parse('$pbUrl/api/collections/$collection/records');
    final resp = await pbRequest('POST', url, body: record);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      print('Created $collection "$uniqueValue" (id=${body['id']}).');
      return body['id']?.toString();
    } else {
      stderr.writeln('Failed to create $collection "$uniqueValue": ${resp.statusCode} ${resp.body}');
      return null;
    }
  }

  Future<bool> updateRecord(String collection, String id, Map<String, dynamic> updates) async {
    final url = Uri.parse('$pbUrl/api/collections/$collection/records/$id');
    final resp = await pbRequest('PATCH', url, body: updates);
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      print('Updated $collection id=$id');
      return true;
    }
    stderr.writeln('Failed to update $collection id=$id: ${resp.statusCode} ${resp.body}');
    return false;
  }

  final performers = <Map<String, dynamic>>[
    {
      'name': 'Radiohead',
      'type': 'band',
      'memberIds': '',
      'contact': 'radio@head.example',
    },
    {
      'name': 'Arctic Monkeys',
      'type': 'band',
      'memberIds': '',
      'contact': 'monkeys@arctic.example',
    },
    {
      'name': 'Thom Yorke',
      'type': 'solo',
      'memberIds': '',
      'contact': 'thom.yorke@example.com',
    },
  ];

  final venues = <Map<String, dynamic>>[
    {
      'name': 'Harbor Hall',
      'address': '12 Dock St',
      'capacity': 300,
      'timezone': 'America/New_York',
      'contact': 'events@harborhall.example',
      'ownerId': '',
      'managerIds': '',
    },
    {
      'name': 'Bluebird Club',
      'address': '78 Main Ave',
      'capacity': 150,
      'timezone': 'America/Chicago',
      'contact': 'booking@bluebird.example',
      'ownerId': '',
      'managerIds': '',
    },
    {
      'name': 'Eastside Loft',
      'address': '410 East St',
      'capacity': 220,
      'timezone': 'America/Los_Angeles',
      'contact': 'stage@eastside.example',
      'ownerId': '',
      'managerIds': '',
    },
  ];

  final users = <Map<String, dynamic>>[
    {
      'name': 'Thom Yorke',
      'email': 'thom.yorke@example.com',
      'password': 'tvbrain123'
    },
    {
      'name': 'Alex Turner',
      'email': 'alex.turner@example.com',
      'password': 'propeller1'
    },
    {
      'name': 'Jonny Greenwood',
      'email': 'jonny.greenwood@example.com',
      'password': 'jonny1234'
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
      print('User $email -> id=$id');
    } else if (email.isNotEmpty) {
      final rec = await findByField('users', 'email', email);
      if (rec != null && rec['id'] != null) {
        usersByEmail[email] = rec['id'].toString();
        print('User $email -> id=${rec['id']} (found)');
      } else {
        stderr.writeln('Could not locate created user for $email');
      }
    }
  }

  // Assign users to performers and venues
  final performerAssignments = <String, List<String>>{
    'Radiohead': ['thom.yorke@example.com', 'jonny.greenwood@example.com'],
    'Arctic Monkeys': ['alex.turner@example.com'],
    'Thom Yorke': ['thom.yorke@example.com'],
  };

  for (final entry in performerAssignments.entries) {
    final name = entry.key;
    final emails = entry.value;
    final rec = await findByName('performers', name);
    if (rec == null) {
      stderr.writeln('Performer not found: $name');
      continue;
    }
    final ids = <String>[];
    for (final e in emails) {
      final id = usersByEmail[e];
      if (id != null) {
        ids.add(id);
      } else {
        stderr.writeln('No user id for $e; skipping for performer $name');
      }
    }
    await updateRecord('performers', rec['id'].toString(), {'memberIds': jsonEncode(ids)});
  }

  final venueAssignments = <String, List<String>>{
    'Harbor Hall': ['thom.yorke@example.com'],
    'Bluebird Club': ['alex.turner@example.com'],
    'Eastside Loft': ['thom.yorke@example.com', 'jonny.greenwood@example.com'],
  };

  for (final entry in venueAssignments.entries) {
    final name = entry.key;
    final emails = entry.value;
    final rec = await findByName('venues', name);
    if (rec == null) {
      stderr.writeln('Venue not found: $name');
      continue;
    }
    final ids = <String>[];
    for (final e in emails) {
      final id = usersByEmail[e];
      if (id != null) {
        ids.add(id);
      } else {
        stderr.writeln('No user id for $e; skipping for venue $name');
      }
    }
    await updateRecord('venues', rec['id'].toString(), {'managerIds': jsonEncode(ids)});
  }

  client.close();
  print('Seed complete.');
  return 0;
}

String _cookieHeaderFromNetscape(String content) {
  final lines = LineSplitter.split(content);
  final cookies = <String>[];
  for (final line in lines) {
    final l = line.trim();
    if (l.isEmpty || l.startsWith('#')) continue;
    final parts = l.split(RegExp(r'\s+'));
    if (parts.length >= 7) {
      final name = parts[5];
      final value = parts.sublist(6).join(' ');
      cookies.add('$name=$value');
    }
  }
  return cookies.join('; ');
}
