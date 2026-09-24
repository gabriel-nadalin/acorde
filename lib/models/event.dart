import 'dart:convert';

import 'identified.dart';
import 'recurrence.dart';

/// An event from the PocketBase `events` collection.
///
/// Two serialization paths on purpose:
///
///   * [toMap] is the wire payload. Dates are written as explicit UTC instants
///     because month queries and the server's overlap check compare them
///     lexically — a naive local time would misalign at month boundaries.
///     `createdBy`, `created` and `updated` are server-managed and never sent.
///   * [toJson]/[fromJson] are the offline cache, read and written by this app
///     only, so they stay strict and canonical.
///
/// [venueName] and [performerNames] are **transient**: they come from
/// PocketBase `expand` or from the venue/performer repositories at render time,
/// and are never persisted. Caching them would freeze display names at the
/// moment an event was fetched and let them go stale behind a renamed venue.
class Event implements Identified {
  Event({
    this.id,
    required this.title,
    this.description,
    required this.start,
    required this.end,
    this.venueId,
    this.performers = const [],
    this.createdBy,
    DateTime? created,
    this.updated,
    this.seriesId,
    this.recurrence,
    this.venueName,
    this.performerNames = const [],
  }) : created = created ?? DateTime.now();

  @override
  final String? id;

  final String title;
  final String? description;
  final DateTime start;
  final DateTime end;

  /// Venue id, stored as text and normalized on the server through the same id
  /// parsing as [performers] so both compare identically.
  final String? venueId;

  final List<String> performers;

  /// Set by the server from the authenticated user on create.
  final String? createdBy;

  /// Server-managed `created` autodate.
  final DateTime created;

  /// Server-managed `updated` autodate; null on a locally built event.
  final DateTime? updated;

  /// Groups the instances of one recurrence; empty for a one-off event.
  final String? seriesId;

  /// The rule this instance was generated from, if any.
  final Recurrence? recurrence;

  /// Transient display name from `expand`; not persisted.
  final String? venueName;

  /// Transient display names from `expand`; not persisted.
  final List<String> performerNames;

  Duration get duration => end.difference(start);

  bool get isSeriesInstance => (seriesId ?? '').isNotEmpty;

  /// Wire payload. Never includes server-managed fields.
  Map<String, dynamic> toMap() => {
    'title': title,
    'description': description,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'venueId': venueId,
    'performers': performers,
    'seriesId': seriesId,
    'recurrence': recurrence?.toJson(),
  };

  /// Offline cache payload: canonical fields only, no `expand` display names.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'venueId': venueId,
    'performers': performers,
    'createdBy': createdBy,
    'created': created.toUtc().toIso8601String(),
    'updated': updated?.toUtc().toIso8601String(),
    'seriesId': seriesId,
    'recurrence': recurrence?.toJson(),
  };

  factory Event.fromJson(Map<String, dynamic> json) => Event(
    id: json['id']?.toString(),
    title: json['title']?.toString() ?? '',
    description: json['description']?.toString(),
    start: _requiredDate(json['start'], 'start'),
    end: _requiredDate(json['end'], 'end'),
    venueId: json['venueId']?.toString(),
    performers: _idList(json['performers']),
    createdBy: json['createdBy']?.toString(),
    created: _optionalDate(json['created']) ?? DateTime.now(),
    updated: _optionalDate(json['updated']),
    seriesId: json['seriesId']?.toString(),
    recurrence: _recurrence(json['recurrence']),
  );

  /// Parses a server record.
  ///
  /// Throws [FormatException] when `start`/`end` are missing or unparseable
  /// instead of substituting `DateTime.now()`: a record with a broken date used
  /// to surface as a plausible-looking booking at the current time, which is
  /// worse than a visible load failure.
  factory Event.fromMap(Map<String, dynamic> data, [String? id]) => Event(
    id: id ?? data['id']?.toString(),
    title: data['title']?.toString() ?? '',
    description: data['description']?.toString(),
    start: _requiredDate(data['start'], 'start'),
    end: _requiredDate(data['end'], 'end'),
    venueId: data['venueId']?.toString(),
    performers: _idList(data['performers']),
    createdBy: data['createdBy']?.toString(),
    created: _optionalDate(data['created']) ?? DateTime.now(),
    updated: _optionalDate(data['updated']),
    seriesId: data['seriesId']?.toString(),
    recurrence: _recurrence(data['recurrence']),
    venueName: _expandedName(data['expand'], 'venueId'),
    performerNames: _expandedNames(data['expand'], 'performers'),
  );

  Event copyWith({
    String? id,
    String? title,
    String? description,
    DateTime? start,
    DateTime? end,
    String? venueId,
    List<String>? performers,
    String? createdBy,
    DateTime? created,
    DateTime? updated,
    String? seriesId,
    Recurrence? recurrence,
    String? venueName,
    List<String>? performerNames,
  }) => Event(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    start: start ?? this.start,
    end: end ?? this.end,
    venueId: venueId ?? this.venueId,
    performers: performers ?? this.performers,
    createdBy: createdBy ?? this.createdBy,
    created: created ?? this.created,
    updated: updated ?? this.updated,
    seriesId: seriesId ?? this.seriesId,
    recurrence: recurrence ?? this.recurrence,
    venueName: venueName ?? this.venueName,
    performerNames: performerNames ?? this.performerNames,
  );

  /// Rebuilds this event for another occurrence of its series, preserving the
  /// wall-clock time and the original duration.
  Event occurrenceAt(DateTime newStart) =>
      copyWith(start: newStart, end: newStart.add(duration));

  static DateTime _requiredDate(dynamic value, String field) {
    final parsed = _optionalDate(value);
    if (parsed == null) {
      throw FormatException(
        'Event.$field is missing or not a valid date: $value',
      );
    }
    return parsed;
  }

  static DateTime? _optionalDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  static Recurrence? _recurrence(dynamic value) {
    if (value == null) return null;
    if (value is Map) {
      return Recurrence.fromJson(Map<String, dynamic>.from(value));
    }
    final text = value.toString().trim();
    if (text.isEmpty || text == 'null') return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Recurrence.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Accepts a real JSON array, a JSON-encoded array string, or a
  /// comma-separated string — the shapes PocketBase can hand back for a `json`
  /// field depending on how the record was loaded.
  static List<String> _idList(dynamic value) {
    if (value == null) return const [];
    final raw = value is List ? value : _decodeArray(value.toString());
    if (raw == null) {
      return [
        for (final part in value.toString().split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ];
    }
    return [
      for (final item in raw)
        if (item != null && item.toString().isNotEmpty) item.toString(),
    ];
  }

  static List<dynamic>? _decodeArray(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String? _expandedName(dynamic expand, String key) {
    if (expand is! Map) return null;
    final value = expand[key];
    if (value is! Map) return null;
    final name = (value['name'] ?? value['title'] ?? '').toString();
    return name.isEmpty ? null : name;
  }

  static List<String> _expandedNames(dynamic expand, String key) {
    if (expand is! Map) return const [];
    final value = expand[key];
    if (value is! List) return const [];
    return [
      for (final item in value)
        if (item is Map && (item['name'] ?? item['title']) != null)
          (item['name'] ?? item['title']).toString(),
    ];
  }
}
