#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'pb_harness.dart';

/// Schema drift guard.
///
/// Usage:
///   dart run scripts/verify_schema.dart
///
/// See `pb_harness.dart` for the environment overrides and how the backend is
/// booted. The instance under test is migrated from `pb_migrations/`, so a
/// failure here means the applied migrations and the JSON templates in
/// `scripts/collections/` have diverged.
///
/// # Why this exists
///
/// The deployed schema has three potential sources of truth: `pb_migrations/`
/// (what production runs), `scripts/collections/*.json` (what
/// `create_pocketbase_collections.dart` pushes onto a fresh instance), and
/// whatever the running server actually holds. They drift one field at a time,
/// silently, and the symptom is always far from the cause — a client that stops
/// seeing a field, a rule that lets a write through, an index that quietly
/// stops being created. This script pins them together: it boots the real
/// binary on the real migrations, reads `/api/collections`, and compares that
/// against the templates field by field.
///
/// `/api/collections` is the authority rather than the SQLite file because it
/// reports the schema the SERVER resolved — the same view the rules engine and
/// the API use.
Future<void> main(List<String> args) async {
  final code = await runWithHarness(_run);
  // `dart run` does NOT honour a `Future<int>` returned from `main` (verified
  // against Dart 3.13: a run with failing assertions still exited 0). The exit
  // code must therefore be set explicitly, or CI would go green on a broken
  // schema and a broken guard alike.
  await stdout.flush();
  exit(code);
}

/// The collections the app owns. System collections (`_superusers`, `_mfas`,
/// …) are PocketBase's own and their shape is not this repo's business.
const _appCollections = [
  'users',
  'venues',
  'performers',
  'memberships',
  'events',
];

Future<void> _run(PbHarness h, PbAssertions a) async {
  stdout.writeln('Agenda schema verification — templates vs live schema');
  stdout.writeln('Target: ${h.baseUrl}\n');

  final templateDir = Directory('scripts/collections');
  if (!templateDir.existsSync()) {
    throw StateError(
      'scripts/collections/ not found; run this from the repository root.',
    );
  }

  final token = await h.superuserToken();
  a.check('superuser authenticates', token.isNotEmpty);

  final resp = await h.get('/api/collections?perPage=200', token: token);
  a.check('/api/collections answers 200', resp.status == 200, '$resp');
  final live = <String, Map<String, dynamic>>{
    for (final item in (resp.body['items'] as List? ?? const []))
      (item as Map<String, dynamic>)['name'] as String: item,
  };

  for (final name in _appCollections) {
    final file = File('${templateDir.path}/${name}_collection.json');
    if (!file.existsSync()) {
      a.check('template exists for "$name"', false, file.path);
      continue;
    }

    final decoded = jsonDecode(file.readAsStringSync());
    final template =
        (decoded is List ? decoded.first : decoded) as Map<String, dynamic>;
    final actual = live[name];
    if (actual == null) {
      a.check(
        'collection "$name" exists on the server',
        false,
        'missing from /api/collections',
      );
      continue;
    }

    _compareCollection(a, name, template, actual);
  }

  // Nothing outside the owned list should have appeared: a stray collection in
  // production usually means a half-applied migration that left a scratch table
  // behind (this repo's own history has several: `profiles`, `membershipProbe`).
  final unexpected =
      live.keys
          .where(
            (name) => !name.startsWith('_') && !_appCollections.contains(name),
          )
          .toList()
        ..sort();
  a.check(
    'no unexpected application collections exist',
    unexpected.isEmpty,
    'found: ${unexpected.join(', ')}',
  );
}

void _compareCollection(
  PbAssertions a,
  String name,
  Map<String, dynamic> template,
  Map<String, dynamic> actual,
) {
  // --- rules -------------------------------------------------------------
  for (final rule in [
    'listRule',
    'viewRule',
    'createRule',
    'updateRule',
    'deleteRule',
  ]) {
    final expected = _normalizeRule(template[rule]);
    final observed = _normalizeRule(actual[rule]);
    a.check(
      '$name.$rule matches the template',
      expected == observed,
      'template=$expected live=$observed',
    );
  }

  // --- fields ------------------------------------------------------------
  // Compared as a MAP keyed by field name rather than a list: PocketBase is
  // free to reorder fields (an added field is appended), and an order change is
  // not drift.
  final templateFields = _fieldMap(template['fields']);
  final actualFields = _fieldMap(actual['fields']);

  for (final fieldName in templateFields.keys) {
    final expected = templateFields[fieldName]!;
    final observed = actualFields[fieldName];
    if (observed == null) {
      a.check('$name.$fieldName exists', false, 'missing from the live schema');
      continue;
    }
    a.check(
      '$name.$fieldName has type ${expected['type']}',
      observed['type'] == expected['type'],
      'live=${observed['type']}',
    );
    a.check(
      '$name.$fieldName required=${expected['required']}',
      _truthy(observed['required']) == _truthy(expected['required']),
      'live=${observed['required']}',
    );

    // A select field's allowed values are part of its contract: dropping
    // `performer` from `memberships.targetType` would make every performer
    // membership unwritable.
    if (expected['type'] == 'select') {
      final expectedValues =
          (expected['values'] as List? ?? const [])
              .map((value) => '$value')
              .toList()
            ..sort();
      final observedValues =
          (observed['values'] as List? ?? const [])
              .map((value) => '$value')
              .toList()
            ..sort();
      a.check(
        '$name.$fieldName values match',
        expectedValues.join(',') == observedValues.join(','),
        'template=${expectedValues.join(',')} live=${observedValues.join(',')}',
      );
      a.check(
        '$name.$fieldName maxSelect matches',
        (expected['maxSelect'] ?? 1) == (observed['maxSelect'] ?? 1),
        'live=${observed['maxSelect']}',
      );
    }
  }

  for (final fieldName in actualFields.keys) {
    if (!templateFields.containsKey(fieldName)) {
      a.check(
        '$name.$fieldName is not in the template',
        false,
        'live-only field of type ${actualFields[fieldName]!['type']}',
      );
    }
  }

  // --- indexes -----------------------------------------------------------
  // Index DDL is compared by the set of index NAMES plus the full statement:
  // the name alone would let a wrong column through, and PocketBase rewrites
  // the statement itself when a column is renamed.
  final expectedIndexes =
      (template['indexes'] as List? ?? const [])
          .map((value) => '$value')
          .toList()
        ..sort();
  final observedIndexes =
      (actual['indexes'] as List? ?? const []).map((value) => '$value').toList()
        ..sort();
  a.check(
    '$name indexes match the template',
    expectedIndexes.join('|') == observedIndexes.join('|'),
    'template=$expectedIndexes live=$observedIndexes',
  );
}

Map<String, Map<String, dynamic>> _fieldMap(Object? fields) => {
  for (final field in (fields as List? ?? const []))
    (field as Map<String, dynamic>)['name'] as String: field,
};

/// Rules round-trip through JSON as `null` or a string. The comparison must be
/// textually exact: a rule that merely *looks* equivalent (`!= ''` vs `!= ""`)
/// is still a different rule to PocketBase, and finding that out from a 403 in
/// production is exactly what this script is for.
String _normalizeRule(Object? rule) {
  if (rule == null) return '<null>';
  final text = '$rule'.trim();
  return text.isEmpty ? '<empty>' : text;
}

bool _truthy(Object? value) => value == true;
