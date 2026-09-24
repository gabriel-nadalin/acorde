/// Server-side guards for writes to the `events` collection.
///
/// Checks run on every write, in this order:
///
///   1. Not the `events` collection — pass straight through.
///   2. On CREATE, `createdBy` is forced to the authenticated user id, or
///      cleared for a superuser/anonymous caller. An UPDATE that tries to
///      reassign authorship is rewritten back to the stored value.
///   3. Shape (create/update only, skipped for DELETE): `start` and `end` are
///      present with `start < end`, and the event is booked somewhere — a venue
///      or at least one performer. A superuser may omit the booking but not the
///      dates.
///   4. Ownership — the caller manages the venue, manages one of the
///      performers, or created the event.
///   5. Double-booking (create/update only) — a time range overlapping an
///      existing event that shares the same venue or any performer is rejected.
///
/// Steps 3 and 5 describe what a WRITE must produce, so they do not run on
/// DELETE: a delete writes nothing, and applying the booking rule there would
/// make a row stored before the rule existed impossible to remove. Ownership
/// always runs.
///
/// # Why ownership lives here and not in the collection rules
///
/// `users.createRule` is "" (public signup), so "any authenticated user" no
/// longer restricts anything — anyone can mint an account. Writes therefore
/// need an ownership proof, but `events.venueId` and `events.performers` are
/// plain text/json fields holding ids, NOT relations. PocketBase rules can
/// only traverse relations, so `venueId.createdBy ?= @request.auth.id` fails
/// with `field "venueId" is not a valid relation`. The collection rules stay
/// at "authenticated" and this handler narrows them.
///
/// Ownership is now an ACTIVE row in `memberships` (`{userId, targetId,
/// targetType, status}`), which replaced the old `venues.managerIds` /
/// `performers.memberIds` text arrays. `createdBy === me` is accepted as well,
/// so a user who created an event keeps access to it even after being removed
/// from the membership list — for an EXISTING record only (see the ownership
/// section, and the note on why the same fallback must not cover creates).
///
/// Read access stays open to any authenticated user on purpose: browsing
/// venues and their events is the point of public signup.
///
/// Superusers (admin dashboard, seed scripts) bypass the ownership check so
/// tooling keeps working.
///
/// # PocketBase runtime requirements (easy to break)
///
///   * Hook files are only loaded when they match `^.*(.pb.js|.pb.ts)$`.
///   * Registration extracts each handler by its SOURCE TEXT and compiles it
///     into a pooled VM (plugins/jsvm/binds.go), so every helper must be
///     declared INSIDE the handler body — top-level declarations are not in
///     scope when the hook runs. That is also why every check shares one
///     handler: a second registered function would need its own copy of
///     [toIdList] and of the date helpers, and a second copy is how the bugs
///     below creep back in.
///   * Request-level hooks must call `e.next()` on every non-rejecting path,
///     otherwise the hook chain stops and the request is answered empty.
///   * `e.record.id` is EMPTY before `e.next()` on a create (verified against
///     0.38.2). Anything that needs the new id has to run after `e.next()`.
///
/// # The json-field trap this file exists to avoid
///
/// PocketBase hands a `json` field back in two different shapes:
///
///   * On a REQUEST record (`e.record`) it is a raw byte array ([]uint8), so
///     `["iobkj6cjof1vz32"]` arrives as the character codes of that JSON text.
///   * On a record loaded from the DB (`$app.findRecordsByFilter`) it is the
///     JSON string itself.
///
/// `Array.isArray()` is TRUE for the byte array, so the obvious
/// `if (Array.isArray(v)) return v.map(String)` turns every id into a digit
/// character. Comparing those character sets "works" whenever two events share
/// an id — by accident, via overlapping characters — and produces false
/// conflicts between unrelated performers, silently rejecting valid bookings.
/// [toIdList] decodes the byte array first so both shapes yield real ids.
///
/// # The date-filter trap this file exists to avoid
///
/// A `date` column is compared as TEXT in PocketBase's own normalised form
/// `YYYY-MM-DD HH:MM:SS.sssZ` — a SPACE, not the `T` of RFC3339. Submitting an
/// RFC3339 value into the filter (or building one with `Date#toISOString()`)
/// matches nothing at all, because `' '` sorts before `'T'`: the venue overlap
/// filter then silently returns zero rows and the double-booking guard becomes
/// a no-op instead of erroring. [toFilterDate] always converts to the space
/// form before the filter text is built. `e.record.get("start")` already
/// arrives normalised, so `String(...)` is safe — `.toISOString()` is not.
///
/// # The self-overlap and paging traps
///
/// The overlap query excludes the record being written (`id != this`), so an
/// update that keeps an event's own slot while changing its title is allowed,
/// while any second event in that slot is still rejected.
///
/// `$app.findRecordsByFilter` is capped by its `limit` argument, so a single
/// call with `limit: 200` would stop seeing conflicts past the 200th
/// overlapping row. [findAllConflicts] therefore walks every page until a
/// short page comes back.
function eventsGuard(e) {
  // Not our collection: let the request continue untouched.
  if (!e.record || !e.collection || e.collection.name !== "events") {
    return e.next();
  }

  // `requestInfo` is a function on this build; accept the property form too so
  // an upgrade can't silently drop the guard.
  const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
  const method = info && info.method ? String(info.method).toUpperCase() : "";
  // Only an explicit DELETE skips the overlap check. Anything else — including
  // an unrecognised method — still runs it, so a detection failure can never
  // silently disable the double-booking guard.
  const isDelete = method === "DELETE";
  const isCreate = method === "POST";
  const checkOverlap = !isDelete;

  /// Byte array -> JSON text (see the json-field trap above).
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

  /// Normalises a json-encoded id list into real ids, whatever shape it
  /// arrives in: raw byte array, JSON string, JS array, or comma-separated.
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

  /// `venueId` is a single id in a text column, but it must be read through the
  /// SAME normalizer as `performers`: a client that sends `" venue1 "` (padding
  /// is invisible in a JSON viewer) or `'["venue1"]'` would otherwise never
  /// match the clean id in the membership lookup and never collide in the
  /// overlap check — a silent bypass of both.
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

  /// Milliseconds since the epoch for a PocketBase-normalised timestamp
  /// (`YYYY-MM-DD HH:MM:SS.sssZ`) or an RFC3339 one. NaN when the text is in no
  /// shape we understand — callers treat that as "missing".
  function toEpochMillis(value) {
    if (value === null || value === undefined) return NaN;
    const text = String(value).trim();
    if (!text) return NaN;
    const match = text.match(
      /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.(\d{1,3}))?(Z|[+-]\d{2}:?\d{2})?$/
    );
    if (!match) return NaN;
    const offset = match[8] && match[8] !== "Z" ? match[8].replace(":", "") : "";
    const millis = Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]),
      Number(match[5]),
      match[6] ? Number(match[6]) : 0,
      match[7] ? Number(match[7].padEnd(3, "0")) : 0
    );
    const shift = offset
      ? (offset.charAt(0) === "-" ? 1 : -1) *
        (Number(offset.slice(1, 3)) * 3600000 + Number(offset.slice(3, 5)) * 60000)
      : 0;
    return millis + shift;
  }

  /// The value to embed in a `date` filter: PocketBase compares the column as
  /// text in its space-separated form (see the date-filter trap above).
  function toFilterDate(value) {
    const millis = toEpochMillis(value);
    if (isNaN(millis)) return "";
    return new Date(millis).toISOString().replace("T", " ");
  }

  /// True when [userId] holds an **active** membership row for the given
  /// target, **whatever its role**.
  ///
  /// Booking is the job, so a performer's `member` may create their events just
  /// as a venue's `manager` may: the role gates administering the entity
  /// (rename/delete/invite, enforced in `entities.guard.pb.js`), not working
  /// for it. Adding a role filter here would lock band members out of their own
  /// calendar.
  ///
  /// The STATUS filter is a different matter, and it is the whole point of it
  /// being here: a `pending` row is an invitation nobody has answered, and
  /// treating it as access would mean an invitee silently gains the ability to
  /// book the venue the moment a manager types their address — the consent bug
  /// Phase 2 fixes. `entities.guard.pb.js` applies the same filter to
  /// `canAdminister`; this side is the one that decides whether they may write
  /// to the calendar at all.
  function hasMembership(memberId, targetType, targetId) {
    if (!memberId || !targetId) return false;
    const filter =
      "userId = " + quote(memberId) +
      " && targetType = " + quote(targetType) +
      " && targetId = " + quote(targetId) +
      " && status = " + quote("active");
    return $app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
  }

  /// Every event overlapping `[startText, endText)` except [excludeId], walking
  /// all pages so a large collection cannot hide a conflict past the first
  /// `limit` rows.
  function findAllConflicts(startText, endText, excludeId) {
    const pageSize = 200;
    let filter = "start < " + quote(endText) + " && end > " + quote(startText);
    if (excludeId) filter += " && id != " + quote(excludeId);

    const found = [];
    let offset = 0;
    for (;;) {
      const page = $app.findRecordsByFilter("events", filter, "", pageSize, offset);
      for (const record of page) found.push(record);
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return found;
  }

  /// performerId -> the user ids who are part of that act, over ACTIVE rows only.
  ///
  /// "Who plays in what" is already in the data rather than stored a second
  /// time: a performer's members ARE the people in the act (the edit screen
  /// calls the section "Members" and the invite "Invite member"). So two acts
  /// that share a member share a person, and a solo booking collides with the
  /// band that person also plays in — which is the whole point: Thom Yorke
  /// solo cannot be booked at the same hour as Radiohead.
  ///
  /// Derived rather than added as a `lineup` field on purpose. A stored copy
  /// would drift from the roster the UI maintains, and the roster is what the
  /// app actually asks the user to keep up to date. The cost is that an
  /// association which is not a membership is invisible here; the trade is
  /// documented in DEVELOPMENT.md under "Booking collisions".
  ///
  /// `status = active` is load-bearing: an unclaimed invitation means the person
  /// has not accepted, so counting it would invent collisions between acts whose
  /// only "link" is an unanswered invite.
  ///
  /// Paged, because `findRecordsByFilter` is bounded by its argument and a
  /// membership that is not read is a collision that is not caught.
  function activePerformerMembers() {
    const index = {};
    const pageSize = 500;
    let offset = 0;
    for (;;) {
      const page = $app.findRecordsByFilter(
        "memberships",
        "targetType = " + quote("performer") + " && status = " + quote("active"),
        "",
        pageSize,
        offset
      );
      for (const row of page) {
        const performerId = String(row.get("targetId") || "");
        const memberId = String(row.get("userId") || "");
        // A row with no user id is an unclaimed invitation: nobody yet.
        if (!performerId || !memberId) continue;
        if (!index[performerId]) index[performerId] = [];
        if (index[performerId].indexOf(memberId) === -1) index[performerId].push(memberId);
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return index;
  }

  /// Every person in any of [performerIds], deduplicated.
  function peopleIn(performerIds, memberIndex) {
    const people = [];
    for (const id of performerIds) {
      const members = memberIndex[id];
      if (!members) continue;
      for (const memberId of members) {
        if (people.indexOf(memberId) === -1) people.push(memberId);
      }
    }
    return people;
  }

  /// Display name of a performer, falling back to the id. Only ever called on
  /// the failure path, so the extra lookup costs nothing in the happy case.
  function performerName(id) {
    try {
      const record = $app.findRecordById("performers", id);
      return record ? String(record.get("name") || id) : id;
    } catch (_) {
      return id;
    }
  }

  /// Display name of a user account, falling back to their email, then the id.
  function personName(id) {
    try {
      const record = $app.findRecordById("users", id);
      if (!record) return id;
      return String(record.get("name") || record.get("email") || id);
    } catch (_) {
      return id;
    }
  }

  const isSuperuser = typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();
  const auth = info ? info.auth : null;
  const userId = auth ? String(auth.id) : "";

  // --- 1. createdBy is server-owned ---------------------------------------
  if (isCreate) {
    // Never trust a client-supplied value: it would let any user attribute an
    // event to somebody else and then keep editing it through the `createdBy`
    // branch of the ownership check.
    //
    // A superuser carries an auth record (of the `_superusers` collection, not
    // `users`), so `auth` is truthy for it too — verified against 0.38.2. That
    // id would be meaningless as an owner and would leak an admin identity into
    // app data, so superusers (and anonymous callers) get an empty value.
    e.record.set("createdBy", isSuperuser ? "" : userId);
  } else if (!isSuperuser && info && info.body && info.body.createdBy !== undefined) {
    // `createdBy` is "server-set on create, never client-writable" — an update
    // that tries to reassign authorship is rewritten back to the stored value.
    const stored = $app.findRecordById("events", e.record.id);
    e.record.set("createdBy", stored ? String(stored.get("createdBy") || "") : "");
  }

  const startRaw = String(e.record.get("start") || "").trim();
  const endRaw = String(e.record.get("end") || "").trim();
  const startMillis = toEpochMillis(startRaw);
  const endMillis = toEpochMillis(endRaw);
  const venueId = toSingleId(e.record.get("venueId"));
  const performers = toIdList(e.record.get("performers"));

  // --- 2. shape validation: NOT on DELETE ---------------------------------
  //
  // These two checks describe what a WRITE must produce. A DELETE writes
  // nothing — it only removes a row — so applying them there adds no safety and
  // creates a trap: an event stored before these rules existed, with no venue
  // and no performers (the live dataset has exactly one), could never be
  // deleted by anyone but a superuser. `start`/`end` are also `required` in the
  // schema as of 1790250100_events_recurrence_and_required_dates.js; this
  // handler is what produces a message a human can act on, and it still guards
  // a database older than that migration.
  if (!isDelete) {
    if (!startRaw || !endRaw || isNaN(startMillis) || isNaN(endMillis)) {
      throw new BadRequestError("Event must have a start and an end time.");
    }
    if (!(startMillis < endMillis)) {
      throw new BadRequestError("Event end must be after its start.");
    }
    // The only shape rule a superuser may break. `start`/`end` stay mandatory
    // for everyone — the schema's `required` flag enforces them below any hook,
    // so relaxing them here would change nothing. "Booked somewhere" has no
    // schema equivalent, and refusing it for an admin would make it impossible
    // to import a legacy row (the live dataset contains exactly one event with
    // neither a venue nor a performer, and an importer must be able to write it
    // before it can be fixed up or deleted).
    if (!venueId && performers.length === 0 && !isSuperuser) {
      throw new BadRequestError("Event must be booked at a venue or by a performer.");
    }
    // Write the NORMALISED venue id back. Every comparison below is normalised,
    // so leaving the raw value in the record would let a stored value carry
    // padding that the next request has to strip again — and every other
    // reader (the client's venue lookup, a future SQL query) would have to know
    // to. `""` is the correct stored value for "no venue": the column is not a
    // relation, so it has no null form.
    if (venueId !== String(e.record.get("venueId") || "")) {
      e.record.set("venueId", venueId);
    }
  }

  // --- 3. ownership -------------------------------------------------------
  if (!isSuperuser && auth) {
    // Anonymous callers are left to the collection rules, which already reject
    // a write without an authenticated user.
    let owned = hasMembership(userId, "venue", venueId);
    if (!owned) {
      for (const performerId of performers) {
        if (hasMembership(userId, "performer", performerId)) {
          owned = true;
          break;
        }
      }
    }
    // Only an EXISTING record can prove ownership through `createdBy`. On a
    // create that field was just set to `userId` two blocks up, so accepting it
    // here would let every authenticated user book any venue — the very hole
    // this handler exists to close.
    if (!owned && !isCreate && String(e.record.get("createdBy") || "") === userId) {
      owned = true;
    }
    if (!owned) {
      throw new ForbiddenError(
        "You can only change events for venues you manage or performers you belong to."
      );
    }
  }

  // --- 4. double-booking --------------------------------------------------
  if (checkOverlap) {
    // NOT gated on the raw dates being truthy: by this point they are known to
    // be a valid range, and skipping the check on a falsy date is exactly how
    // the guard used to be bypassed with an empty `start`.
    const conflicts = findAllConflicts(
      toFilterDate(startRaw),
      toFilterDate(endRaw),
      e.record.id || ""
    );

    // Built once per write, and only when this event books somebody: the index
    // spans every active performer membership.
    const memberIndex = performers.length > 0 ? activePerformerMembers() : {};
    // The people this booking puts on stage.
    const myPeople = peopleIn(performers, memberIndex);

    for (const other of conflicts) {
      if (venueId && toSingleId(other.get("venueId")) === venueId) {
        throw new BadRequestError("Schedule conflict: venue already booked in this time range.");
      }
      const others = toIdList(other.get("performers"));
      if (others.length === 0) continue;

      // 1. The same act, booked twice.
      //
      // Kept as its own check rather than folded into the people comparison: an
      // act can have no members at all (a one-off, a DJ), and two bookings of it
      // must still collide. Relying on shared members would silently stop
      // catching the simplest case.
      for (const performerId of performers) {
        if (others.indexOf(performerId) !== -1) {
          throw new BadRequestError("Schedule conflict: performer already booked in this time range.");
        }
      }

      // 2. A different act that shares a person with this booking.
      //
      // This is the ensemble case: booking Thom Yorke solo against a Radiohead
      // slot, where the two records have no id in common and only the roster
      // says they are the same human being. Compared person-by-person rather
      // than act-by-act so the message can name who is double-booked.
      if (myPeople.length > 0) {
        const theirPeople = peopleIn(others, memberIndex);
        for (const memberId of theirPeople) {
          if (myPeople.indexOf(memberId) === -1) continue;

          // Name BOTH acts and the person. "This booking conflicts" is not
          // actionable when the incoming event is a festival bill with a dozen
          // acts on it — the user needs to know which pairing is the problem.
          let theirAct = "";
          for (const id of others) {
            if ((memberIndex[id] || []).indexOf(memberId) !== -1) {
              theirAct = id;
              break;
            }
          }
          let myAct = "";
          for (const id of performers) {
            if ((memberIndex[id] || []).indexOf(memberId) !== -1) {
              myAct = id;
              break;
            }
          }
          if (!theirAct || !myAct) continue;

          // A solo act is usually named after the person in it, so naming both
          // produces "shares Thom Yorke with Thom Yorke" — which reads like a
          // bug in the message rather than a fact about the booking. When the
          // two names coincide the person already identifies the act, so the
          // clause is dropped.
          const person = personName(memberId);
          const mine = performerName(myAct);
          throw new BadRequestError(
            "Schedule conflict: " + performerName(theirAct) +
              " is already booked in this time range, and shares " + person +
              (person === mine ? " with this booking." : " with " + mine + ".")
          );
        }
      }
    }
  }

  return e.next();
}

onRecordCreateRequest(eventsGuard);
onRecordUpdateRequest(eventsGuard);
onRecordDeleteRequest(eventsGuard);
