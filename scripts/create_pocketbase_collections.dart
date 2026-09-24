#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Script to create or update PocketBase collections from JSON templates.
/// Usage:
///   PB_URL=http://127.0.0.1:8090 PB_ADMIN_EMAIL=admin@example.com PB_ADMIN_PASSWORD=secret \
///     dart run scripts/create_pocketbase_collections.dart scripts/collections/*.json

Future<int> main(List<String> args) async {
  final pbUrl = Platform.environment['PB_URL'] ?? 'http://127.0.0.1:8090';
  final adminEmail = Platform.environment['PB_ADMIN_EMAIL'];
  final adminPass = Platform.environment['PB_ADMIN_PASSWORD'];
  final cookieFilePath = Platform.environment['PB_COOKIE'] ?? '.pb_cookie';

  final collectionFiles = args.isNotEmpty
      ? args.map((a) => File(a)).where((f) => f.existsSync()).toList()
      : Directory('scripts/collections').existsSync()
      ? Directory('scripts/collections')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
      : [];

  if (collectionFiles.isEmpty) {
    stdout.writeln(
      'No collection JSON files found in scripts/collections/. Nothing to do.',
    );
    return 0;
  }

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
        final body = jsonDecode(resp.body);
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

  Future<http.Response> pbRequest(
    String method,
    Uri url, {
    String? body,
  }) async {
    var headers = <String, String>{'Content-Type': 'application/json'};
    if (cookieHeader.isNotEmpty) {
      headers['Cookie'] = cookieHeader;
    }

    http.Response resp;
    if (method == 'GET') {
      resp = await client.get(url, headers: headers);
    } else if (method == 'POST') {
      resp = await client.post(url, headers: headers, body: body);
    } else if (method == 'PATCH') {
      resp = await client.patch(url, headers: headers, body: body);
    } else {
      throw Exception('Unsupported method $method');
    }

    if (resp.statusCode == 401 && adminToken != null) {
      final authHeaders = Map<String, String>.from(headers);
      authHeaders.remove('Cookie');
      authHeaders['Authorization'] = 'Bearer $adminToken';
      if (method == 'GET') {
        resp = await client.get(url, headers: authHeaders);
      } else if (method == 'POST') {
        resp = await client.post(url, headers: authHeaders, body: body);
      } else if (method == 'PATCH') {
        resp = await client.patch(url, headers: authHeaders, body: body);
      }

      if (resp.statusCode == 401) {
        authHeaders['Authorization'] = adminToken!;
        if (method == 'GET') {
          resp = await client.get(url, headers: authHeaders);
        } else if (method == 'POST') {
          resp = await client.post(url, headers: authHeaders, body: body);
        } else if (method == 'PATCH') {
          resp = await client.patch(url, headers: authHeaders, body: body);
        }
      }
    }
    return resp;
  }

  for (final file in collectionFiles) {
    stdout.writeln('Processing ${file.path}...');
    final content = file.readAsStringSync();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      stderr.writeln('Failed to parse JSON for ${file.path}: $e');
      return 1;
    }

    // Normalize to a list of collection definitions (each a Map)
    final defs = <Map<String, dynamic>>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          defs.add(Map<String, dynamic>.from(item));
        } else {
          stderr.writeln(
            'Invalid item in array in ${file.path}; expected object.',
          );
          return 1;
        }
      }
    } else if (decoded is Map<String, dynamic>) {
      defs.add(Map<String, dynamic>.from(decoded));
    } else {
      stderr.writeln(
        'Unsupported JSON root type in ${file.path}; expected object or array.',
      );
      return 1;
    }

    for (final def in defs) {
      // normalize unsupported field types (e.g. `datetime` -> PocketBase `date`)
      void normalizeTypes(dynamic node) {
        if (node is Map<String, dynamic>) {
          if (node.containsKey('type') && node['type'] == 'datetime') {
            node['type'] = 'date';
            if (!node.containsKey('options')) node['options'] = {};
          }
          for (final k in node.keys.toList()) {
            normalizeTypes(node[k]);
          }
        } else if (node is List) {
          for (final e in node) {
            normalizeTypes(e);
          }
        }
      }

      normalizeTypes(def);

      final name = (def['name'] as String?) ?? '';
      if (name.isEmpty) {
        stderr.writeln('Missing name in definition from ${file.path}');
        return 1;
      }

      final bodyString = jsonEncode(def);
      final createUrl = Uri.parse('$pbUrl/api/collections');
      var resp = await pbRequest('POST', createUrl, body: bodyString);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        try {
          final body = jsonDecode(resp.body);
          stdout.writeln('Created collection id: ${body['id']}');
        } catch (_) {
          stdout.writeln(
            'Created collection (non-json response): ${resp.body}',
          );
        }
        continue;
      }

      if (resp.statusCode == 400 ||
          resp.body.contains('validation_collection_name_exists')) {
        stdout.writeln(
          'Collection "$name" already exists; fetching existing info...',
        );
        final getUrl = Uri.parse('$pbUrl/api/collections/$name');
        resp = await pbRequest('GET', getUrl);
        if (!(resp.statusCode >= 200 && resp.statusCode < 300)) {
          stderr.writeln(
            'Failed to fetch existing collection "$name": ${resp.statusCode} ${resp.body}',
          );
          return 1;
        }
        String id;
        try {
          final body = jsonDecode(resp.body);
          id = body['id'] as String? ?? '';
        } catch (e) {
          stderr.writeln('Failed to parse existing collection response: $e');
          return 1;
        }
        if (id.isEmpty) {
          stderr.writeln('Existing collection has no id');
          return 1;
        }
        final patchUrl = Uri.parse('$pbUrl/api/collections/$id');
        resp = await pbRequest('PATCH', patchUrl, body: bodyString);
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          try {
            final body = jsonDecode(resp.body);
            stdout.writeln('Updated collection id: ${body['id']}');
          } catch (_) {
            stdout.writeln(
              'Updated collection (non-json response): ${resp.body}',
            );
          }
          continue;
        } else {
          stderr.writeln(
            'Failed to update collection "$name": ${resp.statusCode} ${resp.body}',
          );
          return 1;
        }
      } else {
        stderr.writeln(
          'Failed to create collection "$name": ${resp.statusCode} ${resp.body}',
        );
        return 1;
      }
    }
  }

  client.close();
  stdout.writeln('All done.');
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
