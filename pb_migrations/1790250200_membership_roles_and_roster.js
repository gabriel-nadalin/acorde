/// <reference path="../pb_data/types.d.ts" />
///
/// Phase 2 of the ownership refactor: authorization becomes **purely**
/// membership-role based, and the entity row keeps only provenance.
///
/// Three things change together, and they only make sense together:
///
///   1. `ownerId` -> `createdBy` on `venues` / `performers`. The column is no
///      longer consulted for authorization anywhere (see
///      `entities.guard.pb.js`); it records who created the row and nothing
///      else. The rename is DONE LAST among the identity work but FIRST here
///      because backfill 2 below reads the new name.
///   2. `memberships` gains `status` (pending | active) and `initiatedBy`
///      (invite | request), and loses `targetOwnerId`. The denormalised owner
///      only existed so `memberships.listRule` could grant a target's owner the
///      roster — a rule can only traverse relations, and `targetId` is plain
///      text. The roster now comes from `GET /api/agenda/roster`, which can ask
///      the question the rule cannot: "does an ACTIVE MANAGER row for this
///      target name me?". The read rules therefore shrink to self-only
///      (`userId` = me, or `pendingEmail` = my address).
///   3. `canAdminister` loses its `createdBy` shortcut and requires
///      `role = manager && status = active`.
///
/// # Why backfill 2 exists
///
/// Removing the `createdBy` shortcut is the point of the phase, and it is also
/// what makes every entity created before the role fix unadministerable: they
/// were reachable through `ownerId === me`, so nothing ever forced an *active
/// manager* row to exist for them. Without backfill 2, the moment the shortcut
/// is gone, the owner of such a venue cannot rename it, delete it, invite
/// anybody, or read its roster. Backfill 2 writes the missing row.
///
/// # Ordering is load-bearing
///
///   * The rename runs before backfill 2, which reads `createdBy`.
///   * Backfill 1 (statuses) runs before backfill 2: backfill 2 asks whether an
///     *active* manager row exists, and pre-existing manager rows only become
///     active in backfill 1. Run them the other way round and every entity
///     whose manager row was written before this migration gets a second,
///     duplicate manager row.
///   * Both backfills run before `targetOwnerId` is dropped, so a run that
///     fails part way leaves a database that can still be read by the old
///     rules. Every step is guarded by a field check, so re-running is safe.
migrate((app) => {
  // Declared inline: migrations and hook files do not share a top-level scope.
  function existingCollection(name) {
    try {
      return app.findCollectionByNameOrId(name);
    } catch (_) {
      // A half-migrated database is detected instead of blowing up the run.
      return null;
    }
  }

  /// Quotes a value for a PocketBase filter. Ids and emails never legitimately
  /// contain `"` or `\`, and both would break out of the filter string.
  function quote(value) {
    return '"' + String(value).replace(/["\\]/g, "") + '"';
  }

  // --- 1. ownerId -> createdBy on the entities -----------------------------
  //
  // PocketBase tracks a field by its ID, not by its name, and renames the
  // SQLite column when the Field's name changes — so the values travel with the
  // column. That is an assumption about the engine, so it is PROVEN rather than
  // trusted: `scripts/guard_test.dart` populates a database in the old shape,
  // applies this migration, and checks the values landed on the right rows.
  // (It passes; the values survive. A copy-then-drop would be the fallback if
  // it did not.)
  for (const name of ["venues", "performers"]) {
    const collection = existingCollection(name);
    if (!collection) continue;
    const field = collection.fields.getByName("ownerId");
    if (field) {
      field.name = "createdBy";
      app.save(collection);
    }
  }

  // --- 2. memberships: add status + initiatedBy ---------------------------
  let memberships = existingCollection("memberships");
  if (memberships) {
    // A select rather than a plain text column: the two values are a closed
    // set, and a typo'd `"activ"` would silently mean "not active" everywhere
    // (the guards, the roster endpoint, the client's `MembershipStatus`) with
    // no error at write time.
    if (!memberships.fields.getByName("status")) {
      memberships.fields.add(new SelectField({
        id: "select_status_memberships_0001",
        name: "status",
        type: "select",
        values: ["pending", "active"],
        maxSelect: 1,
      }));
      memberships.addIndex("idx_memberships_status", false, "status", "");
    }
    if (!memberships.fields.getByName("initiatedBy")) {
      memberships.fields.add(new SelectField({
        id: "select_initiatedBy_memberships_0001",
        name: "initiatedBy",
        type: "select",
        values: ["invite", "request"],
        maxSelect: 1,
      }));
    }
    // The columns must exist in the DB before any record below carries them:
    // `app.save(record)` reloads the collection, which has to know the fields.
    app.save(memberships);
  }

  /// True when [targetType]/[targetId] already has an ACTIVE MANAGER, i.e. an
  /// entity that survives the removal of the `createdBy` shortcut.
  function hasActiveManager(targetType, targetId) {
    const filter =
      "targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId) +
      " && role = " + quote("manager") +
      " && status = " + quote("active");
    return app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
  }

  function findMembership(userId, targetType, targetId) {
    const filter =
      "userId = " + quote(userId) +
      " && targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId);
    const rows = app.findRecordsByFilter("memberships", filter, "", 1, 0);
    return rows.length > 0 ? rows[0] : null;
  }

  /// Guarantees an active manager row for [userId] on the target.
  ///
  /// When the user already holds a row for the target that row is PROMOTED
  /// rather than joined by a second one. The contract says "insert one", but
  /// inserting is wrong here: every performer creator from the previous phase
  /// holds `role = "member"` (performers used to be seeded with `memberIds`,
  /// which mapped to the member role), and a membership's identity is the
  /// (user, target) pair. A blind insert would leave two rows for one person —
  /// one of them bookable, one administrative — and the roster would list them
  /// twice.
  function ensureActiveManager(userId, targetType, targetId) {
    const existing = findMembership(userId, targetType, targetId);
    if (existing) {
      if (
        String(existing.get("role") || "") !== "manager" ||
        String(existing.get("status") || "") !== "active"
      ) {
        existing.set("role", "manager");
        existing.set("status", "active");
        app.save(existing);
      }
      return;
    }
    const record = new Record(app.findCollectionByNameOrId("memberships"));
    record.set("userId", userId);
    record.set("targetId", targetId);
    record.set("targetType", targetType);
    record.set("role", "manager");
    record.set("status", "active");
    record.set("initiatedBy", "invite");
    app.save(record);
  }

  // --- 3. backfill 1: every existing row gets a status --------------------
  //
  // A row that names an account was a real, working membership; a row that only
  // carries `pendingEmail` was an invitation nobody had accepted yet. Making
  // the invitation active would be the consent bug the phase exists to fix, so
  // the distinction is preserved rather than flattened to "active".
  if (memberships) {
    const pageSize = 200;
    let offset = 0;
    for (;;) {
      // No filter, and no value in the filter changes while we walk, so rows
      // stay put and the offset may advance normally.
      const page = app.findRecordsByFilter("memberships", "", "", pageSize, offset);
      for (const membership of page) {
        const userId = String(membership.get("userId") || "").trim();
        membership.set("status", userId ? "active" : "pending");
        if (!String(membership.get("initiatedBy") || "").trim()) {
          membership.set("initiatedBy", "invite");
        }
        app.save(membership);
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
  }

  // --- 4. backfill 2: keep old entities administrable ---------------------
  //
  // Only rows with a `createdBy` are touched: an entity with no recorded
  // creator has no candidate for the manager role, and inventing one from the
  // remaining membership rows would hand administration to somebody the
  // previous phase deliberately did not put in charge. Such an entity stays
  // claimable through `POST /api/agenda/claim` (see agenda_routes.pb.js).
  for (const spec of [
    { collection: "venues", targetType: "venue" },
    { collection: "performers", targetType: "performer" },
  ]) {
    const collection = existingCollection(spec.collection);
    if (!collection || !collection.fields.getByName("createdBy")) continue;

    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = app.findRecordsByFilter(spec.collection, "", "", pageSize, offset);
      for (const record of page) {
        const creator = String(record.get("createdBy") || "").trim();
        if (!creator) continue;
        if (hasActiveManager(spec.targetType, record.id)) continue;
        ensureActiveManager(creator, spec.targetType, record.id);
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
  }

  // --- 5. drop targetOwnerId and narrow the read rules --------------------
  //
  // Dropped last: it is the only column backfills 1-4 do not need but which the
  // OLD read rule does, so a failure above leaves a working database behind.
  memberships = existingCollection("memberships");
  if (memberships) {
    if (memberships.fields.getByName("targetOwnerId")) {
      memberships.fields.removeByName("targetOwnerId");
    }
    memberships.removeIndex("idx_memberships_targetOwnerId");
    // Self-only. A rule cannot ask "does an active manager row exist for this
    // target" — that is what `GET /api/agenda/roster` is for — so the
    // collection exposes only rows that are the caller's own business: their
    // memberships and the invitations addressed to their address.
    memberships.listRule =
      "userId = @request.auth.id || pendingEmail = @request.auth.email";
    memberships.viewRule = memberships.listRule;
    app.save(memberships);
  }
}, (app) => {
  function existingCollection(name) {
    try {
      return app.findCollectionByNameOrId(name);
    } catch (_) {
      return null;
    }
  }

  function quote(value) {
    return '"' + String(value).replace(/["\\]/g, "") + '"';
  }

  // Rollback. The order is the mirror image of `up`: everything that needs
  // `createdBy` reads it BEFORE the rename back to `ownerId`, and the fields
  // the previous phase knows nothing about are dropped last.
  //
  // What this deliberately does NOT do is remove the manager rows backfill 2
  // wrote. They are indistinguishable from rows an operator created by hand,
  // and deleting a membership somebody may now be relying on is a worse
  // outcome than leaving an extra admin row behind.

  // --- 1. restore targetOwnerId and fill it from the entities -------------
  const memberships = existingCollection("memberships");
  if (memberships) {
    if (!memberships.fields.getByName("targetOwnerId")) {
      memberships.fields.add(new TextField({
        id: "text_targetOwnerId_memberships_0001",
        name: "targetOwnerId",
        type: "text",
      }));
      memberships.addIndex("idx_memberships_targetOwnerId", false, "targetOwnerId", "");
      app.save(memberships);
    }

    // `createdBy` still holds the owner at this point — the rename below runs
    // last. Read it per row rather than caching the two entity collections:
    // `app.findRecordById` goes through the record cache anyway, and a target
    // deleted mid-rollback must not abort the whole migration.
    function createdByOf(targetType, targetId) {
      const collection = targetType === "venue" ? "venues" : "performers";
      try {
        const target = app.findRecordById(collection, targetId);
        return String(target.get("createdBy") || "");
      } catch (_) {
        return "";
      }
    }

    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = app.findRecordsByFilter("memberships", "", "", pageSize, offset);
      for (const membership of page) {
        const owner = createdByOf(
          String(membership.get("targetType") || ""),
          String(membership.get("targetId") || "")
        );
        membership.set("targetOwnerId", owner);
        app.save(membership);
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }

    // --- 2. old rules, then drop the two new fields -----------------------
    memberships.listRule =
      "userId = @request.auth.id || pendingEmail = @request.auth.email || targetOwnerId = @request.auth.id";
    memberships.viewRule = memberships.listRule;
    memberships.removeIndex("idx_memberships_status");
    memberships.fields.removeByName("status");
    memberships.fields.removeByName("initiatedBy");
    app.save(memberships);
  }

  // --- 3. createdBy -> ownerId --------------------------------------------
  for (const name of ["venues", "performers"]) {
    const collection = existingCollection(name);
    if (!collection) continue;
    const field = collection.fields.getByName("createdBy");
    if (field) {
      field.name = "ownerId";
      app.save(collection);
    }
  }
})
