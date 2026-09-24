/// Reasserts the write rules on `venues`, `performers` and `memberships`.
///
/// # Why this exists as a separate migration
///
/// `1790250000_entity_ownership_and_memberships.js` sets these rules, but its
/// file was edited **after** it had already been applied to a database. PocketBase
/// records an applied migration by filename and never re-runs it, so that
/// database kept the pre-edit state: `venues.createRule` and
/// `performers.createRule` stayed `NULL`, and PocketBase answers a `NULL` create
/// rule with "Only superusers can perform this action." — which makes
/// self-service venue creation, claiming, and the whole ownership model
/// unreachable through the app.
///
/// The schema half of that migration *did* land (the `createdBy` rename, the
/// `status`/`initiatedBy` columns), which is what makes the failure confusing:
/// the database looks migrated. Only the rules lagged.
///
/// Editing an applied migration is never the fix — it cannot reach databases
/// that already ran it, and it silently diverges a fresh install from an
/// upgraded one. Reasserting the target state in a new migration converges
/// both, so this file is deliberately idempotent and safe to run over any
/// database, fresh or stranded.
///
/// `scripts/verify_schema.dart` cannot catch this class of bug on its own: it
/// boots a *fresh* database, where every migration runs in its final form. A
/// stranded database is only visible by comparing a live instance's rules.
migrate((app) => {
  function existingCollection(name) {
    try {
      return app.findCollectionByNameOrId(name);
    } catch (_) {
      return null;
    }
  }

  // The rule an ordinary authenticated user needs, on every write. The hooks
  // narrow it further (ownership, validation); the rule only has to stop it
  // being superuser-only.
  const authenticated = '@request.auth.id != ""';

  for (const name of ["venues", "performers"]) {
    const collection = existingCollection(name);
    if (!collection) continue;
    collection.listRule = authenticated;
    collection.viewRule = authenticated;
    collection.createRule = authenticated;
    collection.updateRule = authenticated;
    collection.deleteRule = authenticated;
    app.save(collection);
  }

  // Memberships stay self-only for reads: my rows, plus invitations addressed to
  // my address. The roster is served by `GET /api/agenda/roster`, because a rule
  // cannot express "every row of an entity I actively manage" — `targetId` is
  // plain text, not a relation.
  const memberships = existingCollection("memberships");
  if (memberships) {
    const selfOnly = "userId = @request.auth.id || pendingEmail = @request.auth.email";
    memberships.listRule = selfOnly;
    memberships.viewRule = selfOnly;
    memberships.createRule = authenticated;
    memberships.updateRule = authenticated;
    memberships.deleteRule = authenticated;
    app.save(memberships);
  }
}, (app) => {
  // No inverse. This migration asserts a target state rather than applying a
  // transition, so there is nothing to undo that would leave the system in a
  // better place: restoring the `NULL` create rules would only make venues and
  // performers unadministrable again for everyone but a superuser, which is the
  // defect it exists to repair. A `down` that reintroduces a known-broken state
  // is worse than one that admits it has none.
  return null;
});
