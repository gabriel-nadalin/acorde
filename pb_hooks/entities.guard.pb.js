/// Server-side guards for writes to `venues`, `performers` and `memberships`.
///
/// One handler covers all three collections because PocketBase extracts each
/// registered handler by its SOURCE TEXT and compiles it into a pooled VM
/// (plugins/jsvm/binds.go): a helper declared at the top level of this file is
/// not in scope when the hook runs. Splitting the three collections across
/// three functions would mean three copies of [toIdList], [quote] and the
/// ownership lookup, and three places for them to drift apart.
///
/// Checks per collection:
///
///   * venues / performers CREATE — `createdBy` records the caller (provenance
///     only), and an ACTIVE manager `memberships` row is written afterwards so
///     the creator shows up in "my venues" without a second request.
///   * venues / performers UPDATE / DELETE — the caller must hold an active
///     manager membership for the record.
///   * venues / performers DELETE — refused while any event still references
///     the record, because deleting it would leave those events pointing at a
///     venue that no longer exists and the client renders that as a blank cell.

///   * memberships CREATE — the caller must administer the target. A
///     `pendingEmail` invite is resolved to a real `userId` as soon as an
///     account exists for that address, but the row STAYS PENDING: matching an
///     address proves the invite exists, not that its target consented to it.
///     That same check is what keeps a user from writing their OWN row: the
///     right to create one comes from already administering the target, so
///     `{userId: me, status: "active"}` for somebody else's entity is a 403
///     before the status is even looked at. Access is REQUESTED through
///     `POST /api/agenda/join`, which writes a `pending`/`request` row and
///     needs no such right, precisely because it grants nothing.
///   * memberships UPDATE — only `role` and `status` may change. Every identity
///     field is forced back to its stored value (see "the re-pointing hole").
///   * memberships UPDATE / DELETE — refused when the write would leave the
///     target with zero active managers, self-removal included.
///   * memberships DELETE — additionally allowed for the member themselves, so
///     somebody can leave a venue they were added to.
///
/// # What `canAdminister` means now
///
/// `role = "manager"` AND `status = "active"` on a membership row, and nothing
/// else. `venues.createdBy` / `performers.createdBy` are provenance: written on
/// create, never consulted for authorization. Before this phase they WERE
/// consulted (`createdBy === me` short-circuited the check), which is why a
/// creator kept rights they had never been granted through a membership and why
/// an entity could sit in the database with no manager row at all — the state
/// migration 1790250200 backfills away.
///
/// # The re-pointing hole this file used to have
///
/// The membership branch read `targetId` from the REQUEST and ran
/// `canAdminister` against it. A manager of venue A could therefore take any
/// membership row they were allowed to update (one belonging to venue B, since
/// the write rule is just "authenticated" and the check ran against the
/// supplied target) and re-point it at A — supplying `targetId = A` was itself
/// the permission. The row then carried B's `userId`: A's manager had stolen
/// B's members. The fix is to resolve the target from the STORED row and to
/// force the identity fields back to their stored values, so a request cannot
/// move a row between targets at all.
///
/// # Why ownership is not in the collection rules
///
/// `venues.createdBy` and `performers.createdBy` ARE plain text ids, not
/// relations, and the membership branch cannot be expressed as a rule at all: a
/// rule can only traverse relations, and `memberships.targetId`/`targetType`
/// are a polymorphic pair of text columns (PocketBase has no polymorphic
/// relation) — which is why the roster is served by `GET /api/agenda/roster`
/// instead. The rules therefore stay permissive at "authenticated" and this
/// handler narrows them.
///
/// # Superusers
///
/// The admin dashboard and `scripts/seed_pocketbase_data.dart` authenticate as
/// a superuser and carry no auth record, so there is no id to attribute a
/// `createdBy` or a membership to. Superusers skip the ownership proof entirely
/// and get no auto-created membership row; the seed script writes the rows it
/// wants explicitly.
///
/// # Ordering traps (verified against 0.38.2)
///
///   * `e.record.id` is EMPTY before `e.next()` on a create, so the
///     `memberships` row can only be written after the create has run.
///   * `$app.save(record)` after `e.next()` works and is committed separately
///     from the request's own transaction, so a failure there is logged rather
///     than turned into a confusing error on an already-successful response.
///   * `$app.findAuthRecordByEmail` THROWS when no account matches, so the
///     `pendingEmail` resolution has to be wrapped.
function entitiesGuard(e) {
  const collectionName = e.collection ? e.collection.name : "";
  if (
    !e.record ||
    (collectionName !== "venues" && collectionName !== "performers" && collectionName !== "memberships")
  ) {
    return e.next();
  }

  const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
  const method = info && info.method ? String(info.method).toUpperCase() : "";
  const isCreate = method === "POST";
  const isDelete = method === "DELETE";
  const isSuperuser = typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();
  const auth = info ? info.auth : null;
  const userId = auth ? String(auth.id) : "";

  /// Which collection/type/role a target id belongs to. `memberships` stores a
  /// `targetType` string; the rest of the file works in collection names.
  function targetCollection(targetType) {
    if (targetType === "venue") return "venues";
    if (targetType === "performer") return "performers";
    return "";
  }

  function targetTypeOf(collection) {
    return collection === "venues" ? "venue" : "performer";
  }

  /// The role for the membership auto-written for a record's creator.
  ///
  /// Always `manager`, for venues and performers alike. The old split (venues
  /// had `managerIds`, performers `memberIds`) leaked into the role values and
  /// gave a performer's creator `role = "member"` — which `canAdminister`
  /// rejects, because administering an entity requires the manager role. Such a
  /// creator held their rights only through the `ownerId === me` shortcut; once
  /// ownership stopped being an authorization source, that shortcut was removed
  /// and the auto-membership below became the creator's ONLY claim on the
  /// record. `member` now means one thing: may book, may not administer.
  function roleFor(_collection) {
    return "manager";
  }

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

  /// Same normalizer as `events.guard.pb.js`: a `json` field arrives as a byte
  /// array on a request record and as JSON text on a record loaded from the DB.
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

  /// `venueId` in an event is a text column that may carry padding or a
  /// JSON-quoted id, so it is read through the same normalizer as `performers`.
  function toSingleId(value) {
    const ids = toIdList(value);
    return ids.length > 0 ? ids[0] : "";
  }

  /// Quotes a value for a PocketBase filter. Ids and emails never legitimately
  /// contain `"` or `\`, and both would break out of the filter string, so they
  /// are stripped rather than escaped.
  function quote(value) {
    return '"' + String(value).replace(/["\\]/g, "") + '"';
  }

  function loadRecord(collection, id) {
    if (!id) return null;
    try {
      return $app.findRecordById(collection, id);
    } catch (_) {
      // Dangling id: nothing to own.
      return null;
    }
  }

  /// Membership lookup. `role` and `status` are optional filters, and every
  /// caller that needs an AUTHORIZATION answer must pass both: `role` is what
  /// separates administering an entity from working for it, and `status` is
  /// what separates an accepted membership from an outstanding invitation.
  function hasMembership(memberId, targetType, targetId, role, status) {
    if (!memberId || !targetId) return false;
    let filter =
      "userId = " + quote(memberId) +
      " && targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId);
    if (role) filter += " && role = " + quote(role);
    if (status) filter += " && status = " + quote(status);
    return $app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
  }

  /// Every membership row for one (member, target) pair, any role and status.
  /// Used where the row already exists and has to be amended rather than
  /// looked up for a yes/no answer.
  function findMembershipRows(memberId, targetType, targetId) {
    if (!memberId || !targetId) return [];
    const filter =
      "userId = " + quote(memberId) +
      " && targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId);
    return $app.findRecordsByFilter("memberships", filter, "", 200, 0);
  }

  /// How many OTHER rows in the target carry the active manager role. `limit: 1`
  /// is enough: every caller only asks whether at least one exists.
  function countActiveManagers(targetType, targetId, exceptId) {
    let filter =
      "targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId) +
      " && role = " + quote("manager") +
      " && status = " + quote("active");
    if (exceptId) filter += " && id != " + quote(exceptId);
    return $app.findRecordsByFilter("memberships", filter, "", 1, 0).length;
  }

  /// True when [memberId] may administer the target: they hold a membership row
  /// with `role = "manager"` AND `status = "active"`.
  ///
  /// Two filters for two different mistakes. The role filter is the difference
  /// between administering an entity and working for it: a `member` — a
  /// performer's band member, say — may book events (`events.guard.pb.js`
  /// accepts any active membership row) but must not rename the act, delete it,
  /// or invite and evict other members. The status filter is the difference
  /// between a question and a membership: a `pending` row means somebody was
  /// named or asked, not that anything was agreed, so it grants nothing. That
  /// covers BOTH directions of `initiatedBy` — an unanswered invitation and an
  /// unapproved join request are the same state here, which is why this filter
  /// is written on `status` alone and never consults `initiatedBy`.
  ///
  /// `createdBy` is deliberately NOT consulted. It is provenance; the phase
  /// that renamed it here removed the shortcut precisely because a creator who
  /// holds no active manager row has no business administering the record. The
  /// target's existence IS still checked, so a row pointing at a deleted venue
  /// cannot be used to invite people to an entity that is gone.
  function canAdminister(memberId, targetType, targetId) {
    if (!memberId || !targetId) return false;
    const collection = targetCollection(targetType);
    if (!collection) return false;
    if (!loadRecord(collection, targetId)) return false;
    return hasMembership(memberId, targetType, targetId, "manager", "active");
  }

  /// Refuses (400) a membership write that would leave the target with ZERO
  /// active managers, which is irreversible from inside the app: nobody left
  /// has the role the roster screen requires, and the entity can only be
  /// rescued by the claim flow, which refuses anything with a manager row.
  ///
  /// [keepsRow] is true only when the write leaves THIS row an active manager —
  /// never for a delete, and not for an update that demotes it or sets it back
  /// to pending.
  function requireManagerLeft(targetType, targetId, rowId, keepsRow) {
    const stored = loadRecord("memberships", rowId);
    if (!stored) return;
    const wasActiveManager =
      String(stored.get("role") || "") === "manager" &&
      String(stored.get("status") || "") === "active";
    if (!wasActiveManager || keepsRow) return;
    if (countActiveManagers(targetType, targetId, rowId) > 0) return;
    throw new BadRequestError(
      "Cannot remove the last manager of this " + targetType +
        ". Add another manager first."
    );
  }

  /// Writes the auto-membership that keeps a freshly created venue/performer
  /// administrable. It MUST be an active manager row: `canAdminister` has no
  /// `createdBy` shortcut any more, so anything less would hand the creator an
  /// entity they cannot rename, delete or invite to.
  function createOwnerMembership(memberId, collection, targetId) {
    if (!memberId || !targetId) return;
    const targetType = targetTypeOf(collection);
    if (hasMembership(memberId, targetType, targetId, "manager", "active")) return;
    // A row for the same person and target may already exist in another role
    // (an invitation written before the entity was created, say). A membership
    // is identified by the (user, target) pair, so that row is promoted instead
    // of gaining a twin.
    const existing = findMembershipRows(memberId, targetType, targetId);
    const membership = existing.length > 0
      ? existing[0]
      : new Record($app.findCollectionByNameOrId("memberships"));
    membership.set("userId", memberId);
    membership.set("targetId", targetId);
    membership.set("targetType", targetType);
    membership.set("role", roleFor(collection));
    membership.set("status", "active");
    if (!String(membership.get("initiatedBy") || "").trim()) {
      membership.set("initiatedBy", "invite");
    }
    $app.save(membership);
  }

  /// True while at least one event still points at [entityId]. Walks every page
  /// because `findRecordsByFilter` is limited by its `limit` argument, and reads
  /// `venueId` through [toSingleId] so a stored value with padding still counts
  /// as a reference.
  function hasReferencingEvents(collection, entityId) {
    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = $app.findRecordsByFilter("events", "", "", pageSize, offset);
      for (const event of page) {
        if (collection === "venues") {
          if (toSingleId(event.get("venueId")) === entityId) return true;
        } else if (toIdList(event.get("performers")).indexOf(entityId) !== -1) {
          return true;
        }
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return false;
  }

  // --- memberships --------------------------------------------------------
  if (collectionName === "memberships") {
    if (isCreate) {
      // On a CREATE the request is the row's whole identity, so the values are
      // read from `e.record` — after each one is validated.
      const createType = String(e.record.get("targetType") || "");
      const createTarget = toSingleId(e.record.get("targetId"));
      if (!targetCollection(createType) || !createTarget) {
        throw new BadRequestError("Membership needs a valid targetId and targetType.");
      }
      if (!isSuperuser && !canAdminister(userId, createType, createTarget)) {
        throw new ForbiddenError("You can only invite people to venues or performers you manage.");
      }

      // That check, and only that check, is what stops a user from writing their
      // OWN membership row: the right to create one is "I already administer
      // this target", and `canAdminister` accepts nothing less than an ACTIVE
      // MANAGER row. Neither `userId: me` nor `status: "active"` in the body is
      // consulted anywhere before it, so a direct POST cannot hand anybody
      // access to an entity they do not already run — there is no ordering in
      // which the requested status is honoured first. A manager adding
      // themselves to a target they already administer is not an escalation:
      // they hold those rights already, and the row is a second row for a pair
      // the roster reads as one person.
      //
      // The path that DOES create a row for a non-manager is
      // `POST /api/agenda/join`, which writes `status: "pending"` and
      // `initiatedBy: "request"` through `$app.save` — behind this hook
      // entirely, so this branch cannot see it, and deliberate: that row grants
      // nothing until a manager of the target approves it through
      // `POST /api/agenda/roster/decide`.

      // An invite may name an existing account (`userId`) or an address that
      // has not signed up yet (`pendingEmail`). Resolving the address now fills
      // `userId` in — which is what lets the invitee act on the row through
      // `POST /api/agenda/invite/respond`, where the identity check is a
      // comparison against it — but it does NOT activate the row. A matching
      // address proves the invite exists; it is not consent, and granting
      // access on a match was the bug this phase fixes. The
      // `onRecordAuthRequest` claim in invites.pb.js stays as the path for
      // accounts created AFTER the invite was written.
      const email = String(e.record.get("pendingEmail") || "").trim();
      if (email) {
        e.record.set("pendingEmail", email);
        let invited = null;
        try {
          invited = $app.findAuthRecordByEmail("users", email);
        } catch (_) {
          // No account for that address yet: the invite stays pending.
        }
        if (invited) e.record.set("userId", String(invited.id));
      }

      if (!String(e.record.get("userId") || "").trim() && !email) {
        throw new BadRequestError("Membership needs either a userId or a pendingEmail.");
      }

      // Pending unless the caller says otherwise, and the only other value
      // accepted is `active` — the case of onboarding somebody who is present
      // and has agreed. Anything else is dropped rather than stored, because a
      // third status would mean "not pending" to this guard and "not active" to
      // every reader, i.e. a row that silently grants nothing.
      e.record.set(
        "status",
        String(e.record.get("status") || "").trim() === "active" ? "active" : "pending"
      );
      // Server-owned, and no client value survives: the direction of the
      // invitation is a fact about who called this endpoint, not something the
      // caller gets to assert. A client-supplied "request" would make a
      // manager's own invite look like the invitee asking to join.
      e.record.set("initiatedBy", "invite");

      // `role` is one of exactly two values, and the stored column is plain
      // text, so nothing else enforces it. A typo ("Managr") or an invented
      // value ("admin") would be stored verbatim and then read as *not a
      // manager* by every consumer — `hasMembership(..., "manager", ...)` and
      // the client's `isManager` both compare against the exact string, so the
      // row would silently behave as a plain member. `/api/agenda/join` already
      // rejects anything else (agenda_routes.pb.js); this is the same rule on
      // the collection path, and an omitted role becomes `member` rather than an
      // empty string that means the same thing less legibly.
      e.record.set(
        "role",
        String(e.record.get("role") || "").trim() === "manager"
          ? "manager"
          : "member"
      );

      // Who invited them, for the invitation email to name — provenance only, and
      // consulted by no authorization check (see venues/performers `createdBy`).
      // Set from the authenticated caller rather than the body, or a client could
      // put somebody else's name on an invitation.
      //
      // Skipped for a superuser: it carries an `_superusers` auth record whose id
      // is not a `users` id, so storing it would name an inviter nobody can
      // resolve. An admin-created invite is therefore anonymous, which is honest.
      if (e.collection.fields.getByName("invitedBy") && auth && !isSuperuser) {
        e.record.set("invitedBy", userId);
      }
      return e.next();
    }

    // Update and delete both resolve the target from the STORED row, never from
    // the request. That is the whole fix for the re-pointing hole described at
    // the top of this file: the request cannot choose which target it is being
    // authorized against.
    const stored = loadRecord("memberships", String(e.record.id || ""));
    const storedType = stored ? String(stored.get("targetType") || "") : "";
    const storedTarget = stored ? toSingleId(stored.get("targetId")) : "";

    if (!isSuperuser) {
      // Someone may remove their OWN membership — that is how a member leaves a
      // venue. Changing a membership is different: letting `userId === me`
      // through an update would let a member promote themselves to manager, so
      // update stays limited to admins of the target.
      const isSelfRemoval =
        isDelete && userId && String(e.record.get("userId") || "") === userId;
      if (!isSelfRemoval && !canAdminister(userId, storedType, storedTarget)) {
        throw new ForbiddenError(
          "You can only change memberships for venues or performers you manage."
        );
      }
    }

    if (!isDelete && stored) {
      // Only `role` and `status` are the caller's to choose. `targetId`,
      // `targetType`, `userId`, `pendingEmail` and `createdBy` describe WHAT the
      // row is: a request that rewrites them hands the row to somebody else or
      // moves it to another target. Copying the stored values back is
      // unconditional rather than keyed off `info.body`, because the body is
      // only one of the ways a value can reach the record.
      for (const identityField of ["targetId", "targetType", "userId", "pendingEmail", "createdBy", "invitedBy"]) {
        if (!e.collection.fields.getByName(identityField)) continue;
        e.record.set(identityField, stored.get(identityField));
      }
    }

    // Runs for superusers too: "an entity always has an active manager" is a
    // property of the DATA, not a permission. A support action that quietly
    // orphans a venue is still a bug, and it is unrecoverable from inside the
    // app — the claim flow refuses any entity that has a manager row.
    requireManagerLeft(
      storedType,
      storedTarget,
      String(e.record.id || ""),
      // A delete never keeps the row; an update keeps it only while it leaves
      // this row an active manager.
      !isDelete &&
        String(e.record.get("role") || "") === "manager" &&
        String(e.record.get("status") || "") === "active"
    );

    return e.next();
  }

  // --- venues / performers ------------------------------------------------
  if (isCreate) {
    // A superuser DOES carry an auth record (the `_superusers` collection), so
    // `auth` is truthy for it — but that id is not a `users` id and would never
    // match `@request.auth.id` on an app request. Writing it into `createdBy`
    // or into a membership row would name a phantom creator nobody can act as,
    // so the whole create step is skipped for superusers (and for anonymous
    // callers, where there is no id at all). The admin dashboard and the seed
    // script therefore produce entities with an empty `createdBy`; they are
    // administrable through the manager rows those tools write explicitly.
    if (auth && !isSuperuser) {
      // Server-owned provenance. It no longer decides anything — the active
      // manager row written below does — but it still must never come from the
      // request body: `createdBy` is a record of who did this, and a client
      // that could set it would be able to blame somebody else for a record.
      e.record.set("createdBy", userId);
    } else {
      e.record.set("createdBy", "");
    }

    const result = e.next();

    if (auth && !isSuperuser) {
      // Deliberately AFTER e.next(): the record id does not exist until the
      // create has run. A failure here is logged, not thrown — the record is
      // already committed at this point and an error would only confuse the
      // response.
      try {
        createOwnerMembership(userId, collectionName, String(e.record.id));
      } catch (err) {
        console.log(
          "entities.guard: could not create the initial membership for " +
            collectionName + " " + e.record.id + ": " + err
        );
      }
    }

    return result;
  }

  if (!isSuperuser) {
    if (!userId) {
      // Anonymous: the collection rules already reject the write.
      return e.next();
    }

    // `canAdminister`, not a bare membership test: belonging to an entity is not
    // the same as administering it. A `member` books events for the venue or
    // performer (`events.guard.pb.js` accepts any membership row) but must not
    // rename, delete or re-roster it. Using the role-blind check here is what
    // made `role` decorative — every member behaved exactly like the owner.
    const targetId = String(e.record.id || "");
    if (!canAdminister(userId, targetTypeOf(collectionName), targetId)) {
      throw new ForbiddenError(
        "You can only change " + collectionName + " you own or manage."
      );
    }

    if (info && info.body && info.body.createdBy !== undefined) {
      // `createdBy` is server-set on create and never client-writable: an
      // update that tries to hand the record to somebody else is rewritten
      // back. Provenance is a fact about the past, so unlike `role`/`status` on
      // a membership there is no legitimate reason for it to change.
      const stored = loadRecord(collectionName, String(e.record.id || ""));
      e.record.set("createdBy", stored ? String(stored.get("createdBy") || "") : "");
    }

    // Reached only by an owner or manager: authorization is decided above, so
    // a non-admin learns nothing about the entity's events.
    if (isDelete && hasReferencingEvents(collectionName, targetId)) {
      throw new BadRequestError(
        collectionName === "venues"
          ? "Venue still has events. Remove or reassign them first."
          : "Performer still has events. Remove or reassign them first."
      );
    }
  }

  return e.next();
}

onRecordCreateRequest(entitiesGuard);
onRecordUpdateRequest(entitiesGuard);
onRecordDeleteRequest(entitiesGuard);
