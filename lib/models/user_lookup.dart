/// The deliberately minimal answer to "does this email have an account?".
///
/// Only ever two fields. The invite form asks this *before* sending an
/// invitation, to tell a manager "they already have an account, they will be
/// asked to accept" apart from "no account yet" — and both of those are
/// answers about the caller's own invitee, whom the caller already named.
///
/// It carries no email, no id and no other account field, because the question
/// is the only thing the endpoint is allowed to answer. The caller supplied the
/// address; echoing it back would prove nothing and hide the fact that a wider
/// response would turn the endpoint into an enumeration oracle over the whole
/// user table. Adding a field here is a deliberate act, not a convenience.
class UserLookup {
  const UserLookup({this.exists = false, this.name = ''});

  /// Whether an account with the looked-up address exists.
  final bool exists;

  /// The account's display name, or empty. Never the email.
  final String name;

  factory UserLookup.fromMap(Map<String, dynamic> map) => UserLookup(
    exists: map['exists'] == true,
    name: (map['name'] ?? '').toString(),
  );

  factory UserLookup.fromJson(Map<String, dynamic> json) =>
      UserLookup.fromMap(json);

  Map<String, dynamic> toJson() => {'exists': exists, 'name': name};
}
