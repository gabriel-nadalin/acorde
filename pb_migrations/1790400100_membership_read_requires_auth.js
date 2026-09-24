/// Stops an anonymous caller from listing every membership.
///
/// # The bug
///
/// `memberships` carried:
///
///     listRule: userId = @request.auth.id || pendingEmail = @request.auth.email
///
/// For a request with no session, `@request.auth.id` and `@request.auth.email`
/// both resolve to the empty string, so the rule became
/// `userId = "" || pendingEmail = ""`. Every claimed membership row in this
/// database has an empty `pendingEmail` (it is only set on an *unclaimed*
/// invite), so `pendingEmail = ""` matched **every row** and
/// `GET /api/collections/memberships/records` answered 200 with the whole
/// membership graph to anybody who asked — no token, no account, no trace:
/// which user manages which venue and performer, and in what role. Verified
/// against the running instance before this migration was written.
///
/// PocketBase rules are *filters*, not predicates over rows: a failing rule on a
/// list endpoint is not a 403, it is a query that matches nothing. That is what
/// hid this — the endpoint looked protected because the intent in the comment
/// above it ("the collection's rule is self-only", which
/// `PocketBaseService.getRoster` still says) was true for signed-in callers and
/// false for everyone else.
///
/// # The fix
///
/// The same rule, gated on there being a session at all. `pendingEmail != ""`
/// is redundant once a session is required — an authenticated account always
/// has a non-empty address, so `pendingEmail = @request.auth.email` can never
/// match the empty string — but it is kept because it states the intent
/// directly, and because a future rule that reads `pendingEmail` without that
/// guard is exactly how this bug happened.
///
/// # Why this does not break the app
///
/// Nothing the client asks for anonymously. `AssignmentsController` skips its
/// fetch with no session (`refresh` returns early), the browse page no longer
/// warms it either, and the roster and pending-request lists are served by
/// `agenda_routes.pb.js` with their own manager checks. Signed-in reads are
/// unchanged: a user still lists their own rows and any invite addressed to
/// their address.
///
/// Written as its own migration rather than an edit to
/// `1790250000_entity_ownership_and_memberships.js`, which is the file that
/// introduced the rule: PocketBase records an applied migration by filename and
/// never re-runs it, so editing that file would leave every existing database —
/// including the one this was found on — still leaking.
migrate((app) => {
  const collection = app.findCollectionByNameOrId("memberships");
  unmarshal(
    {
      // Authenticated, then self: my own rows, plus a pending invitation
      // addressed to my address (which has no `userId` until I sign in and the
      // `invites.pb.js` hook claims it).
      "listRule":
        '@request.auth.id != "" && (userId = @request.auth.id || (pendingEmail != "" && pendingEmail = @request.auth.email))',
      "viewRule":
        '@request.auth.id != "" && (userId = @request.auth.id || (pendingEmail != "" && pendingEmail = @request.auth.email))',
    },
    collection
  );
  return app.save(collection);
}, (app) => {
  // Back to the leaky rule, so the down migration is a faithful undo of this
  // one rather than a "safe" variant that never shipped.
  const collection = app.findCollectionByNameOrId("memberships");
  unmarshal(
    {
      "listRule": "userId = @request.auth.id || pendingEmail = @request.auth.email",
      "viewRule": "userId = @request.auth.id || pendingEmail = @request.auth.email",
    },
    collection
  );
  return app.save(collection);
});
