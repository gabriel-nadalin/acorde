/// Custom API routes that cannot be expressed as collection rules.
///
/// Eight endpoints:
///
///   * `POST /api/agenda/claim` — adopt an unmanaged venue/performer.
///   * `GET  /api/agenda/roster` — the team list of a venue/performer.
///   * `POST /api/agenda/invite/respond` — the invitee accepts or declines.
///   * `POST /api/agenda/join` — ask to join an entity you do not manage.
///   * `POST /api/agenda/roster/decide` — a manager answers a PENDING row.
///   * `GET  /api/agenda/requests` — the pending join requests the caller must
///     answer, across every target they manage.
///   * `GET  /api/agenda/user-lookup` — "is this address registered?", for the
///     invite form, without becoming an email-enumeration oracle.
///   * `GET  /api/agenda/mail-status` — can this server send mail at all? The
///     forgot-password flow needs to know before it promises an email.
///
/// # The two directions of one row
///
/// A membership is created by one of two people, and `initiatedBy` records
/// which: a MANAGER naming an address is an `invite`, its subject asking for
/// access is a `request`. Both are written `status: "pending"` and both grant
/// nothing until a manager of the target answers — the row is a question, not a
/// grant. There is no email channel in this system, so "notification" is an
/// in-app count; nobody is told, they look.
///
/// # Why these are not hooks or rules on the `memberships` collection
///
/// `memberships.createRule` is `@request.auth.id != ""` and
/// `entities.guard.pb.js` narrows it further: you may only create a membership
/// for a venue or performer you **already** manage. That is exactly right for
/// invites, and exactly wrong for the cases above:
///
///   * A CLAIM only makes sense because nobody manages the entity yet. A
///     request handler can run the ownership check in the other direction ("is
///     this entity unmanaged?"), which a rule cannot.
///   * A ROSTER cannot be expressed at all. The target is a polymorphic
///     `(targetType, targetId)` pair of PLAIN TEXT columns, and a rule can only
///     traverse relations — so there is no expression reaching from a
///     membership row to "the targets I am an active manager of". PocketBase's
///     own answer to that is a denormalised column, which is what the removed
///     `targetOwnerId` was; the honest form of the question ("does an active
///     manager row for this target name me?") needs code, so the read rules
///     shrink to self-only rows and the roster is served here.
///   * ANSWERING AN INVITATION has to match an address, write the resolved
///     `userId` and then change or delete the row. A rule can allow or deny; it
///     cannot act.
///
/// # PocketBase runtime requirements (easy to break)
///
///   * Hook files are only loaded when they match `^.*(.pb.js|.pb.ts)$`.
///   * Registration extracts each handler by its SOURCE TEXT and compiles it
///     into a pooled VM (`plugins/jsvm/binds.go`), so every helper must be
///     declared INSIDE the handler body — top-level declarations are not in
///     scope when the handler runs. That is why [quote] and [queryParam] appear
///     once per handler below instead of once here.
///   * `e.body` is NOT the parsed payload for a route registered through
///     `routerAdd`: it stays empty unless a record-CRUD middleware populated it.
///     `requestInfo().body` is the parsed JSON for any request.
///   * `$app.save()` / `$app.delete()` bypass collection rules AND the record
///     hooks: they write through the native layer, not the record HTTP
///     endpoint. Every authorization decision for a route in this file
///     therefore has to be made here, explicitly — including the last-manager
///     invariant in the invite response, which the membership guard would
///     otherwise be the only enforcer of.

/// `POST /api/agenda/claim` — adopt an existing venue or performer.
///
/// Body: `{ targetType: "venue" | "performer", targetId: string }`.
///
/// Answers 200 `{status: "claimed" | "already"}`. Refuses with 409 when the
/// entity already has a manager, because taking over somebody else's room by
/// typing its name is not a claim, it is a takeover — that path is a join
/// request, which the entity's managers approve.
///
/// The abuse window is narrow by construction: a claim only succeeds against an
/// entity that has **no** claimed manager, and it is idempotent afterwards, so
/// there is nothing to rate-limit beyond the first success.
routerAdd(
  "POST",
  "/api/agenda/claim",
  (e) => {
    /// Quotes a value for a PocketBase filter. Ids never legitimately contain
    /// `"` or `\`, and both would break out of the filter string, so they are
    /// stripped rather than escaped (same helper as the record guards).
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const auth = e.auth;
    const userId = auth ? String(auth.id) : "";
    if (!userId) {
      throw new UnauthorizedError("Sign in to claim a venue or performer.");
    }

    // `e.body` is NOT the parsed payload for a route registered through
    // `routerAdd`: it stays empty unless a record-CRUD middleware populated it.
    // `requestInfo().body` is the parsed JSON for any request, and the property
    // form is accepted too so a build change cannot silently reduce every body
    // to `{}` — which would make this endpoint reject every well-formed claim
    // with a validation error instead of failing loudly.
    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
    const body = (info && info.body) ? info.body : {};
    const targetType = String(body.targetType || "").trim();
    const targetId = String(body.targetId || "").trim();

    if (targetType !== "venue" && targetType !== "performer") {
      throw new BadRequestError("targetType must be 'venue' or 'performer'.");
    }
    if (!targetId) {
      throw new BadRequestError("targetId is required.");
    }

    // `findRecordById` takes the id directly, so the lookup itself is not
    // injectable; only the derived filters below need quoting.
    const collectionName = targetType === "venue" ? "venues" : "performers";
    let target = null;
    try {
      target = $app.findRecordById(collectionName, targetId);
    } catch (_) {
      // Falls through to the 404 below.
    }
    if (!target) {
      throw new NotFoundError("That " + targetType + " no longer exists.");
    }

    // Who already manages it? Only rows that can actually administer the entity
    // count: `role = manager` AND `status = active`. An outstanding invitation
    // is deliberately excluded — blocking on it would let one stale invite
    // permanently lock the entity out of ever being adopted, and a `pending`
    // row grants its invitee nothing anyway.
    const rows = $app.findRecordsByFilter(
      "memberships",
      "targetType = " + quote(targetType) +
        " && targetId = " + quote(targetId) +
        " && role = " + quote("manager") +
        " && status = " + quote("active"),
      "",
      200,
      0
    );

    let alreadyMine = false;
    let claimedManagers = 0;
    for (const row of rows) {
      const rowUser = String(row.get("userId") || "");
      if (!rowUser) continue;
      claimedManagers++;
      if (rowUser === userId) alreadyMine = true;
    }

    if (alreadyMine) {
      // Idempotent: a double-tap or a retry after a flaky response must not
      // create a second manager row.
      return e.json(200, { status: "already", targetType: targetType, targetId: targetId });
    }

    // `createdBy` is provenance, not an authorization source — but a claim is
    // still refused when it names somebody else, because that means the entity
    // has a recorded creator who is not the claimer, i.e. it is not an orphan.
    // (Being the creator buys nothing: the manager row written below is what
    // grants access, which is the point of Phase 2.)
    const createdBy = String(target.get("createdBy") || "");
    if (claimedManagers > 0 || (createdBy && createdBy !== userId)) {
      throw new ApiError(
        409,
        "This " + targetType + " already has a manager. Ask them to invite you."
      );
    }

    if (!createdBy) {
      // Recorded so the adopted entity has a creator for the tools that read
      // that column (the seed script and the backfill in 1790250200 both key
      // off it). It grants nothing on its own.
      target.set("createdBy", userId);
      $app.save(target);
    }

    // A row for this user may already exist on the target — a `pending`
    // invitation addressed to them, say. A membership is identified by the
    // (user, target) pair, so that row is promoted rather than joined by a
    // twin; two rows for one person would list them twice on the roster.
    const mine = $app.findRecordsByFilter(
      "memberships",
      "userId = " + quote(userId) +
        " && targetType = " + quote(targetType) +
        " && targetId = " + quote(targetId),
      "",
      1,
      0
    );
    const membership = mine.length > 0
      ? mine[0]
      : new Record($app.findCollectionByNameOrId("memberships"));
    membership.set("userId", userId);
    membership.set("targetId", targetId);
    membership.set("targetType", targetType);
    // Always an ACTIVE MANAGER row: a claim is somebody taking responsibility
    // for the entity, and `canAdminister` requires exactly that. A claimed
    // performer therefore differs from a merely invited one, which may be a
    // booking-only `member`.
    membership.set("role", "manager");
    membership.set("status", "active");
    if (!String(membership.get("initiatedBy") || "").trim()) {
      // `request`, not `invite`: the two values differ in WHO asked for the
      // link, and in a claim that is the claimer.
      membership.set("initiatedBy", "request");
    }
    $app.save(membership);

    console.log(
      "agenda: user " + userId + " claimed " + targetType + " " + targetId
    );

    return e.json(200, {
      status: "claimed",
      targetType: targetType,
      targetId: targetId,
      membershipId: String(membership.id),
    });
  },
  // Any auth collection would let a superuser call this, and a superuser has no
  // `users` id to record as the manager — the row would name a phantom owner.
  $apis.requireAuth("users")
);

/// `GET /api/agenda/roster?targetType=venue&targetId=xyz` — the team list.
///
/// Answers 200 `{items: [...]}` with the rows of the target in display order,
/// each carrying the person's resolved `name`/`email`, an `isSelf` flag (the row
/// belongs to the caller), a `requestedByMe` flag (the row is the caller's own
/// unanswered REQUEST — see the field below), and the row's own
/// `targetId`/`targetType` (the client parses roster rows with the same
/// `Membership.fromMap` as collection rows, so a missing `targetType` would
/// default every performer row to `venue`).
/// 400 for a bad `targetType`, 403 for anybody who is not an active manager of
/// the target, 404 for a target that does not exist. A superuser bypasses the
/// manager check so the admin dashboard and the seed tooling keep working.
routerAdd(
  "GET",
  "/api/agenda/roster",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;

    /// Query string reader. `url.Values` reaches JS in more than one shape
    /// depending on the build (an object of string arrays, an object of plain
    /// strings, or an object with a `get` method), and a GET route that
    /// silently reads an empty `targetType` would answer 400 for every
    /// well-formed request — the same family of trap as `e.body` being empty.
    /// All shapes are accepted, and the raw URL is the last resort.
    function queryParam(name) {
      const query = info && info.query ? info.query : null;
      if (query) {
        if (typeof query.get === "function") {
          const viaGetter = query.get(name);
          if (viaGetter !== null && viaGetter !== undefined) {
            return String(viaGetter).trim();
          }
        }
        const direct = query[name];
        if (Array.isArray(direct) && direct.length > 0) {
          return String(direct[0]).trim();
        }
        if (direct !== undefined && direct !== null && !Array.isArray(direct)) {
          return String(direct).trim();
        }
      }
      try {
        const raw = String(e.request.url);
        const match = raw.match(new RegExp("[?&]" + name + "=([^&]*)"));
        if (match) return decodeURIComponent(match[1]).trim();
      } catch (_) {
        // Falls through to the empty string.
      }
      return "";
    }

    /// An ACTIVE MANAGER row for the requester on the target. The same question
    /// `canAdminister` answers in `entities.guard.pb.js`, restated here because
    /// each registered handler is compiled from its own source text and shares
    /// no scope with the record guards.
    function isActiveManager(memberId, targetType, targetId) {
      if (!memberId || !targetId) return false;
      const filter =
        "userId = " + quote(memberId) +
        " && targetType = " + quote(targetType) +
        " && targetId = " + quote(targetId) +
        " && role = " + quote("manager") +
        " && status = " + quote("active");
      return $app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
    }

    /// Active rows first, then managers, then by name.
    ///
    /// Active first because the people who actually have access are what the
    /// screen is for; an unanswered invitation is a request awaiting a human.
    /// Managers before members within each group, because the role that can
    /// change the roster is the one to look at first. A pending row has no
    /// resolved name (its account may not exist yet), so the email is the sort
    /// key there — never empty, and stable.
    function compareItems(left, right) {
      const activeDelta =
        (left.status === "active" ? 0 : 1) - (right.status === "active" ? 0 : 1);
      if (activeDelta !== 0) return activeDelta;
      const roleDelta =
        (left.role === "manager" ? 0 : 1) - (right.role === "manager" ? 0 : 1);
      if (roleDelta !== 0) return roleDelta;
      const leftName = String(left.name || left.email || "").toLowerCase();
      const rightName = String(right.name || right.email || "").toLowerCase();
      if (leftName < rightName) return -1;
      if (leftName > rightName) return 1;
      return 0;
    }

    const requester = e.auth ? String(e.auth.id) : "";
    const isSuperuser =
      typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();

    const targetType = queryParam("targetType");
    const targetId = queryParam("targetId");

    if (targetType !== "venue" && targetType !== "performer") {
      throw new BadRequestError("targetType must be 'venue' or 'performer'.");
    }
    if (!targetId) {
      throw new BadRequestError("targetId is required.");
    }

    let target = null;
    try {
      target = $app.findRecordById(
        targetType === "venue" ? "venues" : "performers",
        targetId
      );
    } catch (_) {
      // Falls through to the 404 below.
    }
    if (!target) {
      throw new NotFoundError("That " + targetType + " no longer exists.");
    }

    if (isSuperuser === false && isActiveManager(requester, targetType, targetId) === false) {
      // Includes a plain `member`: belonging to an entity is not managing it,
      // and the roster names the other members — which is exactly the
      // information a member has no business having.
      throw new ForbiddenError(
        "Only a manager of this " + targetType + " can see its roster."
      );
    }

    // Paged: `findRecordsByFilter` stops at its `limit`, so a single call with
    // a generous limit would truncate the roster of a large venue silently.
    const pageSize = 200;
    let offset = 0;
    const items = [];
    for (;;) {
      const page = $app.findRecordsByFilter(
        "memberships",
        "targetType = " + quote(targetType) + " && targetId = " + quote(targetId),
        "",
        pageSize,
        offset
      );
      for (const row of page) {
        const rowUser = String(row.get("userId") || "");
        const pendingEmail = String(row.get("pendingEmail") || "");
        let name = "";
        let email = pendingEmail;
        if (rowUser) {
          // The lookup may miss: a membership can outlive the account it names
          // (accounts live in another collection, and deleting one cascades
          // nothing), and a missing account must degrade to an empty name
          // rather than fail the whole roster — the manager would then be
          // unable to see, let alone repair, the row that points nowhere.
          let user = null;
          try {
            user = $app.findRecordById("users", rowUser);
          } catch (_) {
            // Leaves name/email empty.
          }
          if (user) {
            name = String(user.get("name") || "");
            email = String(user.get("email") || "");
          }
        }
        items.push({
          id: String(row.id),
          userId: rowUser,
          pendingEmail: pendingEmail,
          // Constant for the whole response, but sent anyway: these are the
          // row's identity, and the client model
          // (`lib/models/membership.dart`) parses every row through the same
          // `fromMap`, which defaults a missing `targetId` to "" and a missing
          // `targetType` to `venue` — silently wrong for a performer roster.
          targetId: targetId,
          targetType: targetType,
          role: String(row.get("role") || ""),
          status: String(row.get("status") || ""),
          initiatedBy: String(row.get("initiatedBy") || ""),
          name: name,
          email: email,
          // Purely a comparison against the caller, so a superuser (whose id is
          // not a `users` id) sees false on every row rather than a throw.
          isSelf: requester !== "" && rowUser === requester,
          // "This row is the request I made." Distinct from `isSelf`, which is
          // true for every row of the caller's: a pending row of theirs that
          // came from an INVITATION is a question addressed TO them, while a
          // pending REQUEST row is their own unanswered ask. The two want
          // different words on screen ("waiting for you" / "your request") and
          // only the second may be withdrawn by its owner, so the client cannot
          // derive one from the other without re-deriving `initiatedBy` itself.
          requestedByMe:
            requester !== "" &&
            rowUser === requester &&
            String(row.get("status") || "") === "pending" &&
            String(row.get("initiatedBy") || "") === "request",
        });
      }
      if (page.length < pageSize) break;
      offset += pageSize;
    }

    items.sort(compareItems);

    return e.json(200, { items: items });
  },
  // `users` for the app, plus `_superusers` because the handler's documented
  // superuser bypass is otherwise unreachable: `requireAuth` rejects any auth
  // record whose collection is not in the list, and a superuser token carries a
  // `_superusers` record — so with `requireAuth("users")` alone the dashboard
  // and the seed tooling get a 403 before the bypass is ever evaluated.
  $apis.requireAuth("users", "_superusers")
);

/// `POST /api/agenda/invite/respond` — the invitee accepts or declines.
///
/// Body: `{ membershipId: string, action: "accept" | "decline" }`.
///
/// Answers 200 `{status: "active" | "declined", membershipId}`.
///
/// `accept` sets `status = "active"`; `decline` DELETES the row. A declined
/// invitation is not a record worth keeping — it would also block a re-invite,
/// because the guard keys its duplicate prevention on the (user, target) pair.
///
/// Refusals: 400 for a missing row (the client's only view of it is the roster
/// it was just handed, so a missing row means somebody else already answered or
/// revoked it — a stale action, not a wrong URL), 400 for accepting a row that
/// is already active, 403 for anybody who is not the invitee.
///
/// This is the ONLY membership write a non-manager may perform, and it is
/// deliberately narrow: it cannot create a row, cannot change a role, and
/// cannot touch a target the caller has nothing to do with.
routerAdd(
  "POST",
  "/api/agenda/invite/respond",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const auth = e.auth;
    const userId = auth ? String(auth.id) : "";
    if (!userId) {
      throw new UnauthorizedError("Sign in to answer an invitation.");
    }

    // `email()` is the record's own accessor; `get("email")` is the fallback if
    // a build exposes only the field map.
    let callerEmail = "";
    try {
      callerEmail = String(auth.email() || "").trim();
    } catch (_) {
      callerEmail = String(auth.get("email") || "").trim();
    }

    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
    const body = (info && info.body) ? info.body : {};
    const membershipId = String(body.membershipId || "").trim();
    const action = String(body.action || "").trim();

    if (!membershipId) {
      throw new BadRequestError("membershipId is required.");
    }
    if (action !== "accept" && action !== "decline") {
      throw new BadRequestError("action must be 'accept' or 'decline'.");
    }

    let membership = null;
    try {
      membership = $app.findRecordById("memberships", membershipId);
    } catch (_) {
      // Falls through to the 400 below.
    }
    if (!membership) {
      throw new BadRequestError("That invitation no longer exists.");
    }

    const rowUser = String(membership.get("userId") || "").trim();
    const pendingEmail = String(membership.get("pendingEmail") || "").trim();
    const emailMatches =
      pendingEmail !== "" &&
      callerEmail !== "" &&
      pendingEmail.toLowerCase() === callerEmail.toLowerCase();

    // The invitee is proven by the account id when the row has one, and by the
    // address otherwise. An address match only counts for the caller who just
    // authenticated as that address — the same proof `invites.pb.js` relies on
    // — and the id is written immediately, so the row stops being keyed by an
    // address somebody could later re-register.
    const alreadyLinked = rowUser !== "" && rowUser === userId;
    if (alreadyLinked === false && emailMatches) {
      if (rowUser === "") membership.set("userId", userId);
    } else if (alreadyLinked === false) {
      throw new ForbiddenError("Only the invited person can answer this invitation.");
    }

    if (action === "decline") {
      // The last-manager invariant, restated because `$app.delete` bypasses the
      // membership guard: declining an ACTIVE row is the invitee leaving, and
      // the one thing that must not fall out of it is an entity with nobody
      // left who can manage it.
      const isActiveManager =
        String(membership.get("status") || "") === "active" &&
        String(membership.get("role") || "") === "manager";
      if (isActiveManager) {
        const survivors = $app.findRecordsByFilter(
          "memberships",
          "targetType = " + quote(String(membership.get("targetType") || "")) +
            " && targetId = " + quote(String(membership.get("targetId") || "")) +
            " && role = " + quote("manager") +
            " && status = " + quote("active") +
            " && id != " + quote(membershipId),
          "",
          1,
          0
        );
        if (survivors.length === 0) {
          throw new BadRequestError(
            "Cannot remove the last manager of this " +
              String(membership.get("targetType") || "entity") +
              ". Add another manager first."
          );
        }
      }
      $app.delete(membership);
      return e.json(200, { status: "declined", membershipId: membershipId });
    }

    if (String(membership.get("status") || "") === "active") {
      throw new BadRequestError("That invitation has already been accepted.");
    }

    membership.set("status", "active");
    // `initiatedBy` is left as stored: accepting does not change who asked.
    $app.save(membership);

    console.log(
      "agenda: user " + userId + " accepted membership " + membershipId
    );

    return e.json(200, { status: "active", membershipId: membershipId });
  },
  $apis.requireAuth("users")
);

/// `POST /api/agenda/join` — ask to join a venue or performer you do not manage.
///
/// Body: `{ targetType: "venue" | "performer", targetId: string, role?: "member" | "manager" }`.
///
/// Answers 200 `{status: "requested", membershipId}`, and writes
/// `{userId: caller, status: "pending", initiatedBy: "request"}`. A request is a
/// QUESTION, not a grant: `canAdminister` and the event guard both require
/// `status = "active"`, so a pending request buys nothing until a manager of the
/// target approves it through `POST /api/agenda/roster/decide`.
///
/// # Why this is a route and not a rule
///
/// The `memberships` create rule requires an ACTIVE MANAGER row — correct for an
/// invite, and the exact opposite of what a requester has, since the whole point
/// of a request is that they manage nothing. A rule can only refuse a write, and
/// the pending row has to be WRITTEN by somebody, so it is written here with
/// `$app.save` — which bypasses the rules AND the record hooks, so every
/// authorization decision is made explicitly below (see the file header).
///
/// # The four refusals are 400s with four different sentences, deliberately
///
/// They are not 409s: the UI shows the server's own wording next to the button
/// that was just pressed, and these are four different situations — "you are
/// already in", "you already asked", "you already run this", "that is not a
/// role" — which a single "conflict" would collapse into one unhelpful line.
///
/// `role` is capped at the two roles the roster screen knows, and no value of it
/// can activate the row: nothing here can make somebody a member of an entity
/// without a manager of that entity saying yes.
routerAdd(
  "POST",
  "/api/agenda/join",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const auth = e.auth;
    const userId = auth ? String(auth.id) : "";
    if (!userId) {
      throw new UnauthorizedError("Sign in to request access.");
    }

    // `e.body` is NOT the parsed payload for a route registered through
    // `routerAdd`: it stays empty unless a record-CRUD middleware populated it.
    // `requestInfo().body` is the parsed JSON for any request, and the property
    // form is accepted too so a build change cannot silently reduce every body
    // to `{}` — which would turn every request into "targetId is required."
    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
    const body = (info && info.body) ? info.body : {};
    const targetType = String(body.targetType || "").trim();
    const targetId = String(body.targetId || "").trim();
    // Defaulted rather than required: the common request is "let me work here",
    // and making the client spell that out buys nothing.
    const role = String(body.role || "").trim() || "member";

    if (targetType !== "venue" && targetType !== "performer") {
      throw new BadRequestError("targetType must be 'venue' or 'performer'.");
    }
    if (!targetId) {
      throw new BadRequestError("targetId is required.");
    }
    if (role !== "member" && role !== "manager") {
      throw new BadRequestError("role must be 'member' or 'manager'.");
    }

    // `findRecordById` takes the id directly, so the lookup is not injectable;
    // only the derived filters below need quoting.
    const collectionName = targetType === "venue" ? "venues" : "performers";
    let target = null;
    try {
      target = $app.findRecordById(collectionName, targetId);
    } catch (_) {
      // Falls through to the 404 below.
    }
    if (!target) {
      throw new NotFoundError("That " + targetType + " no longer exists.");
    }

    // The name comes from the RECORD, never from the body: a client-supplied
    // name in an error message is a way to put arbitrary text in front of a
    // person who is expecting the entity's own title.
    const targetName = String(target.get("name") || "").trim();
    const subject = targetName ? targetType + ' "' + targetName + '"' : "this " + targetType;

    // Every row the caller already has for this (user, target) pair, in one
    // read: a membership is identified by that pair, so the refusals below are
    // readings of the same small set. Nothing here writes.
    const mine = $app.findRecordsByFilter(
      "memberships",
      "userId = " + quote(userId) +
        " && targetType = " + quote(targetType) +
        " && targetId = " + quote(targetId),
      "",
      200,
      0
    );

    let manages = false;
    let active = false;
    let pendingRequest = false;
    let pendingInvite = false;
    for (const row of mine) {
      const status = String(row.get("status") || "");
      if (status === "active") {
        active = true;
        if (String(row.get("role") || "") === "manager") manages = true;
      } else if (status === "pending") {
        if (String(row.get("initiatedBy") || "") === "request") pendingRequest = true;
        else pendingInvite = true;
      }
    }

    // Checked FIRST, and that order is load-bearing: a manager of the entity
    // necessarily holds an active row too, so testing "active" first would
    // answer "you are already a member" to the one person the sentence about
    // managing is written for.
    if (manages) {
      throw new BadRequestError("You already manage " + subject + ".");
    }
    if (active) {
      throw new BadRequestError("You are already a member of " + subject + ".");
    }
    if (pendingRequest) {
      throw new BadRequestError("Your request is already waiting for approval.");
    }
    if (pendingInvite) {
      // Not one of the four refusals the contract names, and it cannot be: an
      // invitation awaiting an answer is neither an active row, nor a request,
      // nor management of the entity. Writing a second row for the same pair
      // would list the person twice on the roster — the reason the claim route
      // promotes an existing row instead of twinning it — and silently
      // rewriting `initiatedBy` would destroy the fact that the MANAGER was the
      // one who asked. So the answer is "answer that first": the row they
      // already have IS the invitation, and either their own response or a
      // manager's decision clears it.
      throw new BadRequestError(
        "You already have an invitation to " + subject + ". Answer it first."
      );
    }

    // A brand-new row: every existing row for the pair was refused above.
    const membership = new Record($app.findCollectionByNameOrId("memberships"));
    membership.set("userId", userId);
    membership.set("targetId", targetId);
    membership.set("targetType", targetType);
    membership.set("role", role);
    membership.set("status", "pending");
    membership.set("initiatedBy", "request");
    // `pendingEmail` stays EMPTY on purpose: the column exists to address
    // somebody with no account yet, and a requester is authenticated by
    // definition. Setting it would also make the row readable by whoever
    // registers that address later (the list rule matches on it).
    membership.set("pendingEmail", "");
    $app.save(membership);

    console.log(
      "agenda: user " + userId + " requested to join " + targetType + " " + targetId
    );

    return e.json(200, {
      status: "requested",
      membershipId: String(membership.id),
    });
  },
  // `users` only: a membership row names a `users` id, and a superuser token
  // carries a `_superusers` record — the row would name a member nobody can be.
  // Same reasoning as the claim route.
  $apis.requireAuth("users")
);

/// `POST /api/agenda/roster/decide` — approve or reject a PENDING membership.
///
/// Body: `{ membershipId: string, action: "approve" | "reject" }`.
///
/// Answers 200 `{status: "active" | "rejected", membershipId}`.
///
/// `approve` sets `status = "active"` and keeps the requested `role` — the role
/// that was on the table is the role that was asked for. `reject` DELETES the
/// row, for the same reason `invite/respond` deletes a declined invitation: a
/// refused row is not worth keeping, and keeping it would block the person's
/// next request through the duplicate check in `POST /api/agenda/join`.
/// Deleting a PENDING row cannot orphan the target: `requireManagerLeft` guards
/// active MANAGER rows only, and this route refuses anything that is not pending
/// before it deletes.
///
/// # The escalation this route exists to refuse
///
/// The caller must be an ACTIVE MANAGER of the membership's target, and that
/// check has no self-exception. There is deliberately no branch comparing the
/// caller to the row's `userId`: approving your own request IS the escalation,
/// and that comparison would be the bug rather than a convenience. The manager
/// test alone is sufficient because `POST /api/agenda/join` refuses anybody who
/// already manages the target, so a requester can never hold the row that would
/// let them through. Superusers bypass it (see the `requireAuth` note below).
///
/// # A manager may push an INVITATION through too — deliberately
///
/// `initiatedBy` is not read at all: the question this route answers is "may
/// this person in?", whoever asked. That makes it the only recovery path for an
/// invitee who never answers — with no email channel there is no way to remind
/// them, and the alternative (delete the invitation, then write an active row
/// through the collection) is the same act in two requests.
///
/// Refusals: 404 for a row that does not exist, 403 for anybody who does not
/// manage the target, 400 for a row that is not pending. The order matters — the
/// authorization check runs BEFORE the pending check, so a non-manager learns
/// nothing about the row's state, and the 404 comes first of all because the
/// target has to be read from the stored row before anything can be authorized
/// (the same reason `entities.guard.pb.js` resolves a membership's target from
/// the row rather than the request).
routerAdd(
  "POST",
  "/api/agenda/roster/decide",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    /// An ACTIVE MANAGER row for the requester on the target — the same question
    /// `canAdminister` answers in `entities.guard.pb.js`, restated because each
    /// registered handler is compiled from its own source text and shares no
    /// scope with the record guards.
    function isActiveManager(memberId, targetType, targetId) {
      if (!memberId || !targetId) return false;
      const filter =
        "userId = " + quote(memberId) +
        " && targetType = " + quote(targetType) +
        " && targetId = " + quote(targetId) +
        " && role = " + quote("manager") +
        " && status = " + quote("active");
      return $app.findRecordsByFilter("memberships", filter, "", 1, 0).length > 0;
    }

    const requester = e.auth ? String(e.auth.id) : "";
    const isSuperuser =
      typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();

    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;
    const body = (info && info.body) ? info.body : {};
    const membershipId = String(body.membershipId || "").trim();
    const action = String(body.action || "").trim();

    if (!membershipId) {
      throw new BadRequestError("membershipId is required.");
    }
    if (action !== "approve" && action !== "reject") {
      throw new BadRequestError("action must be 'approve' or 'reject'.");
    }

    let membership = null;
    try {
      membership = $app.findRecordById("memberships", membershipId);
    } catch (_) {
      // Falls through to the 404 below.
    }
    if (!membership) {
      // 404, unlike the 400 `invite/respond` answers for a missing row: this
      // caller arrived from a roster of a target they manage, so a missing id is
      // a stale screen or an id from somewhere else — and "that does not exist"
      // is the honest answer for both, without disclosing which.
      throw new NotFoundError("That membership no longer exists.");
    }

    const targetType = String(membership.get("targetType") || "");
    const targetId = String(membership.get("targetId") || "");

    if (isSuperuser === false && isActiveManager(requester, targetType, targetId) === false) {
      throw new ForbiddenError(
        "Only a manager of this " + (targetType || "entity") + " can answer this request."
      );
    }

    if (String(membership.get("status") || "") !== "pending") {
      throw new BadRequestError("That membership is not waiting for approval.");
    }

    if (action === "reject") {
      $app.delete(membership);
      console.log("agenda: membership " + membershipId + " rejected");
      return e.json(200, { status: "rejected", membershipId: membershipId });
    }

    membership.set("status", "active");
    // `role` and `initiatedBy` are left as stored: approving answers the
    // question that was asked, it does not re-ask it, and the role on the table
    // is the one the request named.
    $app.save(membership);

    console.log("agenda: membership " + membershipId + " approved");

    return e.json(200, { status: "active", membershipId: membershipId });
  },
  // `users`, plus `_superusers` because of the documented superuser bypass:
  // `requireAuth` rejects any auth record whose collection is not in the list,
  // and a superuser token carries a `_superusers` record — with
  // `requireAuth("users")` alone the dashboard would get a 403 before the bypass
  // was ever evaluated.
  $apis.requireAuth("users", "_superusers")
);

/// `GET /api/agenda/user-lookup?email=…` — the "already registered" hint.
///
/// Answers 200 `{exists: bool, name: string}` and NOTHING else: no id, no email,
/// no record fields. The caller supplied the address, so echoing it back proves
/// nothing and leaks nothing new; the id or any other column would hand out more
/// than the yes/no the invite form needs. `name` is the account's display name,
/// or `""` when it has none.
///
/// # Why this needs a manager gate
///
/// "Does this address have an account?" open to every signed-in account is an
/// email-enumeration oracle: register, then walk a list of addresses and keep
/// the ones that answer yes. So the caller must hold at least one ACTIVE MANAGER
/// row — the same standing that lets them invite people at all — or be a
/// superuser. Any manager of anything is enough, because the invite form exists
/// for every one of them.
///
/// `exists` describes the ADDRESS, not the account's state: the invite form's
/// question is "does this address already resolve to a person?", and the fields
/// that come closest to a state (`users.verified`, which this schema has — and
/// `users.disabled`, which it does not) are deliberately not read. Answering
/// "verified or not?" would be a second, narrower oracle, and an unverified
/// account still owns its address, so the answer must not depend on account
/// state at all.
///
/// A malformed or empty `email` is a 400 rather than a blank answer: the form
/// only ever sends what somebody typed, so an address-less request is a client
/// bug, and a silent `{exists: false}` for it would be a lie that looks like a
/// lookup result.
routerAdd(
  "GET",
  "/api/agenda/user-lookup",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const info = typeof e.requestInfo === "function" ? e.requestInfo() : e.requestInfo;

    /// Query string reader. `url.Values` reaches JS in more than one shape
    /// depending on the build (an object of string arrays, an object of plain
    /// strings, or an object with a `get` method), and a GET route that silently
    /// reads an empty value would answer 400 for every well-formed request — the
    /// same family of trap as `e.body` being empty on a `routerAdd` route. All
    /// shapes are accepted, and the raw URL is the last resort.
    function queryParam(name) {
      const query = info && info.query ? info.query : null;
      if (query) {
        if (typeof query.get === "function") {
          const viaGetter = query.get(name);
          if (viaGetter !== null && viaGetter !== undefined) {
            return String(viaGetter).trim();
          }
        }
        const direct = query[name];
        if (Array.isArray(direct) && direct.length > 0) {
          return String(direct[0]).trim();
        }
        if (direct !== undefined && direct !== null && !Array.isArray(direct)) {
          return String(direct).trim();
        }
      }
      try {
        const raw = String(e.request.url);
        const match = raw.match(new RegExp("[?&]" + name + "=([^&]*)"));
        if (match) return decodeURIComponent(match[1]).trim();
      } catch (_) {
        // Falls through to the empty string.
      }
      return "";
    }

    const requester = e.auth ? String(e.auth.id) : "";
    const isSuperuser =
      typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();

    if (isSuperuser === false) {
      // ANY active manager row, on any target — the standing to invite, not the
      // standing to invite to a particular place.
      const managerRows = $app.findRecordsByFilter(
        "memberships",
        "userId = " + quote(requester) +
          " && role = " + quote("manager") +
          " && status = " + quote("active"),
        "",
        1,
        0
      );
      if (!requester || managerRows.length === 0) {
        throw new ForbiddenError(
          "Only a manager of a venue or performer can look up an account."
        );
      }
    }

    /// Deliberately loose: this checks the SHAPE of what arrived (one `@`,
    /// something either side of it, a dot in the domain), it does not validate
    /// an address. A stricter pattern would reject addresses PocketBase itself
    /// accepts, and a well-formed but absent address has a harmless answer
    /// anyway (`exists: false`).
    function looksLikeEmail(value) {
      return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
    }

    const email = queryParam("email");
    if (!looksLikeEmail(email)) {
      throw new BadRequestError("A valid email address is required.");
    }

    let account = null;
    try {
      account = $app.findAuthRecordByEmail("users", email);
    } catch (_) {
      // `findAuthRecordByEmail` THROWS when nothing matches (see the ordering
      // traps in `entities.guard.pb.js`), so absence is the catch, not a null.
    }

    // No account state is read: see the note above on what `exists` means.
    return e.json(200, {
      exists: account !== null,
      name: account ? String(account.get("name") || "") : "",
    });
  },
  // `_superusers` as well, for the same reason as the roster and `decide`: the
  // documented superuser access is otherwise unreachable behind the 401.
  $apis.requireAuth("users", "_superusers")
);

/// `GET /api/agenda/requests` — the pending JOIN REQUESTS the caller must answer.
///
/// Answers 200 `{items: [...]}`, each item in the same shape
/// `GET /api/agenda/roster` answers with (including the row's own
/// `targetId`/`targetType`, so the client can name the entity and link to its
/// roster). **Not paginated**: `items` is a manager's unanswered invitations to
/// the room, which is a handful, and a paging cursor on a dashboard badge would
/// be ceremony. The limits below are documentation, not pagination.
///
/// # Why this endpoint exists at all
///
/// `memberships.listRule` is self-only, and a rule cannot be widened for this:
/// the target is a polymorphic `(targetType, targetId)` text pair, so there is
/// no expression from a membership row to "the targets I actively manage" (the
/// same reason the roster is a route — see the file header). The roster route
/// CAN answer it, but only one target at a time, so a dashboard summarising
/// "what is waiting for me" would have to call it once per venue and performer
/// the user manages. This is that fan-out, in one request.
///
/// # What it does NOT do
///
/// It is not a way to see a target's rows: only rows that are `pending` AND
/// `request` are returned, and only for targets the caller actively manages, so
/// nothing here is visible to a caller that the per-target roster would not
/// already show them. Invitations are deliberately absent — an invitation is a
/// question the MANAGER asked, and it is not waiting on the manager.
///
/// **A caller who manages nothing gets 200 with an empty list, not a 403.**
/// That is the most common state of all (a brand-new account), and it is not an
/// error: they have no incoming requests because they have nothing to guard. A
/// 403 would make the dashboard render a failure for the ordinary case.
routerAdd(
  "GET",
  "/api/agenda/requests",
  (e) => {
    function quote(value) {
      return '"' + String(value).replace(/["\\]/g, "") + '"';
    }

    const requester = e.auth ? String(e.auth.id) : "";
    const isSuperuser =
      typeof e.hasSuperuserAuth === "function" && e.hasSuperuserAuth();

    /// The row shape `GET /api/agenda/roster` answers with, field for field. The
    /// client parses both through `Membership.fromMap`, so a missing
    /// `targetType` would default every row to a venue, and a missing
    /// `isSelf`/`requestedByMe` would silently read as false.
    function rosterRow(row) {
      const rowUser = String(row.get("userId") || "");
      const pendingEmail = String(row.get("pendingEmail") || "");
      let name = "";
      let email = pendingEmail;
      if (rowUser) {
        // The lookup may miss (accounts live in another collection and deleting
        // one cascades nothing), and a missing account must degrade to an empty
        // name rather than fail the whole list.
        let user = null;
        try {
          user = $app.findRecordById("users", rowUser);
        } catch (_) {
          // Leaves name/email empty.
        }
        if (user) {
          name = String(user.get("name") || "");
          email = String(user.get("email") || "");
        }
      }
      const status = String(row.get("status") || "");
      const initiatedBy = String(row.get("initiatedBy") || "");
      // Computed rather than hardcoded false: a caller cannot hold a pending
      // request for a target they manage (`POST /api/agenda/join` refuses
      // exactly that), so both are false for every row this route can return in
      // practice — but the shape stays identical to the roster's, and it stays
      // correct if that invariant ever changes.
      const isSelf = requester !== "" && rowUser === requester;
      return {
        id: String(row.id),
        userId: rowUser,
        pendingEmail: pendingEmail,
        targetId: String(row.get("targetId") || ""),
        targetType: String(row.get("targetType") || ""),
        role: String(row.get("role") || ""),
        status: status,
        initiatedBy: initiatedBy,
        name: name,
        email: email,
        isSelf: isSelf,
        requestedByMe: isSelf && status === "pending" && initiatedBy === "request",
      };
    }

    /// The row's `created` as a sortable string. PocketBase hands a
    /// `types.DateTime` to JS, which is not reliably a string in every build —
    /// and the fields are read through the same accessor family as everywhere
    /// else in this file for that reason.
    /// The stored form is `YYYY-MM-DD HH:MM:SS.sssZ`, which compares
    /// chronologically as text.
    function createdKey(row) {
      try {
        const value = row.get("created");
        if (value === null || value === undefined) return "";
        if (typeof value === "string") return value;
        if (typeof value.string === "function") return String(value.string());
        return String(value);
      } catch (_) {
        // An unreadable timestamp sorts last rather than failing the list.
        return "";
      }
    }

    const rows = [];
    // Keyed by row id because the same row can be reached twice: the fan-out
    // below reads one filter per managed target, and nothing in the schema stops
    // a person from holding two active manager rows for one target (only the app
    // path that writes them does). A request listed twice would render twice.
    const seen = {};

    /// Every page of a filter, appending to [rows]. `findRecordsByFilter`
    /// truncates at its `limit`, and a silently truncated list of requests is
    /// indistinguishable from "nothing else is waiting".
    function collect(filter) {
      const pageSize = 200;
      let offset = 0;
      for (;;) {
        const page = $app.findRecordsByFilter("memberships", filter, "", pageSize, offset);
        for (const row of page) {
          const id = String(row.id);
          if (seen[id]) continue;
          seen[id] = true;
          rows.push(row);
        }
        if (page.length < pageSize) break;
        offset += pageSize;
      }
    }

    /// Only `pending` AND `request`: an unanswered INVITATION is the manager's
    /// own question coming back to them, and an active row is already answered.
    function requestFilter(targetType, targetId) {
      let filter =
        "status = " + quote("pending") +
        " && initiatedBy = " + quote("request");
      if (targetType && targetId) {
        filter =
          "targetType = " + quote(targetType) +
          " && targetId = " + quote(targetId) +
          " && " + filter;
      }
      return filter;
    }

    if (isSuperuser) {
      // The documented bypass: the admin dashboard sees every outstanding
      // request, which is what makes a stuck one diagnosable.
      collect(requestFilter("", ""));
    } else {
      // The targets the caller ACTIVELY MANAGES — the same condition
      // `canAdminister` and the roster route use, restated because each
      // registered handler is compiled from its own source text and shares no
      // scope with the others.
      const targets = [];
      const targetPageSize = 200;
      let offset = 0;
      for (;;) {
        const page = $app.findRecordsByFilter(
          "memberships",
          "userId = " + quote(requester) +
            " && role = " + quote("manager") +
            " && status = " + quote("active"),
          "",
          targetPageSize,
          offset
        );
        for (const row of page) {
          targets.push({
            targetType: String(row.get("targetType") || ""),
            targetId: String(row.get("targetId") || ""),
          });
        }
        if (page.length < targetPageSize) break;
        offset += targetPageSize;
      }

      // A deliberate cap on the fan-out, not pagination: one read per managed
      // target, so an account managing hundreds of entities would turn this
      // into hundreds of queries. Beyond it the list is incomplete, so it is
      // logged rather than silently short.
      const targetLimit = 200;
      for (let i = 0; i < targets.length && i < targetLimit; i++) {
        collect(requestFilter(targets[i].targetType, targets[i].targetId));
      }
      if (targets.length > targetLimit) {
        console.log(
          "agenda: /requests truncated for user " + requester +
            " (" + targets.length + " managed targets)"
        );
      }
    }

    // Newest first — the one that just arrived is the one to look at. Ties keep
    // insertion order (`Array.prototype.sort` is stable), and a tied pair is
    // only reachable when two requests were written in the same millisecond.
    rows.sort((left, right) => {
      const a = createdKey(left);
      const b = createdKey(right);
      if (a === b) return 0;
      return a < b ? 1 : -1;
    });

    return e.json(200, { items: rows.map(rosterRow) });
  },
  // `_superusers` as well, because of the documented superuser bypass: with
  // `requireAuth("users")` alone the dashboard would get a 401 before the
  // bypass was ever evaluated.
  $apis.requireAuth("users", "_superusers")
);

/// `GET /api/agenda/mail-status` — can this server actually send mail?
///
/// Answers 200 `{enabled: bool}`: whether PocketBase has a usable SMTP
/// configuration, so the client knows whether a password reset can arrive.
///
/// # Why this route has to exist
///
/// `POST /api/collections/users/request-password-reset` answers 204 with an
/// empty body for every input — an unknown address, a known address, and a
/// server with no mailer configured alike. That is deliberate on PocketBase's
/// part: differing responses would turn the endpoint into an email-enumeration
/// oracle. The cost is that the endpoint cannot say "nothing was sent".
///
/// Without a mailer a password reset is a dead end that looks exactly like a
/// success: the user is told to check an inbox nothing will ever arrive in, and
/// has no way to find out why. Asking this first lets the sign-in screen say so
/// outright instead of promising an email. The administrator path — resetting
/// the password from the PocketBase dashboard — always works, so the honest
/// message is actionable rather than a dead end.
///
/// # Why this one is unauthenticated
///
/// It serves the forgot-password flow, which happens *before* anyone holds a
/// session, so an auth gate would make it unreachable exactly when it is needed.
/// It is not an oracle of anything: one bit about server configuration, no user
/// data, and the answer does not vary by account, by address, or by request — it
/// is the same for everyone who asks it.
routerAdd("GET", "/api/agenda/mail-status", (e) => {
  /// Both halves matter: `enabled` is the operator's switch, and an empty `host`
  /// means the switch is on with nowhere to send. Reading it defensively because
  /// a false "no mail" is recoverable (the user asks an administrator, who can
  /// always reset it) while a false "yes, check your inbox" is a dead end.
  let enabled = false;
  try {
    const smtp = $app.settings().smtp;
    enabled = !!smtp.enabled && String(smtp.host || "") !== "";
  } catch (_) {
    // Left false: see above on which error is safe to make.
  }
  return e.json(200, { enabled: enabled });
});
