/// <reference path="../pb_data/types.d.ts" />
///
/// Events become recurrence-aware and lose their free-text `status`.
///
/// # Why `start`/`end` are now required
///
/// Both columns were optional, so a client could POST `{"title": "x"}` and get
/// a stored event with an empty time range. Everything downstream then had to
/// guess: the client's `Event.fromMap` threw `FormatException` on the empty
/// string it got back, the overlap guard skipped its check because the dates
/// looked falsy, and the calendar could not place the row in a month. Making
/// the columns required turns that class of hole into a 400 at the API
/// boundary, which is where it belongs.
///
/// `pocketbase migrate` runs on the live DB, so existing rows are validated
/// first: an event with an empty `start`/`end` would abort the migration. The
/// up() below repairs those rows to a one-hour slot on the row's `created`
/// timestamp before flipping the flag, so the migration succeeds on any dataset
/// instead of demanding manual surgery.
///
/// `status` is dropped outright — nothing reads it, the client no longer sends
/// it, and the guard rejects writes that omit the time range instead.
///
/// `seriesId` groups the instances of one recurrence and `recurrence` stores
/// the `{freq,interval,count,until}` descriptor so a calendar can re-expand a
/// series without a second request.
migrate((app) => {
  const events = app.findCollectionByNameOrId("events");

  addMissingDate(events, "start");
  addMissingDate(events, "end");

  events.fields.add(new TextField({ id: "text_seriesId_events_0001", name: "seriesId", type: "text" }));
  events.fields.add(new JSONField({ id: "json_recurrence_events_0001", name: "recurrence", maxSize: 0 }));

  const start = events.fields.getByName("start");
  if (start) start.required = true;
  const end = events.fields.getByName("end");
  if (end) end.required = true;

  events.fields.removeByName("status");

  // Single-field indexes: the month window query filters on `start`/`end`, the
  // ownership + delete-references checks filter on `venueId`/`createdBy`, and
  // series expansion filters on `seriesId`. All five are already the shape the
  // queries use, so none of them needs a composite index.
  const indexes = [
    ["idx_events_start", "start"],
    ["idx_events_end", "end"],
    ["idx_events_venueId", "venueId"],
    ["idx_events_createdBy", "createdBy"],
    ["idx_events_seriesId", "seriesId"],
  ];
  for (const [name, column] of indexes) {
    events.addIndex(name, false, column, "");
  }

  app.save(events);

  /// Gives every row a usable value in a date column that is about to become
  /// required. `created` is always populated by the autodate field, so it is
  /// the safest anchor; `end` is derived from `start` to keep the range valid.
  function addMissingDate(collection, name) {
    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = app.findRecordsByFilter("events", "", "", pageSize, offset);
      for (const record of page) {
        const current = String(record.get(name) || "").trim();
        if (!current || current.indexOf("0001-01-01") === 0) {
          const created = String(record.get("created") || "").trim();
          const anchor = created || new Date().toISOString().replace("T", " ");
          if (name === "start") {
            record.set("start", anchor);
          } else {
            const begin = String(record.get("start") || "").trim() || anchor;
            record.set("end", shiftOneHour(begin));
          }
          app.save(record);
        }
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }
  }

  /// One hour after a PocketBase-normalised timestamp
  /// (`YYYY-MM-DD HH:MM:SS.sssZ`). Parsed as text rather than with `Date` so a
  /// malformed value degrades to "no change" instead of silently producing an
  /// `Invalid Date` string that the column would reject.
  function shiftOneHour(timestamp) {
    const match = String(timestamp).match(
      /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})\.(\d{1,3})Z$/
    );
    if (!match) return String(timestamp);
    const ms = Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]),
      Number(match[5]),
      Number(match[6]),
      Number(match[7])
    );
    return new Date(ms + 3600000).toISOString().replace("T", " ");
  }
}, (app) => {
  const events = app.findCollectionByNameOrId("events");

  const start = events.fields.getByName("start");
  if (start) start.required = false;
  const end = events.fields.getByName("end");
  if (end) end.required = false;

  events.fields.removeByName("seriesId");
  events.fields.removeByName("recurrence");

  // Restore `status` as the free-text column it used to be. Its old values are
  // unrecoverable — the point of the up() migration was that nothing read them
  // — so it comes back empty rather than pretending to a value it never had.
  events.fields.add(new TextField({ id: "text_status_1687431684", name: "status", type: "text" }));

  for (const name of ["idx_events_start", "idx_events_end", "idx_events_venueId", "idx_events_createdBy", "idx_events_seriesId"]) {
    events.removeIndex(name);
  }

  app.save(events);
})
