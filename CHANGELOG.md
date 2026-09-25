# Changelog

## Unreleased

### Added

* **Three things the README was missing.** It covered all six screens but not the
  three questions a user hits *between* them. *Recuperar a senha* documents the
  reset flow, including why the confirmation is deliberately hedged ("se esse
  endereço tiver uma conta…") rather than confirming an account exists.
  *Recorrência* documents that a repeat creates independent events, and therefore
  why deleting one asks *somente este* vs *a série inteira* — the one
  irreversible question in the app, previously discoverable only by meeting it.
  And a bullet records that times are shown in the **viewer's** zone, so
  `venues.timezone` does not move anything; that field's doc comment called it an
  "IANA zone name" while nothing parsed it, which the new text and a note in
  `DEVELOPMENT.md` correct.

* **Guest sign-in, for demonstrating the app without an account.** The sign-in
  screen gains *"Entrar como visitante"*, which creates a throwaway account and
  signs in with it — no address, no password typed. The credentials are generated client-side (`guest-<ts><rand>@guest.invalid`,
  a 24-character password) and the account is created through the **ordinary
  public signup endpoint**, so a guest is an ordinary account with no
  assignments: one creation path to reason about, and every existing rule, guard
  and rate limit applies unchanged. **ON by default**, because a demo button that
  requires editing a file first is off in every demo; `PB_GUEST_LOGIN=0` disables
  it, and any other value (unset, empty, a typo) leaves it on. The button is gated
  on `GET /api/agenda/guest-status` rather than on a build flag, so a deployment
  can turn it off without shipping a new bundle, and the client never offers a
  button the server would refuse. Verified against a real server for unset, `1`,
  `0`, `false`, `off`, empty and a nonsense value. The
  probe follows `mail-status`: one bit about server configuration, read so that a
  failure withholds the button instead of offering a dead end.

* **The upcoming list says when the month turns, and hands off to the calendar.**
  Two changes to `/upcoming`, both about the one thing a flat list cannot say — the
  shape of the schedule. A month heading now sits above the first day of each month,
  because a long list of day headers ran "sexta-feira, 25 de setembro" into "sábado,
  7 de novembro" with nothing marking the turn, which is exactly what somebody
  scanning for "how far out does this go" is looking for. And a day header is now
  tappable: it opens the calendar on that day's month (`/calendar?month=YYYY-MM`),
  which is the one question the list cannot answer about a date.

  A calendar grid *inside* the list was the other obvious move and was rejected:
  both screens read all events, so a grid there would be a strict subset of the
  `/calendar` tab one tap away — the app already shipped one feature drawn twice,
  which is why `Destinations` exists. The screens read different data paths
  (`end > now` unbounded vs. a month window with its own cache), so a second grid
  would have meant a second month-loading path beside the one that already exists.

### Fixed

* **Próximos listed bookings that were not yours, and tapping one led nowhere.**
  Reported by the user: tapping a day in the upcoming list opened a calendar that
  "has nothing to do with" the events listed there. It did not — `/upcoming` ran
  one query with no scope at all (`end > now`), while the calendar's Combinado tab
  filters to this account's assignments. Measured on the seeded data, three of
  seventeen rows were somebody else's bookings, shown in the list and absent from
  the screen the day header opened.

  The screens were not merely inconsistent, they were two implementations of one
  idea: `events_list.dart` had `_eventCats` and used it to filter, `upcoming.dart`
  had `_colorFor` and used it only to choose a colour. They now share
  `lib/utils/event_scope.dart`, and the repository's list is scoped by the screen
  rather than by the repository, which cannot know who is asking.

  The display cap moved with it: it now applies *after* scoping, because capping
  first let other people's bookings fill the fifty-row window and push this
  account's off the end.

### Fixed

* **"Explorar locais" and "Explorar artistas" on the sign-in screen did nothing.**
  Reported by the user, confirmed by clicking them: the URL stayed on `/`. They
  were broken in two independent places, both fixed. The router's redirect sent
  every signed-out visitor back to the sign-in route unless it was one of a
  hand-written pair of public paths, so the public lists the screen advertised
  were unreachable — while the route comment claimed they were public. The
  allowlist is now derived from `Destinations.public`, which reads each
  destination's new `requiresAuth` flag, so a list is declared public in exactly
  one place. And `venues`/`performers` carried `listRule: '@request.auth.id != ""'`,
  so even a route that got through would have rendered a list that 401'd: new
  `1790400000_public_entity_lists.js` makes both readable anonymously, leaving
  every write rule authenticated and ownership-narrowed as before.
* **A public list, signed out, now looks like one.** The top bar offered the
  dashboard, the upcoming list and the calendar — each of which the router
  refuses, i.e. three buttons that bounced — plus sign-out for a session that
  does not exist. It now offers only the destinations the session can open
  (`Destination.requiresAuth`) and shows *Entrar* in place of *Sair*. The create
  button and the whole per-row action area (manage / ask to join / pending
  marker) are withheld too, since none of them mean anything without a session;
  the row still opens its calendar, which is what a reader came for.
* **Anonymous callers could list every membership in the database.** Found while
  fixing the above. `memberships` carried
  `listRule: userId = @request.auth.id || pendingEmail = @request.auth.email`,
  and for a request with no session both sides resolve to the empty string —
  `pendingEmail = ""` matches every claimed row, because `pendingEmail` is only
  set on an unclaimed invite. `GET /api/collections/memberships/records` answered
  200 with the entire membership graph (who manages which venue and performer, in
  what role) to anybody, no token required; verified against the running instance
  before fixing. A PocketBase rule is a *filter*, not a predicate: a failing rule
  on a list endpoint is not a 403, it is a query matching nothing, which is what
  hid it. New `1790400100_membership_read_requires_auth.js` gates the same rule on
  there being a session at all. `scripts/verify_schema.dart` grew the rule into
  its templates, so this cannot silently regress.

### Added

* **A README in Portuguese, with screenshots.** The app ships in Portuguese, so its
  front page now does too: what it is, how to run it (Docker Compose, then the local
  Flutter + PocketBase path), and how to use each screen — with captures of the
  login, dashboard, calendar, upcoming list and browse list in `docs/img/`.
* **The engineering document moved to [DEVELOPMENT.md](DEVELOPMENT.md).** It was
  the README, but it is a 600-line architecture and deployment reference — the
  wrong first thing to hand somebody who wants to run the app. The CI toolchain
  drift guard now greps DEVELOPMENT.md, which is where the pinned-version table
  lives.


* **Upcoming events** (`/upcoming`, and a three-row preview on the dashboard).
  One query — `end > now`, sorted by `start` — so a booking months out appears
  without paging the calendar that far. Bounded on `end`, not `start`, so a
  booking that is happening right now is included rather than hidden until it is
  over. Grouped by day. Kept across a failed fetch with a "showing cached" banner,
  and dropped on sign-out.
* **Deleting events**, from the upcoming list, a calendar day sheet, and the edit
  form — one `confirmDeleteEvent`, so all three ask the same thing. A repeating
  instance is asked about explicitly (this one / the whole series, with the count
  on the button and read from the server's stored instances); deleting a whole
  series cannot be undone, and deleting one night of a weekly booking is rarely
  what was meant. Offered only where the server would accept it (a venue the
  account manages, an act it belongs to, an event it created), because a 403
  dressed up as a button is worse than no button.
* `context.read<EventRepository>().upcoming(...)`, plus `deleteSeries` and
  `seriesInstanceCount` on the repository.

### Added

* **Password recovery.** `/forgot-password` requests a reset link and
  `/reset-password?token=…` spends it; both are public, and the router exempts
  them from the signed-out redirect — the visitor following a reset link is
  normally signed out, and bouncing them to the sign-in screen they cannot get
  past was the whole point of the link. The form asks a new
  `GET /api/agenda/mail-status` route before promising anything: PocketBase
  answers `request-password-reset` with 204 for every input, including when no
  SMTP is configured, so with no mailer the screen says recovery is unavailable
  and names the administrator path instead of an inbox that will stay empty.
* **The reset email now links here.** PocketBase's built-in template points at its
  own admin dashboard (`{APP_URL}/_/#/auth/confirm-password-reset/{TOKEN}`), which
  in this deployment falls through to the SPA catch-all and renders nothing — a
  link that fails only once it reaches the recipient. A migration rewrites it to
  the app's route, and `pb_hooks/mail.pb.js` applies `PB_APP_URL` (new, documented
  in `.env.example` and passed by docker-compose) so the host is the front end and
  not the backend's `localhost:8090`.
* **The auth session is no longer plaintext.** The bearer token and session cookie
  moved from `SharedPreferences` to the platform keystore
  (`flutter_secure_storage`) behind a `SessionStore` interface; the user record
  stays where it was, so an upgrading install keeps its profile and, if the
  keystore had nothing, adopts the plaintext credential once and deletes it. Every
  keystore access is bounded by a timeout, because a platform channel can go
  unanswered as well as throw — and an unanswered write inside `login` left the
  app on the sign-in screen with a spinner that never stopped.

### Added

* **Outbound email, so membership can reach people.** An invitation now emails the
  invited address, and a join request emails every active manager of that
  entity — the second one is what makes *"someone asked to play my room"* a
  question that gets asked rather than a row somebody may never open. Both are
  sent from `pb_hooks/mail.pb.js` as a side effect of the `memberships` row being
  written, are best-effort (a mail failure is logged, never thrown — the row is
  already committed), and are skipped entirely when no mailer is configured.
  `PB_SMTP_*` is documented in `.env.example` and forwarded by docker-compose.
  Verified end to end against a real SMTP conversation: correct recipient,
  subject naming the entity, and role wording in both directions.

### Fixed

* **The invitation email names the inviter.** It could not before: a `memberships`
  row recorded the direction of an invite (`initiatedBy`) but not the person, and
  for an invite `userId` holds the INVITEE, so the inviter was nowhere in the
  system to look up — the post-write hook that sends the mail has no `e.auth`
  either. A new `memberships.invitedBy` column is written on create from the
  authenticated caller, treated as an identity field on update (so it cannot be
  rewritten), and read by no authorization check. A client cannot name somebody
  else as the inviter; both properties have guard tests. Verified end to end:
  *"Ana Manager convidou você para participar de Inviter Hall como membro."*
* **`PB_SMTP_TLS` defaulted to the wrong mode.** PocketBase's `tls: true` means
  IMPLICIT TLS (port 465), while `false` sends STARTTLS — which is what port 587,
  the standard submission port, expects. The default is now `0` (STARTTLS), and
  both `.env.example` and the hook explain the two modes, because choosing the
  wrong one fails with "first record does not look like a TLS handshake" — which
  reads like a broken mail server rather than a mismatched setting. Found by
  pointing a real relay at it.

### Changed

* **A plain member is no longer offered controls the server refuses.** The role
  split is real at the server — `entities.guard.pb.js` lets any active membership
  book events, but requires an active **manager** to rename, re-roster or delete
  an entity, and the roster endpoint answers 403 for anything less — yet the
  client asked only "is this mine", which is the *booking* question, and used the
  answer to decide whether to draw an edit button. So a band member was shown both
  a ＋ and a pencil on their own band, and the dashboard labelled the row
  *"Gerenciar artista"*: the pencil opened an editor whose save the server
  rejected, and the dashboard's label pointed at a roster that would 403.
  `AssignmentsController` now derives `canManagePerformer`/`canManageVenue` from
  active manager rows, separate from `isMyPerformer`/`isMyVenue`, and the browse
  rows split three ways instead of two: manage (＋ and pencil), belong (＋ only),
  or join (ask / pending). Verified against a live server — Thom Yorke is a
  `member` of Radiohead and a `manager` of Eastside Loft, so `PATCH` returns 403
  on the one and succeeds on the other — and pinned by a new test per kind that
  fails with the old single-flag logic.
* **Membership `role` is constrained on the collection path, not only on `/join`.**
  The column is plain text, so `"Managr"` or `"admin"` was stored verbatim by a
  manager's invite and then read as *not a manager* by every consumer, since both
  `hasMembership(..., "manager", ...)` and the client's `isManager` compare
  against the exact string — a silent demotion. `POST /api/agenda/join` already
  rejected anything but `member`/`manager`; the create branch of
  `entities.guard.pb.js` now normalises the same way, with an omitted role
  becoming `member`. Not an escalation either way (creating still requires
  `canAdminister`), but no longer a silent one.
* **The `expand` request for event names is gone, along with the fields it fed.**
  Client code asked PocketBase for `expand=venueId,performers`, but the guard
  documents why that can never resolve: `events.venueId` and `events.performers`
  are text/json id fields, not relations, so rules and `expand` cannot traverse
  them. A live query returns no `expand` key at all, which made
  `Event.venueName`/`performerNames` and their two parsing helpers unreachable,
  and the fallbacks reading them in `event_labels.dart` dead. Display names come
  from the entity repositories at render time, which is also what keeps them from
  going stale behind a rename. 15 unreferenced messages were removed from
  `app_pt.arb` the same way (`loginFailed`, `reconnecting`, `rosterActive`,
  `noAccessToManage`, …), along with four unreferenced model members
  (`Venue`/`Performer`/`Membership.copyWith`, `UserLookup.fromJson`/`toJson`) and
  an unused `filter` parameter on `getMemberships`. `PocketBaseService.close()`
  stays: only the app never calls it, the realtime integration test constructs two
  services and releases both.
* **Comments that stated the opposite of the code are corrected.** `guest.pb.js`
  described `PB_GUEST_LOGIN` as opt-in ("anything else — unset, empty, `0`,
  `false`, a typo — is OFF") while the code it sits above defaults to **on**;
  `agenda_routes.pb.js` said twice that "there is no email channel in this system"
  after `mail.pb.js` had shipped one. A reader trusting either would have made a
  wrong call about the deployment. `DEVELOPMENT.md` also documented a
  `PB_TEST_DATA_DIR` that no script reads, and `.gitignore`'s comment cited it too;
  the genuinely undocumented knob is `PB_COOKIE`, which both collection scripts
  read and which is now written down.
* **`README.md` is in the toolchain drift guard.** The guard pinned the Flutter
  version across the workflow, the `Dockerfile` and `DEVELOPMENT.md`, but
  `README.md` names it too — in the copy a contributor reads first, and with
  nothing else linking the two. All four are compared now.
* **Web is the only platform.** The Android, iOS, macOS, Windows and Linux
  scaffolding is deleted — 115 files, five targets, none of them ever built by
  CI or the Dockerfile. `.metadata` follows. `flutter create --platforms=x .`
  restores any of them.
* **Brazilian Portuguese is the only locale.** `app_en.arb`/`app_es.arb` are gone
  and `app_pt.arb` is now the template as well as the only shipped language, so
  198 strings stopped needing three edits each. This immediately surfaced a real
  bug the English strings had hidden: the calendar day sheet's header was an
  intrinsic-width `Text` beside a button and overflowed a Material bottom sheet
  once the date was spelled out in Portuguese. The header is now flexible, and
  the single-locale fallback is pinned by `test/localization_pt_test.dart`.


* **The app is named.** It was still the `flutter create` placeholder everywhere:
  `pubspec.yaml` was `flutter_application_1`, the window and app titles said
  "flutter_application_1" or "Flutter Application 1", the web `<title>`, manifest
  and meta description advertised a new Flutter project, and the bundle ids were
  `com.example.flutter_application_1` — which the Play Store refuses to publish
  under that namespace. Everything then read `Event Calendar`, and the bundle ids
  were `com.eventcalendar.app`; the Kotlin `MainActivity` moved to match the new
  Android namespace, and the Xcode, Windows and Linux product metadata followed.
  Those targets were dropped afterwards (see *Web is the only platform*), so no
  bundle id survives in the tree today, and the name itself was replaced again —
  see the next entry.
* **The app is named `Acorde`.** *Agenda de Eventos* was a category, not a name:
  every scheduling app is an "agenda de eventos", and the phrase collided with the
  app's own vocabulary, where *Agenda*, *Combinado*, *Próximos* and *Calendário*
  each already mean something specific. Its PWA `short_name` was also 17
  characters — long enough for a launcher to ellipsize it on an installed icon.
  *Acorde* is the idea the app already centres on: a chord only works when its
  notes are in tune with one another, which is the same claim a room and the act
  playing it make about a shared slot — including the shared-performer collision
  (a solo set stepping on a band's booking) that `events.guard.pb.js` exists to
  catch. The product name now has one source, `appTitle` in `app_pt.arb`, which the
  generated `AppLocalizations` reads; the web `<title>`, meta description and
  manifest name/`short_name`/description were updated to agree with it instead of
  each holding an independent copy. **The Dart package moves with the product**,
  `event_calendar` → `acorde` — `pubspec.yaml` plus 70 `package:` imports across
  `test/` and `scripts/` — so the identifier in an import line and the name in the
  UI are the same word. `publish_to: none` keeps pub.dev namespace out of it, and
  `acorde` is unclaimed there regardless (404). The mail branding follows: the
  SMTP sender-name default is `Acorde` (it was `Event Calendar`, an English name in
  an app that ships only Portuguese), including the hidden
  `settings.meta.appName` fallback that produced it and the three email strings
  that spelled it out. Verified by a tree-wide search for the old names returning
  nothing outside this changelog, and by the full suite and the two backend
  integration scripts after re-resolving the renamed package.
* **The analyzer is a gate, not advice.** `dart format`'s tall style was swept
  across the 56 files that predated it, and the last 31 analyzer infos are gone:
  20 `avoid_print` (the dev scripts now write through `stdout`, matching the
  `stderr` they already used — the lint cannot tell a CLI tool from a widget) and
  11 unbraced single-statement bodies. CI enforces formatting over
  `lib test scripts` and runs `flutter analyze` with infos fatal, replacing the
  `continue-on-error` formatting step and `--no-fatal-infos`.

* **The upcoming icon is `Icons.schedule`, not `Icons.event_available`.** The
  latter renders an empty gap under the tree-shaken web font: the button is laid
  out, sized and tappable and paints nothing, while every icon beside it draws
  normally. The glyph is present in the generated subset with a valid outline, so
  it is a subsetting quirk rather than a missing character. Found by measuring the
  painted bar in a browser — the widget tests pass either way, because the icon
  widget is correct; it simply does not paint.

* **The dashboard is the app's home**, defined once as `kHomeLocation`. Both the
  router's redirect and the sign-in form read it — they previously decided the
  landing route separately and disagreed, so which one won depended on ordering.
* **The top bar navigates laterally.** Destinations are siblings, so switching
  between them replaces the page (`GoRouter.replace`) instead of pushing: no
  stack accumulates, and back from any destination returns to the dashboard.
  Drill-downs still push and still return where the user came from.
* The dashboard has no back arrow. While signed in the router redirects the
  sign-in route back to home, so an "exit to sign-in" arrow would visibly do
  nothing — the sign-out button is the way out.
* **The session's credential is encrypted at rest.** The bearer token and the
  session cookie were stored beside the profile in plaintext
  `SharedPreferences`, readable by anyone with the device's files — they now go
  to the OS keystore (`flutter_secure_storage`), with the profile left where the
  app's other caches expect it. An install that is already signed in is migrated
  on first read: the credential is re-encrypted and the plaintext keys are
  removed, and if the keystore cannot be reached the plaintext copy is kept so
  the next launch can try again rather than signing the user out. Persistence
  sits behind a `SessionStore` seam so a widget test can substitute an
  in-memory store for the keystore, which does not exist under `flutter test`.

### Fixed

* **The calendar stacked two top bars**, which put its back button below the
  tabs instead of in the leading position every other screen uses, and left it the
  only screen without sign-out (the inner bar's actions overrode the outer one's).
  The tab host now owns the single bar; its tabs are `embedded` pages that draw
  none. The bar carries the back arrow, one refresh (for every loaded month, since
  the per-tab refresh buttons went with the per-tab bars), the destinations, and
  sign-out — so all four screens have the same bar.

* `FakePb` ignored `sort`, so the entity lists and any ordered query were served
  in insertion order. One existing assertion had pinned that behaviour
  (`['Hall', 'Annex']`) where the real server returns name order; corrected to
  the server's contract, and the fake now honours `sort` including `-field`.

### Fixed

* **Creating an event by tapping a calendar day only worked on a venue's
  calendar.** Each view gated the day cell on its own condition — a venue page on
  whether the account manages that venue, a performer or combined page on the
  day merely having an event — so on the performer and combined tabs a tap on an
  empty day did nothing at all, while the create button was an unlabelled path to
  the same form. All four views now create through one method on the page, so the
  FAB, a day cell and the day sheet cannot disagree about what a new event is
  seeded with.
* The combined tab no longer stacks its own FAB on top of the one its pages
  already had. On a venue tab that was two buttons in the same place; the page
  owns the button now, and names it per view ("New event (venue)", "New event
  (performer)", "New event").
* The combined tab asks which assignment a new event is for, then seeds the
  form with it (and keeps the venue locked to one the account manages). Tapping
  a day there previously created nothing.

### Localization

* **Brazilian Portuguese.** `lib/l10n/app_pt.arb` with all 176 messages, plus the
  generated `app_localizations_pt.dart`. Dates come along with it: the app feeds
  the device locale into `intl`'s `DateFormat`, and `flutter_localizations`
  bundles `pt`, so a `pt_BR` device resolves to `pt` and formats "setembro de
  2026" with Portuguese weekday abbreviations.
* `test/localization_pt_test.dart` covers what a file in the tree does not: that
  a `pt_BR` device *resolves* to Portuguese, that the strings are a translation
  rather than a copy of the template, that placeholders survive, and that the
  grid renders a Portuguese month instead of throwing on missing date symbols.

### Navigation

* New `lib/nav/destinations.dart`: one registry describing each top-bar
  destination (icon, label, location). `navActions` renders every destination
  except the current one, so every bar has the same shape and a new destination
  appears on all of them at once.
* **Fixed inconsistent icons**, the reported bug: the performer list was
  `person_search` from the calendar and the dashboard but `person_outline` from
  the sign-in page and the list itself. Icons now come from the registry, so a
  screen cannot disagree with it — and "my entities" and the calendar are reached
  from the browse lists too, where previously only a sibling link and sign-out
  were offered.
* Switched to the solid icon variants. Measured on the app bar, the outlined
  glyphs paint a fraction of the ink of the buttons beside them.
* `test/nav_destinations_test.dart` asserts, per screen, that each destination is
  offered with the registry's own icon and label, that the screen does not offer
  a link to itself, and that sign-out appears exactly where intended.

### Fixed

* **The dashboard body never rendered.** `AsyncView` read its snapshot through
  `requireData`, which treats a null value as "no data" — and a `Future<void>`
  completes with exactly that. Every render of `AsyncView<void>` (the dashboard's
  whole body) threw `StateError: Snapshot has neither data nor error`. It reads
  `snapshot.data` now, so a completed void future is the success case it is
  meant to be.
* **Loading a collection notified its listeners during a build.** `_load` set
  `_loading` and called `notifyListeners()` synchronously, and the screens that
  own their data (the dashboard, the tabbed calendar) start a forced pass from
  `initState` — which runs during a build, so `provider` threw "setState() called
  during build" and the screen mounted broken. The notification is now sent one
  microtask later: `loading` is already true when `load` returns, and no frame
  can be built before the microtask runs.

### Security

* New `1790250300_reassert_entity_write_rules.js`. The rule-reasserting half of
  `1790250000` had been applied to one database *before* that file gained its
  rule loop, and PocketBase never re-runs a migration it has recorded. The
  stranded database looked fully migrated — `createdBy`, `status`, `initiatedBy`
  all present — while `venues.createRule` and `performers.createRule` were still
  `NULL`, which PocketBase answers with "Only superusers can perform this
  action." Self-service venue creation, claiming and the whole ownership model
  were unreachable through the app. The new migration reasserts the target state
  idempotently, so it converges both a stranded database and a fresh one.
  Lesson worth keeping: editing an applied migration cannot reach databases that
  already ran it, and `scripts/verify_schema.dart` cannot see the problem because
  it inspects a fresh install where every migration runs in its final form.


* Membership moved out of embedded id lists (`venues.managerIds`,
  `performers.memberIds`) into a `memberships` collection
  (`userId`, `pendingEmail`, `targetId`, `targetType`, `role`,
  `targetOwnerId`). Rules can query
  rows, so ownership is now enforceable; an id list could not represent an
  invite for a user who has not signed up yet, and concurrent edits silently
  dropped entries. `targetOwnerId` is the target's `ownerId` denormalized by the
  hook: without a flat field to compare, the visibility rule could match only
  the member's own row and the venue owner could not list who they had invited.
* `venues` and `performers` write rules are no longer empty (empty meant
  superuser-only, which made self-service venue creation impossible); a normal
  account can now create its own venue or performer and immediately manage it.
* `venues.ownerId`, `performers.ownerId` and `events.createdBy` are set
  server-side on create and are no longer accepted from the request body.
* `pb_hooks/events.guard.pb.js` rewritten: forces `createdBy` from the session,
  requires a valid `start < end` range and a venue or at least one performer,
  authorizes writes through `memberships`, and rejects overlapping bookings
  (scanning every result page, not the first 200). `venueId` now goes through
  the same id normalizer as `performers`, so the raw/JSON-encoded shapes cannot
  bypass the overlap check.
* New `pb_hooks/entities.guard.pb.js`: sets `ownerId` and creates the initial
  `manager`/`member` membership on create, restricts update/delete to the owner
  or a linked member, and refuses to delete a venue or performer that still has
  events.
* New `pb_hooks/invites.pb.js`: pending invitations (`pendingEmail` with an
  empty `userId`) are claimed automatically on the invitee's first
  authentication.
* Events no longer expose a client-settable `status`; writes require an
  ownership proof instead.
* Deployment: the PocketBase superuser password is required
  (`${PB_ADMIN_PASSWORD:?…}`) — the stack refuses to start without it, and CI
  asserts that refusal. PocketBase is published on `127.0.0.1` only; nginx is
  the public entry point.

### Claiming and duplicates

* New `POST /api/agenda/claim` (`pb_hooks/agenda_routes.pb.js`) adopts a venue or
  performer that nobody manages. Those records existed but were unreachable: the
  seed script and the admin dashboard create records as a superuser, and the
  create hook deliberately writes no `ownerId` or membership for a superuser
  (its id is not a `users` id, so the row would name a phantom owner). Every
  write to such a record was refused to everybody.
  Claiming is idempotent, and answers `409` when somebody else already manages
  the entity — taking over a room by typing its name is a takeover, not a claim.
* Creating a record whose name matches an existing one now prompts to claim it
  instead, with "create anyway" for genuinely distinct places that share a name.
  Two records for the same venue share no id, so the schedule-conflict check
  compares `venueId` and never sees the collision — the duplicate quietly breaks
  double-booking detection for that room. The comparison
  (`lib/utils/entity_names.dart`) ignores case, spacing, punctuation and Latin
  accents, and is advisory rather than a unique constraint.
* Fixed: a performer's creator was given `role = "member"`, which
  `canAdminister` rejects — they held admin rights only through the `ownerId`
  shortcut. Every creator is now a `manager`; `member` means "may book, may not
  administer".

### Ownership is membership, not a column

* `venues.ownerId` / `performers.ownerId` renamed to `createdBy` and demoted to
  provenance. Authorization now reads only `memberships` — a `role = manager`,
  `status = active` row — so ownership is transferable and a creator can leave
  without stranding the entity. The old `ownerId` shortcut is gone.
* `memberships` gained `status` (`pending`|`active`) and `initiatedBy`
  (`invite`|`request`), and lost `targetOwnerId`. That column existed only so a
  collection rule could let an owner read the roster; the roster is now served by
  `GET /api/agenda/roster`, which authorizes by membership and resolves names.
* **Invitations require consent.** Resolving an invite to an existing account no
  longer activates it: the row stays pending until the invitee accepts via
  `POST /api/agenda/invite/respond`. Previously a mistyped or hostile invite
  granted booking rights the moment the email matched an account. A pending row
  now grants no event access at all, and an unaccepted invite no longer puts an
  entity in the invitee's calendar.
* **An entity always keeps one active manager.** Any membership change that
  would leave none is refused, so an entity cannot be locked out of
  administration by its last manager leaving.
* Roles now mean something distinct: a `manager` administers an entity, a
  `member` may book it. The roster shows both, with approve/reject for pending
  rows and role changes for active ones.
* Fixed a privilege-escalation hole in the membership guard: authorization was
  checked against the *incoming* `targetId`, so a manager of venue A could
  re-point a membership row belonging to venue B at A and inherit B's members.
  Update now freezes every identity field and accepts only `role`/`status`.
* Fixed `setState(() => _future = …)` on five screens. The arrow body evaluates
  to the assigned `Future`, which `setState` asserts against, so every refresh
  and retry aborted the frame in debug and silently failed to refetch.

### Performers reach parity with venues

* New `/performers` browse list. Venues had a browse page, a route, and entry
  points from the sign-in screen, dashboard and calendar; performers had only
  create and edit routes, so an act could not be *found* — the discovery half of
  the invite flow was missing for exactly the entities that needed it most. The
  two kinds now differ only in labels and paths.
* `lib/screens/venue_browse.dart` is replaced by `lib/screens/entity_browse.dart`,
  one screen parameterised by `TargetType`, modelled on the spec pattern already
  used by the editor. Clean cutover: no alias, no parallel copy.
* Venue and performer lists cross-link, and the sign-in screen offers both public
  lists instead of only venues.
* The dashboard gained a "browse all" action beside "add" for each kind, and a
  browse-performers action in the app bar.
* Fixed a layout overflow I introduced while adding the second browse link to the
  sign-in screen: two labelled buttons in one `Row` overflow a narrow phone, so
  they are stacked.

### Ensemble booking collisions

* A performer booking now conflicts with an overlapping event for any act that
  **shares a person** with it, not just the same act. Booking Thom Yorke solo on
  top of a Radiohead slot is refused, because Thom plays in both and the two
  performer records have no id in common.
* The relation is derived from the roster rather than stored: a performer's
  active members are the people in the act, so two acts sharing a member share a
  person. No schema change, and no second source of truth to drift from the
  roster the UI maintains.
* Only `status = active` memberships count, so an unanswered invitation cannot
  invent a collision. Any role counts, including managers — the known
  false-positive of the derived model, documented in the README.
* The check compares only against *other* events, so co-billing the band and the
  solo act on one event stays legal (that is one person playing with both).
* The refusal names the conflicting act and the person who links them, and drops
  the redundant act name when a solo act is named after the person in it —
  otherwise the message read "shares Thom Yorke with Thom Yorke".

### Joining an entity

* New `POST /api/agenda/join`: a user asks to join a venue or performer they do
  not manage, creating a `pending` + `initiatedBy: request` row. Previously the
  only way in was an invitation, which required a manager to already know the
  invitee's address — a musician who found their own venue in the public list had
  no way to ask.
* New `POST /api/agenda/roster/decide`: a manager approves or rejects a request.
  **Manager-only with no self branch**, so a requester cannot admit themselves —
  the collection already refuses a self-granted active row, and this route is
  what makes that enforcement meaningful rather than a dead end.
* New `GET /api/agenda/requests`: pending requests across every entity the caller
  actively manages, in one call, so the dashboard can surface them. Returns an
  empty list rather than `403` for a caller who manages nothing.
* New `GET /api/agenda/user-lookup?email=`: the "already has an account" hint on
  the invite form. Returns only `{exists, name}` and requires the caller to manage
  at least one entity, so it cannot be used to enumerate accounts.
* UI: a "request access" action on unmanaged venues (showing a pending state
  rather than offering the action twice), approve/reject on the entity roster for
  requests and withdraw for your own, and an access-requests section on the
  dashboard. Invitations and requests are labelled and actioned separately,
  because different people answer them.
* No email is sent: there is no SMTP configured, so discovery is in-app only. An
  invitee who never signs in will never learn of the invitation.

### Data layer

* `PocketBaseService` rewritten: every failure becomes a typed
  `PocketBaseException` with a `PbErrorKind` (so "unreachable" and "wrong
  password" are distinguishable), one shared pagination helper walks every page
  of every collection, idempotent GETs retry twice with backoff, query strings
  are built with `Uri(queryParameters:)`, and `baseUrl` defaults to `''`
  (same-origin) with the `--dart-define=PB_URL=` override intact.
* Realtime rewritten as a proper SSE client (handshake, `data:` frame parsing,
  exponential backoff 1 s→30 s, clean cancellation).
* New `RealtimeSync`: subscribes to `events`, `venues`, `performers` and
  `memberships`, debounces 500 ms, reloads loaded months and entity caches, and
  reconnects.
* `EventRepository` tracks a *set* of loaded months and reloads all of them
  after a write; the month cache is now LRU (capacity 24); the never-assigned
  `events` getter is gone; `byId` uses an id index instead of a linear scan.
* `EntityRepository.load` joins the running pass, schedules its own after a
  forced call, and guards pass identity so an obsolete pass cannot clear a
  newer one.
* Caches serve the last good value when a fetch fails and report `stale`;
  corrupt cache JSON is dropped and flagged (`cacheCorrupt`) instead of failing
  silently.
* Models: `Event` (de)serialization is hand-written and throws
  `FormatException` on a missing/unparseable date instead of substituting
  `DateTime.now()`; `build_runner`/`json_serializable` and the generated
  `event.g.dart` are gone. `Event.toMap()` emits the wire contract
  (UTC ISO-8601 `start`/`end`, real JSON array of performer ids) and never
  `createdBy`/`created`/`updated`.
* `SessionController` no longer owns repositories; the new
  `AssignmentsController` derives my venues/performers, pending invites and
  membership from the session plus the three caches.

### UI

* New and rewritten screens: venue browse, sign-up, my-entities dashboard,
  tabbed calendar, single-entity calendar,
  `VenueEditPage`/`PerformerEditPage` (`lib/screens/entity_edit.dart`) with
  invite management, and an event form with a searchable venue/performer picker.
* Routes are explicit paths (`/venues`, `/venues/:id/edit`, `/dashboard`,
  `/calendar/:type/:id`, `/events/:id/edit`, …) with redirects: unauthenticated
  users only reach `/` and `/signup`; an authenticated user on `/` or `/signup`
  lands on `/calendar` when they have assignments, otherwise `/venues`.
* Localized, user-facing error text via `errorText` (server prose when present,
  localized transport-failure text otherwise); Spanish (`es`) added next to
  English.
* Venue and performer listing is readable by any authenticated account on
  purpose — public signup is only useful if a new user can find what they
  belong to — while `memberships` rows stay private to the member and invitee.

### Deployment

* `docker-compose.yml`: required `PB_ADMIN_PASSWORD`, `PB_URL` build arg with a
  same-origin default, PocketBase published on `127.0.0.1:8090`, healthcheck
  gating the app container.
* `docker/nginx.conf`: reverse-proxies `/api/` to PocketBase (making the app
  single-origin, which is what removes the old absolute-URL/cross-origin
  requirement) with the realtime stream configured correctly
  (`proxy_buffering off`, `proxy_cache off`, `proxy_read_timeout 3600s`,
  HTTP/1.1 with `Connection` cleared), plus security headers, the SPA fallback
  and immutable `/assets/` caching.
* New `docker/nginx-tls.conf.example`: TLS server block with HSTS and an
  HTTP→HTTPS redirect, documented with the compose mount for certificates.
* `Dockerfile`: still multi-stage, Flutter pinned to the CI version, no
  codegen step.
* CI: two real jobs. `flutter` (pinned toolchain, a drift guard across the
  workflow/Dockerfile/README, format check, analyze, test, release web build)
  and `backend` (downloads and sha256-verifies PocketBase 0.38.2, boots it on a
  temp data dir against `pb_migrations/` + `pb_hooks/`, runs the integration
  scripts, validates `docker-compose.yml`, and asserts it fails without
  `PB_ADMIN_PASSWORD`).
* `.env.example` documents the required password and the optional same-origin
  `PB_URL`; `.gitignore` drops generated `lib/l10n/app_localizations*.dart` and
  backend temp dirs, and keeps `pb_data/` ignored.

### Tests

* New backend integration tests: `scripts/guard_test.dart` (validation,
  ownership, double-booking, invites) and `scripts/verify_schema.dart`
  (migration snapshot against the client contract). Both self-boot the shipped
  PocketBase on a throwaway data dir, so no running server is required.
* Client tests for event parsing, calendar recurrence math, the repository
  caches, and a widget smoke test.
