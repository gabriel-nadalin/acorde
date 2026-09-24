import 'identified.dart';

/// A performer record from the PocketBase `performers` collection.
///
/// See [Venue] for why the wire path ([fromMap]) and the cache path
/// ([toJson]/[fromJson]) are separate. [createdBy] is server-managed.
class Performer implements NamedEntity {
  const Performer({
    this.id,
    required this.name,
    this.contact,
    this.type,
    this.createdBy,
  });

  @override
  final String? id;

  @override
  final String name;

  final String? contact;

  /// Free-text kind, e.g. `band` or `solo`.
  final String? type;

  /// User id of the creator, set by the server on create. Provenance only:
  /// nothing authorizes against it.
  final String? createdBy;

  @override
  String get displayName => name;

  /// Fields a client may write. `createdBy` is deliberately absent.
  Map<String, dynamic> toWriteMap() => {
    'name': name,
    'contact': contact,
    'type': type,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'contact': contact,
    'type': type,
    'createdBy': createdBy,
  };

  factory Performer.fromJson(Map<String, dynamic> json) => Performer(
    id: json['id']?.toString(),
    name: json['name']?.toString() ?? '',
    contact: json['contact']?.toString(),
    type: json['type']?.toString(),
    createdBy: json['createdBy']?.toString(),
  );

  factory Performer.fromMap(Map<String, dynamic> map) => Performer(
    id: map['id']?.toString(),
    name: (map['name'] ?? map['title'] ?? '').toString(),
    contact: map['contact']?.toString(),
    type: map['type']?.toString(),
    createdBy: map['createdBy']?.toString(),
  );

  Performer copyWith({
    String? id,
    String? name,
    String? contact,
    String? type,
    String? createdBy,
  }) => Performer(
    id: id ?? this.id,
    name: name ?? this.name,
    contact: contact ?? this.contact,
    type: type ?? this.type,
    createdBy: createdBy ?? this.createdBy,
  );
}
