import 'identified.dart';

/// A venue record from the PocketBase `venues` collection.
///
/// Two serialization paths on purpose:
///
///   * [fromMap] parses a server record and tolerates the flexible encodings
///     PocketBase can return (a missing `name`, an `id`-only stub from
///     `expand`).
///   * [toJson]/[fromJson] are the offline cache, which is written and read by
///     this app only, so they stay strict and canonical.
///
/// [createdBy] is server-managed: it is never sent on write.
class Venue implements NamedEntity {
  const Venue({
    this.id,
    required this.name,
    this.address,
    this.contact,
    this.capacity,
    this.timezone,
    this.createdBy,
  });

  @override
  final String? id;

  @override
  final String name;

  final String? address;
  final String? contact;
  final int? capacity;

  /// The venue's own timezone, as free text (e.g. `Europe/Madrid`) — a note on
  /// the record, not a setting that moves anything.
  ///
  /// Deliberately not read when events are shown: times are stored as UTC
  /// instants and every screen renders them with `toLocal()`, so each viewer
  /// reads the schedule on their own clock. Making this field authoritative
  /// would change what dozens of screens display, and would need a real zone
  /// picker rather than a text box.
  final String? timezone;

  /// User id of the creator, set by the server on create. Provenance only:
  /// nothing authorizes against it.
  final String? createdBy;

  @override
  String get displayName => name;

  /// Fields a client may write. `createdBy` is deliberately absent.
  Map<String, dynamic> toWriteMap() => {
    'name': name,
    'address': address,
    'contact': contact,
    'capacity': capacity,
    'timezone': timezone,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'contact': contact,
    'capacity': capacity,
    'timezone': timezone,
    'createdBy': createdBy,
  };

  factory Venue.fromJson(Map<String, dynamic> json) => Venue(
    id: json['id']?.toString(),
    name: json['name']?.toString() ?? '',
    address: json['address']?.toString(),
    contact: json['contact']?.toString(),
    capacity: (json['capacity'] as num?)?.toInt(),
    timezone: json['timezone']?.toString(),
    createdBy: json['createdBy']?.toString(),
  );

  factory Venue.fromMap(Map<String, dynamic> map) => Venue(
    id: map['id']?.toString(),
    name: (map['name'] ?? map['title'] ?? '').toString(),
    address: map['address']?.toString(),
    contact: map['contact']?.toString(),
    capacity: (map['capacity'] as num?)?.toInt(),
    timezone: map['timezone']?.toString(),
    createdBy: map['createdBy']?.toString(),
  );
}
