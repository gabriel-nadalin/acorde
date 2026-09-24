/// <reference path="../pb_data/types.d.ts" />
///
/// Ownership moves out of the entity rows and into a `memberships` collection.
///
/// Before this migration a venue carried `managerIds` and a performer carried
/// `memberIds`, both plain TEXT columns holding a JSON-encoded array of user
/// ids. There was no way to answer "which venues does this user manage?" from
/// SQL, there was no place to park an invite for somebody who has not signed up
/// yet, and the two arrays could disagree with each other for the same user.
///
/// `memberships` replaces both with one row per (user, target) link:
///
///   * `userId`        empty while the invite is still pending
///   * `pendingEmail`  set until the invited account first authenticates
///   * `targetId`      the venue/performer id (a plain text id, NOT a relation)
///   * `targetType`    venue | performer
///   * `role`          manager | member
///
/// The entity rows gain a single `ownerId` so the creator's access survives
/// even if every membership row is deleted; the guard accepts either proof.
///
/// # Ordering is load-bearing
///
/// `managerIds`/`memberIds` are the ONLY copy of the existing assignments, so
/// the backfill below must read them before the drop, and the `down` migration
/// must re-materialise them before deleting `ownerId`. Both directions have to
/// keep working on a database that already has the new shape (re-run safety),
/// which is why every step checks whether it has already been applied.
migrate((app) => {
  // Same id decoding rules as the guards: a `text` field holding a JSON array
  // may also arrive comma-separated from older seed data. Declared inline
  // because migrations and hook files do not share a top-level scope.
  function decodeBytes(bytes) {
    let text = "";
    for (let i = 0; i < bytes.length; i++) {
      text += String.fromCharCode(bytes[i]);
    }
    return text;
  }

  function isAllNumbers(list) {
    if (list.length === 0) return false;
    for (let i = 0; i < list.length; i++) {
      if (typeof list[i] !== "number") return false;
    }
    return true;
  }

  function toIdList(value) {
    if (value === null || value === undefined) return [];
    if (Array.isArray(value) && isAllNumbers(value)) {
      value = decodeBytes(value);
    }
    if (Array.isArray(value)) {
      return value.map((v) => String(v)).filter((v) => v.length > 0);
    }
    const text = String(value).trim();
    if (!text) return [];
    try {
      const parsed = JSON.parse(text);
      if (Array.isArray(parsed)) {
        return parsed.map((v) => String(v)).filter((v) => v.length > 0);
      }
    } catch (_) {
      // Not JSON: fall through to the comma-separated form.
    }
    return text.split(",").map((v) => v.trim()).filter((v) => v.length > 0);
  }

  // `findCollectionByNameOrId` throws when the collection is absent, so a
  // half-migrated database is detected instead of blowing up the whole run.
  function existingCollection(name) {
    try {
      return app.findCollectionByNameOrId(name);
    } catch (_) {
      return null;
    }
  }

  // --- 1. memberships ------------------------------------------------------
  let memberships = existingCollection("memberships");
  if (!memberships) {
    memberships = new Collection({
      id: "pbc_memberships",
      type: "base",
      name: "memberships",
      // A membership row is readable by the person it links, by the still
      // unclaimed invitee, and by the owner of the target.
      //
      // The `targetOwnerId` branch is why this collection carries a denormalised
      // copy of the target's owner instead of just reading `targetId`: rules can
      // only traverse RELATIONS, and `targetId`/`targetType` are a polymorphic
      // pair of plain text columns (PocketBase has no polymorphic relation), so
      // `targetId.ownerId ?= @request.auth.id` fails with "not a valid
      // relation". Without it the team-management screen could list exactly one
      // row — the viewer's own — and an owner would be unable to see the people
      // they had invited, which is the entire point of the feature.
      //
      // Writes stay at "authenticated" and entities.guard.pb.js narrows them,
      // because the same `targetId` limitation makes the create/delete proofs
      // inexpressible as a rule.
      listRule: "userId = @request.auth.id || pendingEmail = @request.auth.email || targetOwnerId = @request.auth.id",
      viewRule: "userId = @request.auth.id || pendingEmail = @request.auth.email || targetOwnerId = @request.auth.id",
      createRule: "@request.auth.id != ''",
      updateRule: "@request.auth.id != ''",
      deleteRule: "@request.auth.id != ''",
      fields: [
        {
          autogeneratePattern: "[a-z0-9]{15}",
          id: "text_id_memberships_0001",
          max: 15,
          min: 15,
          name: "id",
          pattern: "^[a-z0-9]+$",
          primaryKey: true,
          required: true,
          system: true,
          type: "text",
        },
        { id: "text_userId_memberships_0001", name: "userId", type: "text" },
        { id: "text_pendingEmail_memberships_0001", name: "pendingEmail", type: "text" },
        { id: "text_targetId_memberships_0001", name: "targetId", type: "text" },
        // Server-set from the target record's `ownerId` on create; never
        // client-writable, or a user could grant themselves read access to
        // every membership row of any target.
        { id: "text_targetOwnerId_memberships_0001", name: "targetOwnerId", type: "text" },
        {
          id: "select_targetType_memberships_0001",
          name: "targetType",
          type: "select",
          values: ["venue", "performer"],
          maxSelect: 1,
        },
        { id: "text_role_memberships_0001", name: "role", type: "text" },
      ],
      indexes: [
        "CREATE INDEX `idx_memberships_userId` ON `memberships` (userId)",
        "CREATE INDEX `idx_memberships_targetId` ON `memberships` (targetId)",
        "CREATE INDEX `idx_memberships_pendingEmail` ON `memberships` (pendingEmail)",
        "CREATE INDEX `idx_memberships_targetOwnerId` ON `memberships` (targetOwnerId)",
      ],
    });
    app.save(memberships);
  } else if (!memberships.fields.getByName("targetOwnerId")) {
    // A database migrated by an earlier revision of this file already has the
    // collection but not this field. `migrate` only runs an unapplied file
    // once, so a re-run here is the only chance to converge such a database on
    // the current shape.
    memberships.fields.add(new TextField({ id: "text_targetOwnerId_memberships_0001", name: "targetOwnerId", type: "text" }));
    memberships.addIndex("idx_memberships_targetOwnerId", false, "targetOwnerId", "");
    app.save(memberships);
  }

  /// Existing membership rows for a target, so a re-run cannot duplicate them.
  function membershipExists(userId, targetType, targetId) {
    const filter =
      'userId = "' + userId + '" && targetType = "' + targetType + '" && targetId = "' + targetId + '"';
    return app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
  }

  function insertMembership(userId, targetType, targetId, role) {
    if (!userId || !targetId) return;
    if (membershipExists(userId, targetType, targetId)) return;
    const record = new Record(app.findCollectionByNameOrId("memberships"));
    record.set("userId", userId);
    record.set("targetId", targetId);
    record.set("targetType", targetType);
    record.set("role", role);
    app.save(record);
  }

  // --- 2. backfill BEFORE dropping the legacy columns ----------------------
  const legacy = [
    { collection: "venues", field: "managerIds", targetType: "venue", role: "manager" },
    { collection: "performers", field: "memberIds", targetType: "performer", role: "member" },
  ];

  /// The first legacy user id seen per record. Existing rows have no recorded
  /// creator, and the first manager/member is the closest thing to one; without
  /// it a row whose list is empty would become editable by nobody once the
  /// legacy column is gone.
  const ownerByTarget = {};

  for (const spec of legacy) {
    const collection = existingCollection(spec.collection);
    if (!collection || !collection.fields.getByName(spec.field)) continue;

    // Paged so the migration is safe on a database far larger than the
    // ~20 records currently shipped.
    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = app.findRecordsByFilter(spec.collection, "", "", pageSize, offset);
      for (const record of page) {
        const userIds = toIdList(record.get(spec.field));
        for (const userId of userIds) {
          insertMembership(userId, spec.targetType, record.id, spec.role);
        }
        if (userIds.length > 0 && !ownerByTarget[record.id]) {
          ownerByTarget[record.id] = userIds[0];
        }
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
  }

  // --- 3. ownerId + name index, then drop the legacy columns ---------------
  for (const spec of legacy) {
    const collection = existingCollection(spec.collection);
    if (!collection) continue;

    collection.fields.add(new TextField({ id: "text_ownerId_" + spec.collection + "_0001", name: "ownerId", type: "text" }));
    collection.fields.removeByName(spec.field);
    collection.addIndex("idx_" + spec.collection + "_name", false, "name", "");
    // Persist the column BEFORE the record loop: `app.save(record)` reloads the
    // collection from the DB, so a record cannot carry a field the collection
    // does not have yet.
    app.save(collection);

    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = app.findRecordsByFilter(spec.collection, "", "", pageSize, offset);
      for (const record of page) {
        const ownerId = ownerByTarget[record.id];
        if (ownerId) {
          record.set("ownerId", ownerId);
          app.save(record);
          // The memberships above were written before this owner existed, so
          // their denormalised `targetOwnerId` is still empty and the owner
          // would not be able to list their own team. Patch them now, in the
          // same pass, so a migrated database behaves like a fresh one.
          const memberships = app.findRecordsByFilter(
            "memberships",
            'targetId = "' + record.id + '"',
            "",
            pageSize,
            0
          );
          for (const membership of memberships) {
            membership.set("targetOwnerId", ownerId);
            app.save(membership);
          }
        }
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
  }

  // --- 4. rules ------------------------------------------------------------
  //
  // The shipped snapshot left create/update/delete as NULL for both
  // collections, so a regular authenticated user got "Only superusers can
  // perform this action." instead of the hook's verdict — which made the whole
  // ownership model unreachable through the app. Section 1 of the contract puts
  // all five rules at "authenticated" and lets entities.guard.pb.js narrow
  // writes, exactly like `events` already does.
  for (const name of ["venues", "performers", "memberships"]) {
    const collection = existingCollection(name);
    if (!collection) continue;

    if (name === "memberships") {
      // A membership row is readable only by the person it links, the pending
      // invitee, or the target's owner; those read rules are set where the
      // collection is created above and are reasserted here so a re-run over an
      // older database converges on the same shape.
      collection.listRule = "userId = @request.auth.id || pendingEmail = @request.auth.email || targetOwnerId = @request.auth.id";
      collection.viewRule = collection.listRule;
      collection.createRule = '@request.auth.id != ""';
      collection.updateRule = '@request.auth.id != ""';
      collection.deleteRule = '@request.auth.id != ""';
    } else {
      collection.listRule = '@request.auth.id != ""';
      collection.viewRule = '@request.auth.id != ""';
      collection.createRule = '@request.auth.id != ""';
      collection.updateRule = '@request.auth.id != ""';
      collection.deleteRule = '@request.auth.id != ""';
    }
    app.save(collection);
  }
}, (app) => {
  function toIdList(value) {
    if (value === null || value === undefined) return [];
    const text = String(value).trim();
    if (!text) return [];
    try {
      const parsed = JSON.parse(text);
      if (Array.isArray(parsed)) {
        return parsed.map((v) => String(v)).filter((v) => v.length > 0);
      }
    } catch (_) {
      // Not JSON: fall through to the comma-separated form.
    }
    return text.split(",").map((v) => v.trim()).filter((v) => v.length > 0);
  }

  function existing(name) {
    try {
      return app.findCollectionByNameOrId(name);
    } catch (_) {
      return null;
    }
  }

  /// Re-materialise the legacy user-id arrays from `memberships` so no
  /// assignment is lost on rollback.
  const specs = [
    { collection: "venues", field: "managerIds", targetType: "venue" },
    { collection: "performers", field: "memberIds", targetType: "performer" },
  ];

  for (const spec of specs) {
    const collection = existing(spec.collection);
    if (!collection) continue;

    const byTarget = {};
    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const filter = 'targetType = "' + spec.targetType + '"';
      const page = app.findRecordsByFilter("memberships", filter, "", pageSize, offset);
      for (const membership of page) {
        const targetId = String(membership.get("targetId") || "");
        const userId = String(membership.get("userId") || "");
        if (!targetId || !userId) continue;
        if (!byTarget[targetId]) byTarget[targetId] = [];
        if (byTarget[targetId].indexOf(userId) === -1) byTarget[targetId].push(userId);
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }

    const legacyField = new TextField({ id: "text_" + spec.field + "_" + spec.collection + "_0001", name: spec.field, type: "text" });
    collection.fields.add(legacyField);
    collection.removeIndex("idx_" + spec.collection + "_name");
    // Persist the column BEFORE the record loop: `app.save(record)` reloads the
    // collection from the DB, so a record cannot carry a field the collection
    // does not have yet.
    app.save(collection);

    let recordOffset = 0;
    for (;;) {
      const page = app.findRecordsByFilter(spec.collection, "", "", pageSize, recordOffset);
      for (const record of page) {
        const users = byTarget[record.id] || [];
        // The previous shape stored a JSON-encoded array in a text column.
        record.set(spec.field, JSON.stringify(users));
        app.save(record);
      }
      if (page.length < pageSize) break;
      recordOffset += pageSize;
    }

    collection.fields.removeByName("ownerId");
    // Back to the shipped snapshot's shape: read-only for authenticated users,
    // writes admin-only.
    collection.createRule = null;
    collection.updateRule = null;
    collection.deleteRule = null;
    app.save(collection);
  }

  const memberships = existing("memberships");
  if (memberships) app.delete(memberships);
})
