/// Record identity contracts shared by the repositories and the pickers.
///
/// [id] is nullable because an entity exists locally before the server assigns
/// it one; use `id ?? ''` at call sites that need a key.
abstract interface class Identified {
  String? get id;
}

/// An [Identified] record that can be labelled in the UI.
///
/// Repositories are generic over this so pickers, `byId` indexes and display
/// names never have to guess at a record's shape (`name` vs `title` vs `id`).
abstract interface class NamedEntity implements Identified {
  /// Canonical server-side name.
  String get name;

  /// Label to show in lists and chips. Defaults to [name] but leaves room for
  /// a richer label later without touching every call site.
  String get displayName;
}
