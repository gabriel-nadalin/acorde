import 'identified.dart';

/// What a [Membership] grants access to.
enum TargetType { venue, performer }

String targetTypeWire(TargetType type) => switch (type) {
  TargetType.venue => 'venue',
  TargetType.performer => 'performer',
};

TargetType parseTargetType(String? value) =>
    value == 'performer' ? TargetType.performer : TargetType.venue;

/// Whether a membership grants access or is still an unanswered invitation.
///
/// Separate from "does it have a `userId`", which used to stand in for this and
/// cannot express a join request: that has a known account and still must not
/// grant anything until somebody approves it. Consent lives here.
enum MembershipStatus { pending, active }

String membershipStatusWire(MembershipStatus status) => switch (status) {
  MembershipStatus.pending => 'pending',
  MembershipStatus.active => 'active',
};

MembershipStatus parseMembershipStatus(String? value) =>
    value == 'active' ? MembershipStatus.active : MembershipStatus.pending;

/// A manager/member link between a user and a venue or performer.
///
/// Membership lives in its own collection rather than as an id list on the
/// venue/performer record, so "who manages what" is not readable by every
/// account. An invitation that has not been claimed yet has an empty [userId]
/// and carries [pendingEmail] instead; the server fills [userId] the first time
/// that email authenticates.
class Membership implements Identified {
  const Membership({
    this.id,
    this.userId,
    this.pendingEmail,
    required this.targetId,
    required this.targetType,
    this.role = 'manager',
    this.status = MembershipStatus.pending,
    this.initiatedBy = 'invite',
    this.name = '',
    this.email = '',
    this.isSelf = false,
    this.requestedByMe = false,
  });

  @override
  final String? id;

  /// Claimed user id, or empty while the invitation is unanswered.
  final String? userId;

  /// Email the invitation was addressed to, until it is claimed.
  final String? pendingEmail;

  final String targetId;
  final TargetType targetType;

  /// `manager` or `member`. A manager administers the entity; a member may book
  /// it and nothing more.
  final String role;

  final MembershipStatus status;

  /// `invite` (a manager asked them) or `request` (they asked to join).
  final String initiatedBy;

  /// Display name resolved by the roster endpoint. Empty on rows read straight
  /// from the collection, which carry ids only.
  final String name;

  /// Email resolved by the roster endpoint; falls back to [pendingEmail].
  final String email;

  /// True when the row belongs to the signed-in account.
  final bool isSelf;

  /// True when the row is the signed-in account's own outstanding join
  /// request, as resolved by the roster endpoint.
  ///
  /// Distinct from [initiatedByRequest], which says the row *is* a request:
  /// this says it is *mine*. A manager deciding on somebody else's request
  /// needs [initiatedByRequest], and the requester looking at their own row
  /// needs this. It cannot be derived from [userId] alone on a roster row,
  /// because a manager reads rows for users they do not otherwise know.
  ///
  /// Only the roster endpoint sets it. Rows read straight from the collection
  /// leave it false; the collection's self-only rule means those rows are
  /// already the caller's, so `userId == me` answers the same question there.
  final bool requestedByMe;

  bool get isActive => status == MembershipStatus.active;
  bool get isPending => status == MembershipStatus.pending;
  bool get isManager => role == 'manager';

  /// True when this row is somebody asking to join rather than a manager
  /// inviting them. The two are decided by different people (the invitee vs a
  /// manager), so the UI has to tell them apart.
  bool get initiatedByRequest => initiatedBy == 'request';

  factory Membership.fromMap(Map<String, dynamic> map) => Membership(
    id: map['id']?.toString(),
    userId: map['userId']?.toString(),
    pendingEmail: map['pendingEmail']?.toString(),
    targetId: map['targetId']?.toString() ?? '',
    targetType: parseTargetType(map['targetType']?.toString()),
    role: map['role']?.toString() ?? 'manager',
    status: parseMembershipStatus(map['status']?.toString()),
    initiatedBy: map['initiatedBy']?.toString() ?? 'invite',
    name: (map['name'] ?? '').toString(),
    email: (map['email'] ?? '').toString(),
    isSelf: map['isSelf'] == true,
    requestedByMe: map['requestedByMe'] == true,
  );

  /// Serialises the row for the offline mirror.
  ///
  /// [isSelf] is deliberately absent: it is a verdict the server gives for one
  /// caller at one moment, and the mirror outlives a sign-out/sign-in cycle, so
  /// persisting it would let the next account inherit the previous one's "this
  /// row is mine". [requestedByMe] *is* kept: it is part of what the roster
  /// said about the row, and a row restored from the mirror has to keep meaning
  /// what it meant when it was fetched — one that came back without the flag
  /// would quietly turn the caller's own request into somebody else's. The
  /// mirror is a fallback throughout: the next successful load replaces the
  /// whole row.
  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'pendingEmail': pendingEmail,
    'targetId': targetId,
    'targetType': targetTypeWire(targetType),
    'role': role,
    'status': membershipStatusWire(status),
    'initiatedBy': initiatedBy,
    'requestedByMe': requestedByMe,
  };

  factory Membership.fromJson(Map<String, dynamic> json) =>
      Membership.fromMap(json);
}
