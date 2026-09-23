/// Server-side guards for writes to the `events` collection.
///
/// Two independent checks run on every write, in this order:
///
///   1. Ownership — a user may only create/update/delete an event booked at a
///      venue they manage (`venues.managerIds`) or by a performer they belong
///      to (`performers.memberIds`).
///   2. Double-booking — a create/update whose time range overlaps an existing
///      event sharing the same venue or any performer is rejected.
///
/// # Why ownership lives here and not in the collection rules
///
/// `users.createRule` is "" (public signup), so "any authenticated user" no
/// longer restricts anything — anyone can mint an account. Writes therefore
/// need an ownership proof, but `events.venueId` and `events.performers` are
/// plain text/json fields holding ids, NOT relations. PocketBase rules can
/// only traverse relations, so `venueId.managerIds ?= @request.auth.id` fails
/// with `field "venueId" is not a valid relation`. The collection rules stay
/// at "authenticated" and this handler narrows them.
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
///     scope when the hook runs. That is also why both checks share one
///     handler: a second registered function would need its own copy of
///     [toIdList], and a second copy is how the bug below creeps back in.
///   * Request-level hooks must call `e.next()` on every non-rejecting path,
///     otherwise the hook chain stops and the request is answered empty.
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
  const checkOverlap = method !== "DELETE";

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

  /// True when record [id] of [collection] lists [userId] in [field]
  /// (venues.managerIds / performers.memberIds).
  function ownsRecord(collection, field, id, userId) {
    if (id === null || id === undefined || String(id) === "") return false;
    let record = null;
    try {
      record = $app.findRecordById(collection, String(id));
    } catch (_) {
      // Dangling id: nothing to own.
      return false;
    }
    if (!record) return false;
    return toIdList(record.get(field)).indexOf(userId) !== -1;
  }

  const isSuperuser = typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();

  // --- 1. Ownership -------------------------------------------------------
  if (!isSuperuser) {
    const auth = info ? info.auth : null;
    // Anonymous: let the collection rules answer (they already reject writes
    // without an authenticated user).
    if (auth) {
      const userId = String(auth.id);
      let owned = ownsRecord("venues", "managerIds", e.record.get("venueId"), userId);

      if (!owned) {
        for (const performerId of toIdList(e.record.get("performers"))) {
          if (ownsRecord("performers", "memberIds", performerId, userId)) {
            owned = true;
            break;
          }
        }
      }

      if (!owned) {
        throw new ForbiddenError(
          "You can only change events for venues you manage or performers you belong to."
        );
      }
    }
  }

  // --- 2. Double-booking --------------------------------------------------
  if (checkOverlap) {
    function toIso(value) {
      if (!value) return "";
      if (typeof value === "string") return value;
      if (value instanceof Date) return value.toISOString();
      return String(value);
    }

    function intersects(a, b) {
      const set = new Set(a);
      for (const v of b) {
        if (set.has(v)) return true;
      }
      return false;
    }

    const startIso = toIso(e.record.get("start"));
    const endIso = toIso(e.record.get("end"));
    if (startIso && endIso) {
      const venueId = e.record.get("venueId");
      const performers = toIdList(e.record.get("performers"));

      let filter = `start < "${endIso}" && end > "${startIso}"`;
      // Exclude the record itself so updating an event doesn't collide with
      // its own previous state.
      if (e.record.id) filter += ` && id != "${e.record.id}"`;

      const items = $app.findRecordsByFilter("events", filter, "", 200, 0);
      for (const item of items) {
        if (venueId && item.get("venueId") === venueId) {
          throw new BadRequestError("Schedule conflict: venue already booked in this time range.");
        }
        if (performers.length > 0 && intersects(performers, toIdList(item.get("performers")))) {
          throw new BadRequestError("Schedule conflict: performer already booked in this time range.");
        }
      }
    }
  }

  return e.next();
}

onRecordCreateRequest(eventsGuard);
onRecordUpdateRequest(eventsGuard);
onRecordDeleteRequest(eventsGuard);
