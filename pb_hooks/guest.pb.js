/// Guest sign-in: a capability the server reports, and nothing else.
///
/// # What this is for
///
/// The app is a prototype meant to be opened and poked at — by a reviewer, a
/// stakeholder, someone handed a link. Requiring an address and a password before
/// anything can be seen is friction with no payoff here: the account exists for
/// five minutes and nobody will ever sign back into it. Guest sign-in removes
/// both fields from that path.
///
/// # What a guest account IS
///
/// Nothing special. The client generates a throwaway address and password and
/// creates an ordinary `users` record through the same public signup endpoint
/// any self-service registration uses; this file does not create records, and
/// deliberately does not have the power to. That keeps one account-creation path
/// in the system instead of two, and means guest accounts inherit every rule,
/// guard and limit that already applies to signup — including the collection's
/// own rate limiting. The guest is distinguishable from a registered user only
/// by its address (`...@guest.invalid`, the reserved TLD that can never resolve)
/// and by the name it is given.
///
/// So the honest description is "prefilled signup", not "anonymous session":
/// a guest is a real account with no assignments, which is exactly what a brand
/// new user has. They land on the dashboard with nothing in it and the whole
/// app to explore from there.
///
/// # Why the switch is here and not in the client
///
/// The button has to be able to disappear. A deployment that does not want
/// throwaway accounts must be able to turn them off without shipping a new
/// bundle, and the client must not offer a button the server will refuse — that
/// is the failure this app has already had once (see the router's redirect and
/// `1790400000_public_entity_lists.js`: a screen advertising a capability
/// nobody implemented). So the client asks, this answers, and the button is
/// rendered from the answer.
///
/// Guest sign-in is **ON by default**, and `PB_GUEST_LOGIN` is therefore an OFF
/// switch: `0`, `false`, `off` or `no` disables it, while unset, empty, `1`,
/// `true` or a typo all leave it on. That direction is deliberate — this is a
/// prototype, and a demo button that only appears after somebody edits a file is
/// absent from every demo — so the default has to suit the demo and the opt-out
/// has to be the thing a real deployment writes down. `docker-compose.yml`
/// passes `PB_GUEST_LOGIN` through, and `.env.example` documents it.
///
/// # Why this is not an oracle
///
/// One bit about server *configuration*: no user data, and the same answer for
/// every caller. It reveals nothing about who has an account or what is in one —
/// the same class of probe as `GET /api/agenda/mail-status`.
routerAdd("GET", "/api/agenda/guest-status", (e) => {
  let enabled = true;
  try {
    // Read through `$os.getenv`, which is how the mail hooks in this directory
    // take their configuration, so there is one way to configure the backend.
    //
    // The `null`/`undefined` guard matters: where the binding itself is missing
    // the read can come back undefined rather than empty, and `String(undefined)`
    // is the non-empty string "undefined", which would sail past a comparison
    // against an explicit "no". No try-throw here — an unreadable environment is "off", never a 500,
    // because the caller's only use for the answer is whether to draw a button.
    const raw = $os.getenv("PB_GUEST_LOGIN");
    const value = String(raw === null || raw === undefined ? "" : raw)
      .trim()
      .toLowerCase();
    enabled = !(value === "0" || value === "false" || value === "off" || value === "no");
  } catch (_) {
    // An unreadable environment leaves the default (enabled) in place: the
    // capability is a prototype affordance, not a security boundary. What a
    // guest may DO is bounded by the collection rules and the guards, not by
    // whether this button is drawn.
  }
  return e.json(200, { enabled: enabled });
});
