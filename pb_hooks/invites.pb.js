/// Claims pending memberships the first time an invited address authenticates.
///
/// An invite can be written before its target has an account, in which case the
/// `memberships` row carries `pendingEmail` and an empty `userId`. Nothing else
/// in the system can fill that in later: `$app.findAuthRecordByEmail` cannot
/// see an account that does not exist yet, and the client has no way to prove
/// it owns an email address. The moment the account authenticates is the only
/// point where "who owns this address" is known with certainty, so the claim
/// happens here.
///
/// # Why this hook can never throw
///
/// `onRecordAuthRequest` runs inside a successful sign-in. A throw would fail
/// the login itself, locking out a user whose only problem is that an invite
/// row is malformed — far worse than leaving the invite unclaimed, because the
/// same claim is retried on every subsequent sign-in. Every failure is logged
/// and swallowed.
///
/// The handler still calls `e.next()`: this is a request-level hook, and not
/// calling it would stop the chain and answer the login with an empty body.
///
/// Claiming an address does NOT activate the row. `status` stays `pending`, so
/// the membership still grants nothing (`canAdminister` and the event guard both
/// require `status = "active"`); it only makes the row addressable by `userId`,
/// which is what lets the invitee answer it through
/// `POST /api/agenda/invite/respond`. Signing in is proof of owning an address,
/// not consent to join somebody's venue.
onRecordAuthRequest((e) => {
  try {
    const collectionName = e.collection ? e.collection.name : "";
    const record = e.record;
    if (collectionName !== "users" || !record) return e.next();

    const email = String(record.email() || "").trim();
    if (!email) return e.next();

    // Claim only rows nobody owns yet — `userId` empty. Re-claiming an already
    // linked row would overwrite a deliberate reassignment.
    const filter = "pendingEmail = " + '"' + email.replace(/["\\]/g, "") + '" && userId = ""';

    const pageSize = 200;
    let offset = 0;
    for (;;) {
      const page = $app.findRecordsByFilter("memberships", filter, "", pageSize, offset);
      for (const membership of page) {
        // `userId` only — never `status`. The invitee has proven the address is
        // theirs, which is what `/api/agenda/invite/respond` needs to find them
        // by id; accepting the invitation is a separate, deliberate act.
        membership.set("userId", String(record.id));
        $app.save(membership);
      }
      if (page.length < pageSize) break;
      // Records leave the result set as they are claimed (`userId` is no longer
      // empty), so the offset must NOT advance — the next row slides into the
      // slot the claimed one just vacated.
    }
  } catch (err) {
    console.log("invites.pb.js: could not claim pending memberships: " + err);
  }

  return e.next();
});
