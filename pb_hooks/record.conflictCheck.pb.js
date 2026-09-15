/// Server-side double-booking guard for the `events` collection.
///
/// Rejects a create/update whose time range overlaps an existing event sharing
/// the same venue or any performer, so the invariant holds regardless of which
/// client writes (app, script, or dashboard).
///
/// Three PocketBase runtime requirements this file depends on:
///   * Hook files are only loaded when they match `^.*(.pb.js|.pb.ts)$`.
///   * Registration extracts the handler by its SOURCE TEXT and compiles it
///     into a pooled VM (plugins/jsvm/binds.go), so every helper must be
///     declared inside the handler body — top-level declarations are not in
///     scope when the hook runs.
///   * Request-level hooks must call `e.next()` on every non-rejecting path,
///     otherwise the hook chain stops and the request is answered empty.

function conflictHandler(e) {
  // Not our collection: let the request continue untouched.
  if (!e.record || !e.collection || e.collection.name !== "events") {
    return e.next();
  }

  function parseList(value) {
    if (value === null || value === undefined) return [];
    if (Array.isArray(value)) return value.map((v) => String(v)).filter((v) => v.length > 0);
    if (typeof value === "string") {
      const s = value.trim();
      if (!s) return [];
      try {
        const parsed = JSON.parse(s);
        if (Array.isArray(parsed)) return parsed.map((v) => String(v)).filter((v) => v.length > 0);
      } catch (_) {}
      return s.split(",").map((v) => v.trim()).filter((v) => v.length > 0);
    }
    return [String(value)];
  }

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
  if (!startIso || !endIso) return e.next();

  const venueId = e.record.get("venueId");
  const performers = parseList(e.record.get("performers"));

  let filter = `start < "${endIso}" && end > "${startIso}"`;
  // Exclude the record itself so updating an event doesn't collide with its
  // own previous state.
  if (e.record.id) filter += ` && id != "${e.record.id}"`;

  const items = $app.findRecordsByFilter("events", filter, "", 200, 0);
  for (const item of items) {
    if (venueId && item.get("venueId") === venueId) {
      throw new BadRequestError("Schedule conflict: venue already booked in this time range.");
    }
    if (performers.length > 0 && intersects(performers, parseList(item.get("performers")))) {
      throw new BadRequestError("Schedule conflict: performer already booked in this time range.");
    }
  }

  return e.next();
}

onRecordCreateRequest(conflictHandler);
onRecordUpdateRequest(conflictHandler);
