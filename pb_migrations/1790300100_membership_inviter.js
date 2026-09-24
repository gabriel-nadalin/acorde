/// <reference path="../pb_data/types.d.ts" />
///
/// Records WHO invited somebody, so the invitation email can name them.
///
/// # Why this needs a column
///
/// A `memberships` row already records the direction of the invitation
/// (`initiatedBy`) but not the person behind it: for an invite, `userId` is the
/// INVITEE (empty until they sign up), and every other column describes the
/// target. So `pb_hooks/mail.pb.js` could say "you have been invited" but not by
/// whom — the inviter was nowhere in the system to look up, and the address was
/// the only thing that could be inferred from the caller.
///
/// That is worth a column rather than a guess. "Ana invited you to Eastside Loft"
/// is the difference between a message somebody acts on and one that reads like
/// a mailing list; and inference was not available anyway, because the hook that
/// sends the mail runs after the row is committed, where `e.auth` is gone.
///
/// # Provenance only
///
/// Exactly like `venues.createdBy` / `performers.createdBy`: written on create by
/// the server from the authenticated caller, forced back to its stored value on
/// every update, and consulted by NOTHING for authorization. It is a record of who
/// did this, not a source of rights — reading it for a permission check is the
/// mistake that let a creator keep rights they had never been granted (see
/// `1790250200`).
///
/// Left empty when the caller is a superuser or anonymous. A superuser carries an
/// `_superusers` auth record whose id is not a `users` id, so writing it would
/// name a creator nobody can resolve — the same trap `createdBy` avoids by
/// skipping superusers entirely.
///
/// No backfill is possible or attempted: the inviter of a row written before this
/// migration was never recorded anywhere, and inventing one would be worse than
/// an empty value that the mail hook already handles.
migrate(
  (app) => {
    let memberships = null;
    try {
      memberships = app.findCollectionByNameOrId("memberships");
    } catch (_) {
      // No memberships collection: nothing to add the column to.
      return;
    }
    if (memberships.fields.getByName("invitedBy")) return;

    memberships.fields.add(
      new TextField({
        id: "text_invitedBy_memberships_0001",
        name: "invitedBy",
        type: "text",
      })
    );
    app.save(memberships);
  },
  (app) => {
    // Dropping the column discards facts that cannot be recovered (see above),
    // so the down leaves it in place rather than destroying data to satisfy a
    // rollback nobody needs. An extra empty column is harmless.
    return null;
  }
);
