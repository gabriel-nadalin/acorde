# Acorde — development guide

(The product is named in Portuguese, the language it ships in; the Dart package
and the deployment identifiers are `acorde`.)

The engineering document: architecture, the reasoning behind each decision,
deployment, tests and the pinned toolchain. For what the app is and how to run
it, see [README.md](README.md) — which is in Portuguese, the language the app
itself ships in.

Event calendar for venues and performers. A venue manager approves a booking,
a band sees its own dates, and both sides see the same calendar — a small
multi-tenant scheduling app, not a public listings site.

* **Client:** Flutter web (`go_router` + `provider`), compiled to static files.
  Web is the only platform: the Android/iOS/macOS/Windows/Linux scaffolding was
  deleted, because five targets that are never built are five things to keep in
  step for no feedback. `flutter create --platforms=<name> .` restores one.
* **Backend:** PocketBase (SQLite + REST + realtime), with the collection schema
  in migrations and the authorization rules in JavaScript hooks.
* **Deployment:** two containers — nginx serves the bundle and reverse-proxies
  `/api/` to PocketBase, so the browser only ever sees one origin.

---

## Architecture

### Data model

| Collection | Purpose |
|---|---|
| `venues` | A room/hall. `name` (required), `address`, `capacity`, `timezone`, `contact`, `createdBy`. |
| `performers` | A band/solo act. `name` (required), `contact`, `type`, `createdBy`. |
| `memberships` | Who may act for a venue or performer: `userId`, `pendingEmail`, `targetId`, `targetType` (`venue`\|`performer`), `role` (`manager`\|`member`), `status` (`pending`\|`active`), `initiatedBy` (`invite`\|`request`). |
| `events` | A booking: `title`, `description`, `start`, `end`, `venueId`, `performers` (json array of ids), `createdBy`, `seriesId`, `recurrence`. |

`createdBy` (venues, performers) and `createdBy` (events) are set **server-side**
on create and are never taken from the request body: the client cannot grant
itself ownership.

`createdBy` is **provenance, not authority**. It records who entered a record; it
grants nothing. Every access decision is a `memberships` row with
`role = manager` and `status = active`, which is what makes ownership
transferable and lets a creator step away.

### Times are UTC on the wire, local on screen

`events.start`/`end` are stored as explicit UTC instants and written that way by
`Event.toMap`, because month queries and the server's overlap check compare them
lexically — a naive local time would misalign at a month boundary. Every screen
renders them through `toLocal()`, so the schedule is read on the *viewer's* clock
and two people in different zones see the same booking at different wall times.

`venues.timezone` does not participate. It is free text on the venue record, kept
because bookers write it down, and read by nothing: making it authoritative would
mean every screen resolving a zone per venue, plus a real picker in place of the
text box. The field is documented as a note so it does not read as a promise.

### Why membership is its own collection

The obvious shortcut is an id list on the venue (`managerIds`) and on the
performer (`memberIds`). Both existed and were removed. A join collection wins
for reasons that are not stylistic:

1. **Rules can traverse it.** `memberships.targetId` holds the id as text just
   like `managerIds` would, but a *row* can be queried directly
   (`targetType = 'venue' && targetId = X && userId = @request.auth.id`) and the
   guard can join against it for any venue or performer, including ones the
   user does not own. An embedded list only exists inside the record you already
   loaded, so it cannot answer "may this user touch this event?" for arbitrary
   records without an extra round trip per record.
2. **Invites for people who do not exist yet.** A membership can carry
   `pendingEmail` with an empty `userId`. The user is invited before they sign
   up; `pb_hooks/invites.pb.js` claims every pending row for that address the
   first time the account authenticates. An id list cannot represent an
   invitation to someone with no account.
3. **Concurrency.** Adding a manager means appending one row. With an embedded
   list, two simultaneous edits both read the list, each appends, and the last
   write wins — the other invite silently disappears.
4. **Roles and provenance.** `role`, `created`, `pendingEmail` are per
   relationship. There is nowhere to put them on an id in an array.
5. **Growth.** A venue with hundreds of staff writes hundreds of short rows
   instead of one ever-growing text field that is rewritten on every edit.

### Why authorization lives in hooks, not only in collection rules

PocketBase rules are a boolean expression over one record plus the request. They
are the right tool for "who may read this row", and they are used for that:

* `venues` / `performers` / `events`: list and view require
  `@request.auth.id != ""`.
* `memberships`: list and view are restricted to
  `userId = @request.auth.id || pendingEmail = @request.auth.email || targetOwnerId = @request.auth.id`.

  The third clause needs `targetOwnerId` (the target's `ownerId`, denormalized
  onto the row by the hook) purely because rules cannot traverse a plain-text
  `targetId`. Without it the rule matched only the member's own row, so the
  venue owner — the one person who is supposed to manage the roster — could not
  list the people they had invited. It is server-maintained and safe to
  denormalize because `ownerId` is set once at create and there is no ownership
  transfer.

They cannot express the two things this app actually needs:

* **Ownership across records.** `events.venueId` and `events.performers` are
  plain text/json fields holding ids, not relations, so a rule cannot walk
  `venueId -> venues.ownerId` or `performers -> memberships`. (PocketBase answers
  `field "venueId" is not a valid relation`.) The same applies to writes.
* **Whole-request validation.** `end > start` across two fields, "booked at a
  venue or by a performer", and "no overlapping booking for the same venue or
  performer" are all multi-record conditions. Additionally `users.createRule`
  is public — anyone can mint an account — so "authenticated" is not an
  authorization boundary by itself.

So the rules stay permissive at the "authenticated" level and the JavaScript
hooks narrow them:

* **`pb_hooks/events.guard.pb.js`** — one handler for every event write: forces
  `createdBy` from the session, requires a valid `start`/`end` range, requires a
  venue or at least one performer, then allows the write only when the user has
  a `memberships` row for the venue, or for any booked performer, or created the
  event; finally rejects overlapping bookings for the same venue or any shared
  performer, walking **every** result page. It is one handler on purpose —
  PocketBase extracts each handler by source text into a pooled VM, so helpers
  must live inside the handler body, and a second handler would need its own
  copy of the id normalizer.
* **`pb_hooks/entities.guard.pb.js`** — sets `ownerId` and creates the initial
  `manager`/`member` membership on create; allows update/delete to the owner or a
  linked member; refuses to delete a venue or performer that still has events
  ("Remove or reassign them first.").
* **`pb_hooks/invites.pb.js`** — promotes pending invitations on sign-in.
* **`pb_hooks/agenda_routes.pb.js`** — `POST /api/agenda/claim`, the one write
  that cannot be a collection rule. The `memberships` create rule requires you to
  *already* manage the target, which is right for invites and impossible for a
  claim: the entire point is that nobody manages the entity yet. A handler can
  ask the opposite question ("is this unmanaged?"), a rule cannot.

### Claiming an existing venue or performer

Self-serve creation means an entity's creator owns it, but the seed script and
the admin dashboard create records as a **superuser**, which carries no `users`
id to record as a manager. Those records were reachable by nobody — no owner and
no membership row, so every write was refused. `POST /api/agenda/claim` adopts
them:

* **Unmanaged** → the claimer becomes `manager`, and `ownerId` is filled in if
  blank so the roster rule can see them. Idempotent: claiming twice is one row.
* **Already managed by somebody else** → `409`, because taking over a room by
  typing its name is not a claim, it is a takeover. That path is a join request,
  which the existing managers approve — see "Asking to join" below.

The client offers this automatically. Because venue duplicates are the failure
that actually hurts — two records for one room share no id, so the
schedule-conflict check never sees the collision — creating a record whose name
matches an existing one (`lib/utils/entity_names.dart` compares case-,
whitespace- and punctuation-insensitively, folding Latin accents) prompts to
**claim it instead**, with "create anyway" for genuinely distinct places of the
same name. It is a prompt, not a constraint: two people submitting at the same
moment both pass the check, and demanding unique names would block two real
venues that share one.

### Roles, consent and the roster

**`role` decides what you may do.** A `manager` administers an entity — rename,
delete, invite, evict, re-role. A `member` may book events for it and nothing
else. The events guard deliberately accepts *any* active membership, so a band
member can create their own gigs without being able to rename the band.

**`status` decides whether you may do anything at all.** An invitation is a
`pending` row: it grants no event access and puts nothing in the invitee's
calendar until they accept it (`POST /api/agenda/invite/respond`). Resolving the
invitation to a real account therefore no longer activates it — matching an email
is not consent, and treating it as consent meant a mistyped invite silently
granted someone booking rights.

**The roster is served by `GET /api/agenda/roster`, not by the collection.**
`memberships.listRule` is self-only — my rows, plus invitations addressed to my
address — which is the right privacy default and useless as a team list. A rule
cannot express "every row of an entity I actively manage", because `targetId` is
plain text rather than a relation, so the endpoint authorizes by membership and
resolves display names server-side. A plain `member` gets `403` from it.

### Asking to join

An invitation only works if a manager already knows the address. `POST
/api/agenda/join` is the other direction: a user who finds a venue in the public
list (or a performer) asks for access, and a manager approves it. It creates the
same kind of `pending` row as an invitation, marked `initiatedBy: request`, so it
grants nothing until a manager acts.

**A requester cannot approve their own request** — `POST /api/agenda/roster/decide`
is manager-only with no self branch. That is the whole point of routing requests
through their own endpoint instead of letting a user write a membership row: the
collection deliberately refuses a self-granted active row.

`GET /api/agenda/requests` is the manager-side aggregate — every pending request
across the entities you actively manage, in one call. It returns an empty list
(not `403`) for a caller who manages nothing, because the common case for a new
account is legitimately "nothing waiting".

`GET /api/agenda/user-lookup?email=` backs the "they already have an account"
hint on the invite form. It returns only `{exists, name}` and requires the caller
to manage at least one entity — otherwise it would be an email-enumeration oracle
open to every account.

**Email is optional, and membership works without it** — but only in the
degraded way. Discovery is in-app: pending invitations and incoming requests
appear on the dashboard, so an invite is real the moment it is written, and a
manager sees a request whenever they next look.

Configure `PB_SMTP_*` (see `.env.example`) and two messages are sent
automatically, which is what turns membership into a loop that can reach people
who are not already looking:

* an invitation, to the address a manager invited;
* a "somebody asked to join" notice, to every active manager of that entity —
  without it, *"someone asked to play my room"* sits unanswered until somebody
  happens to open the app.

Both are sent from `pb_hooks/mail.pb.js`, as a side effect of the `memberships`
row being written. A mail failure is logged and swallowed: the row is already
committed, and failing the write over a mail server would leave the manager
retrying a row that exists. Sending is synchronous inside the request, so a relay
that hangs delays the response until PocketBase's own mailer timeout — the honest
tradeoff against losing the message with no record of it.

The invitation names who sent it, from `memberships.invitedBy`. That column
exists for this and nothing else: it is written on create from the authenticated
caller (`entities.guard.pb.js`), forced back to its stored value on every update,
and read by no authorization check — provenance in the same sense as
`venues.createdBy`. Two properties are guarded in `scripts/guard_test.dart`
because both are about the record being true rather than convenient: a client
cannot name somebody else as the inviter, and cannot rewrite it afterwards. It is
left empty when an invite comes from a superuser or from a script, since a
superuser's auth id is not a `users` id; the message then uses a form that names
nobody rather than a name nobody can resolve.

**An entity always keeps at least one active manager.** The server refuses any
membership change that would leave none, including a manager removing
themselves, because an entity with no manager is one nobody can administer — the
state the claim route exists to rescue.

### Browse lists

Venues and performers each have a public browse list (`/venues`, `/performers`),
reachable from the sign-in screen, the dashboard and the calendar, and each
cross-links to the other. They are also reachable **without a session** — the
sign-in screen offers both to a visitor, and the router lets those two routes
through (the allowlist comes from `Destinations.public`, so a list is declared
public in exactly one place). One screen (`lib/screens/entity_browse.dart`)
serves both kinds; they differ only in labels, paths and the loaded repository,
which live in a private `_BrowseSpec`. Two near-identical files would drift the
moment one gained a feature, and the equivalence is the point.

Per row: manage what you manage (book an event, edit it), ask to join what you do
not, and see a pending state rather than being offered the same request twice.
Signed out there is no per-row action at all and no create button — every one of
them describes a relationship between an account and the entity, and a visitor
has none — so the row reduces to its title and the calendar it opens. The top bar
narrows the same way: only destinations the session can actually open, and
*Entrar* where *Sair* would be.

### What is next

`/upcoming` answers "what have I got coming up" — the question somebody actually
opens the app with, where the calendar answers "what is on this day".

It is one query, not a scan of months: `end > now`, sorted by `start`. The bound
is on **`end`** deliberately. A booking that began an hour ago and runs for
another hour is the most immediate thing on the schedule, so asking only for
future *starts* would hide it until it was over.

**The query returns every event on the server; the screen shows this account's.**
The repository cannot narrow it — "mine" is a question about the viewer — so it
hands back what the server reported and the screen applies `eventInScope`
(`lib/utils/event_scope.dart`) before the display cap. That order matters:
capping in the repository, before the scope is known, would let other people's
bookings fill the fifty-row window and push this account's off the end.

The same predicate decides the calendar's marks and this list's rows, which is
what makes tapping a day header land somewhere coherent. They used to be two
implementations — `events_list.dart` filtered by its copy, `upcoming.dart`
coloured by its — so a booking touching none of your assignments was listed and
then missing from the month the tap opened. `test/event_scoping_test.dart` holds
the two screens to the same answer, booking for booking.

Rows group under the month, and then the day they fall on, because a schedule
read at a glance is read by day — and a long list needs the month boundaries,
which the day headers alone do not give. A day header opens the calendar on that
day's month. The dashboard carries a three-row preview of the same list, so the
answer is visible without a tap.

Like the month cache, the result is kept in memory with a `stale` flag rather than
thrown away: an offline user sees their schedule with a warning instead of an
error. It is dropped on sign-out — the next account must not inherit the previous
one's calendar.

### Deleting an event

Available wherever an event is shown: the upcoming list, a row in a calendar
day sheet, and the edit form. All three call one `confirmDeleteEvent`, so they
ask the same question.

The question that matters is a repeating one. Deleting "the event" on one
Wednesday of a weekly booking is almost never what somebody means, and the
reverse mistake — deleting the whole series when they meant one night — cannot
be undone. So a series instance is asked about explicitly, with the occurrence
count on the button and the count read from the server's own stored instances
rather than recomputed from the rule (a locally recomputed count could promise
more than exist).

Deletion is offered **only** where the server would accept it: a venue the
account manages, an act it belongs to, or an event it created — the same rule
`pb_hooks/events.guard.pb.js` enforces. A delete that comes back 403 is worse
than no button at all.

### Navigation

The dashboard is the app's home, defined once as `kHomeLocation` and used by both
the router's redirect and the sign-in form. Those two used to decide it
separately and disagreed — the redirect sent a new user to the calendar while the
form sent them to the venue list — so which landing route won depended on which
ran last.

The destinations are **siblings, not levels**, and the top bar navigates between
them laterally (`GoRouter.replace`): no stack grows, no animation plays, and back
from any of them returns home. Pushing them onto each other would make back mean
"the last tab I looked at" and leave a history the user never asked to revisit.

Drill-downs — an entity editor, the event form, a venue's calendar opened from a
list — do **push**, and their back returns where the user came from. That is the
distinction: lateral moves between top-level pages replace, going deeper pushes.

The dashboard has no back arrow: it is home, and while signed in the router
redirects the sign-in route straight back to it, so an arrow there would have
nowhere honest to go. The way out of the signed-in area is sign-out.

Each screen draws **one** bar, and the calendar's is the tab host's. Its tabs are
embedded pages (`EventsListPage(embedded: true)`) that render no bar of their own:
before that, the host's bar ("Calendário", with the destinations) sat above each
tab's ("Meu calendário", with the back arrow), which put the back button in the
middle of the screen instead of the leading position every other screen uses — and
left the calendar the only screen without sign-out, because the second bar's
actions overrode the first's. The host bar now carries the back arrow, one
refresh for every loaded month, the destinations, and sign-out, so all four
screens have the same shape.

### Creating an event from a calendar

Every calendar view creates events, and all four reach it the same way: the
page's `_createEvent` (`lib/screens/events_list.dart`). The FAB, an empty day
cell and the day sheet's "Add event" all go through it, so they cannot disagree
about what a new event is seeded with.

What differs per view is only *what the event is for*, which is what the route
location carries:

| View | Seed |
|---|---|
| venue calendar | `venueId` + `lockVenue` — one venue, and it is fixed |
| performer tab / `/calendar/performer/:id` | `performerId`, venue left open |
| combined tab | asks which assignment, then seeds that one |

A performer page leaves the venue open on purpose: an act plays wherever it is
booked, so the venue is a choice rather than a property of the page. Only a venue
page locks it, because there the venue *is* the page.

Writing is gated on one flag, `_canWrite`, and it is derived from what the server
would accept rather than from what looks tidy: a venue this account manages, or
an act it belongs to. Everything else is read-only, because the write would come
back 403. Creation and editing read the same flag, so no view offers one while
withholding the other. The combined tab is the one case that has to ask instead
of assuming, since it covers several assignments at once — and asking also keeps
the venue locked to one this account manages.

### One destination, one icon

Every top bar is built from a single registry (`lib/nav/destinations.dart`): a
destination is an icon, a label and a location, declared once in
`Destinations.all`. A screen renders `navActions(context, current: …)`, which
lays out every destination except the one it is on.

This exists because the alternative already failed. The performer list was
reached with `person_search` from the calendar and the dashboard but with
`person_outline` from the sign-in page and from the list itself — one feature
drawn as two, with nothing to notice the drift short of opening every screen.
Now the icon is read from the registry, so a screen cannot disagree with it, and
`test/nav_destinations_test.dart` asserts exactly that on each screen.

Adding a destination is one entry in `Destinations.all`; it appears on every
screen at once. Adding a *kind of entity* is one line in `entityIcon`, which the
browse list, its rows and the account picker all share.

The icons are the solid variants (`location_on`, `person`, `dashboard`,
`calendar_month`, and a clock for upcoming), not the outlined ones. The outlined ones only read as glyphs at a distance at 24px;
measured against the app bar, the solid set paints several times the ink and
survives the avatar beside it.

One caveat worth keeping: an icon existing in `Icons` does not mean it renders
under the tree-shaken web font. `Icons.event_available` painted nothing at all —
button laid out, sized, tappable, and visibly empty — while every other icon
beside it drew normally, and the glyph was present in the generated subset with a
valid outline. `test/nav_destinations_test.dart` cannot catch that (it asserts the
widget tree, where the icon is correct); a web build has to be looked at.

### Recovering an account

`/forgot-password` requests a link, `/reset-password?token=…` spends it. Both are
public — the visitor following a reset link is normally signed out, and the
router's redirect exempts them, because bouncing that visitor to the sign-in
screen they cannot get past is the whole reason the link exists.

**A reset can only arrive if the deployment has a mailer.** PocketBase answers
`request-password-reset` with 204 for every input — an address with an account,
one without, and a server with no SMTP configured alike — because answering
differently would make the endpoint an email-enumeration oracle. The cost is that
it cannot report a reset that will never arrive, so "the request was accepted" and
"an email is on its way" are different claims and only the first is true by
default. The form therefore asks `GET /api/agenda/mail-status` first, and with no
mailer says so and points at the administrator path (resetting from the PocketBase
dashboard), which always works, instead of at an inbox that will stay empty.

**`PB_APP_URL` must be the app's public origin, not the backend's.** PocketBase
builds the link from its stored `appURL`, whose default is `http://localhost:8090`
— the *backend* port, which serves no app and which the recipient's browser
cannot reach. `pb_hooks/mail.pb.js` applies `PB_APP_URL` from the environment on
boot, and `1790300000_password_reset_link.js` rewrites the built-in template from
the dashboard's own reset page (`{APP_URL}/_/#/auth/confirm-password-reset/{TOKEN}`,
which lands in this app's SPA catch-all and renders nothing) to the app's route.
Both halves are needed: the template decides the path, `PB_APP_URL` decides the
host, and getting either wrong produces a link that fails only in the recipient's
mail client.

### Guest sign-in

*"Entrar como visitante"* is on the sign-in screen by default: one tap, no address,
no password, into a throwaway account. It is on by default because this is a
prototype and a demo button that requires editing a file first is off in every
demo — the reviewer clones the repo, runs it, sees the same form as before.
`PB_GUEST_LOGIN=0` (`false`/`off`/`no`) turns it off; any other value, including
unset and empty, leaves it on, so a typo cannot silently close the demo path.

The trade is real and stated plainly: an untouched deployment does mint accounts
with no verified address. A guest gets nothing from that beyond an empty account
(no assignments, no elevated rights, same rules and rate limits as any signup), and
the escape hatch is one environment variable — but a deployment with real users
should set it to `0`.

**A guest is an ordinary account.** The client generates the credentials
(`guest-<timestamp><random>@guest.invalid`, a 24-character password) and creates
the record through the *same public signup endpoint* any self-service
registration uses. `pb_hooks/guest.pb.js` deliberately cannot create records — it
only reports the capability. One account-creation path in the system instead of
two, and every existing rule, guard and rate limit applies to guests unchanged.
The `.invalid` TLD is reserved and can never resolve, so a guest address can never
collide with, or receive mail meant for, a real one.

**The switch lives on the server, and the client asks.** The button is gated on
`GET /api/agenda/guest-status`, not on a build flag: a deployment can turn guest
sign-in off without shipping a new bundle, and the client never offers a button
the server would refuse — the failure mode this app has already shipped once, when
the sign-in screen advertised two browse lists that no route and no rule allowed.
The probe mirrors `mail-status`: one bit about server configuration, no user data,
and read so that *a failed probe withholds the button* rather than offering a dead
end. The ordinary signup form is always there, so the fallback is never a dead end
either.

**A guest is not anonymous at the API.** It holds a real session, so it can read
events and its own (empty) membership rows like any new account, and it lands on
the dashboard with nothing in it. What it cannot do is see anybody else's
memberships — the same rule that bounds every other account bounds this one.

### Languages

**Brazilian Portuguese only** (`lib/l10n/app_pt.arb`), generated by
`flutter gen-l10n` into `lib/l10n/app_localizations*.dart`. `app_pt.arb` is both
the only locale and the template file, so the base class is generated from the
language actually shipped.

Two languages were removed on purpose. Every extra locale is a per-feature tax —
three edits for every new string, and every one of those edits a chance to fall
out of step — paid by a prototype whose UI is still moving. Adding one back is
mechanical: a second `app_xx.arb`, and `supportedLocales` grows.

Worth knowing: cutting to one locale immediately surfaced a real layout bug the
English strings had hidden. The day sheet's header was an intrinsic-width `Text`
beside a button, which overflowed the Material bottom sheet once the date was
spelled out in Portuguese. The fallback for a device set to a language the app
does not ship is the single locale, so there is no second language to hide behind
— `test/localization_pt_test.dart` pins that resolution.

Dates are the part that bites. The locale is taken from the device and passed to
`intl`'s `DateFormat`, and `intl`'s date symbols must be loaded for it — a locale
whose *strings* exist but whose *symbols* were never initialized fails at the
first `format()` call, on a screen far from the locale files.
`flutter_localizations` loads them, and it bundles `pt` (not `pt_BR`), so a
`pt_BR` device resolves to `Locale('pt')` by language; the app must pass a tag
`intl` can resolve or every date throws. `test/localization_pt_test.dart` pins
both the resolution and the formatted output.

### Booking collisions

A booking is refused when it overlaps another event for the same **venue**, the
same **act**, or an act that **shares a person** with it. The third case is the
ensemble one: a solo set for Thom Yorke cannot sit on top of a Radiohead slot,
because Thom plays in both. The two performer records share no id, so only the
roster can tell they are the same human being.

    Schedule conflict: Radiohead is already booked in this time range, and
    shares Thom Yorke with this booking.

"Who plays in what" is **derived, not stored**: a performer's active members
*are* the people in the act — the edit screen calls the section "Members" and the
invite "Invite member" — so two acts sharing a member share a person. A stored
`lineup` field would be a second source of truth that drifts from the roster the
UI actually asks users to maintain.

The deliberate consequences:

* **Only active memberships count.** An unclaimed invitation is not a person in
  the act, so it cannot invent a collision between two acts.
* **Any role counts, including managers.** A shared manager or agent — somebody
  who administers two acts without playing in either — will register as a shared
  person and block the overlap. That is the known false-positive of the derived
  model. It is the right default for the common case (a musician in two bands)
  and can be tightened to a dedicated "plays in" role if agents turn out to
  share performer rosters.
* **Co-billing is allowed.** Booking the band *and* the solo act on one event is
  legitimate — that is the same person playing with both — so the check only
  compares against *other* events.
* **Same act twice is still caught** by its own check, not by shared members: an
  act with no members at all (a one-off, a DJ) must still collide with itself.

### Read access is deliberately open, membership is not

The **venue and performer lists are readable with no session at all** — open to
anyone who opens the app, account or not. That is what makes them a shop window:
the visitor who cannot sign in is exactly the person who needs to find the room
they work at so they can ask to join it, and asking to join is the only thing
that requires an account. Their `listRule`/`viewRule` are `""` for that reason
(`1790400000_public_entity_lists.js`); every write stays authenticated and
ownership-narrowed in the hooks.

Any authenticated account may also read events. That is what makes public signup
useful: a new user can find the venue they work at and the act they play in, see
the calendar, and then be invited. Locking listings to members would make the
invite flow impossible, because you cannot be invited to something you cannot see.

**Membership rows are private**, and so is every write: the roster of who manages
what, pending invite addresses included, is visible only to that member and to the
invitees themselves. Read-open, write-guarded.

The rule that expresses that is gated on there being a session, and the gate is
load-bearing rather than decorative: a PocketBase rule is a **filter**, not a
predicate, so a list rule that fails is not a `403` — it is a query that matches
nothing, and one that accidentally matches everything is indistinguishable from a
correct one until somebody measures it. `userId = @request.auth.id ||
pendingEmail = @request.auth.email` looked self-only and was, for signed-in
callers; for an anonymous one both sides resolve to the empty string, and
`pendingEmail = ""` matched every claimed row (`1790400100`). Anyone could list
the whole membership graph with no token. When touching a read rule here, ask what
it evaluates to for `@request.auth.id = ""`.

### Client behaviour worth knowing

* **Realtime:** `RealtimeSync` subscribes to `events`, `venues`, `performers`
  and `memberships` over the PocketBase SSE endpoint, debounces 500 ms, reloads
  the loaded months and entity caches, and reconnects with backoff.
* **Offline tolerance:** entity and event caches persist to
  `SharedPreferences`. A failed fetch serves the last good value and marks the
  cache `stale` (surfaced in the offline banner); corrupt cache JSON is dropped
  and flagged instead of silently ignored.
* **Errors:** every non-2xx response becomes a `PocketBaseException` with a
  `PbErrorKind`, so "backend unreachable" and "wrong password" are different
  messages instead of one generic failure.

---

## Running locally

Requirements: Flutter **3.44.0** (see [Toolchain versions](#toolchain-versions)).
Docker is optional and only needed for the container path.

### 1. Backend

```bash
./pocketbase superuser upsert admin@example.com 'change-me'   # first run only
./pocketbase serve                                            # 127.0.0.1:8090
```

`serve` applies `pb_migrations/` to `pb_data/data.db` on startup and loads the
JavaScript guards from `pb_hooks/`. Delete `pb_data/` to start from the
migration snapshot again — `pb_data/` is gitignored and holds the superuser
credentials, so never commit it. The dashboard is at
<http://127.0.0.1:8090/_/>.

The binary is not committed. Any 0.38.2 build works; this repo was developed
against the official `pocketbase_0.38.2_linux_amd64.zip` release asset.

### 2. Web client

```bash
flutter pub get
flutter run -d chrome --dart-define=PB_URL=http://127.0.0.1:8090
```

`PB_URL` is compiled into the bundle and resolved by the **browser**, so in the
dev flow it must point at the backend from the client machine. The default is
empty, which means "same origin" — correct for the nginx deployment below, and
wrong for `flutter run`, where the dev server is on a different port.

### 3. Docker Compose

```bash
cp .env.example .env      # then set a real PB_ADMIN_PASSWORD
docker compose up --build # http://localhost:8080
```

The stack refuses to start while `PB_ADMIN_PASSWORD` is unset — there is no
fallback value, by design. Then open <http://localhost:8080> and sign up; the
first account is a normal user, not an admin. PocketBase's dashboard stays on
<http://127.0.0.1:8090/_/> (see [Deployment](#deployment)).

**If the build fails at `flutter pub get` with `Got socket error trying to find
package … at https://pub.dev`,** that is BuildKit's network namespace on this
host, not the project: the same image reaches pub.dev fine under
`docker run`, and GitHub's runners are unaffected. Build with the legacy builder:

```bash
DOCKER_BUILDKIT=0 docker compose up -d --build
```

---

## Tests

```bash
flutter test        # client unit/widget tests
flutter analyze
```

### Backend integration tests

Both scripts are self-contained: they start the shipped `./pocketbase` binary on
a temp data directory, apply `pb_migrations/`, load `pb_hooks/`, drive the HTTP
API, and tear everything down. They touch neither `pb_data/` nor a running
server, so they are safe to run repeatedly and in parallel with a dev instance.

```bash
dart run scripts/guard_test.dart     # ownership, validation, double-booking
dart run scripts/verify_schema.dart  # migration snapshot vs. the client contract
```

Optional overrides: `PB_TEST_URL` (drive an already-running instance instead of
booting one), `PB_TEST_ADMIN_EMAIL`, `PB_TEST_ADMIN_PASSWORD`,
`PB_TEST_BINARY` (default `./pocketbase`), `PB_TEST_PORT` (default: a free port).
With no variables set, everything has a default.

`scripts/create_pocketbase_collections.dart` and `scripts/seed_pocketbase_data.dart`
push schema and demo records onto a *running* instance. They authenticate with
`PB_URL` plus either `PB_ADMIN_EMAIL`/`PB_ADMIN_PASSWORD` or a Netscape-format
cookie file, whose path is `PB_COOKIE` (default `.pb_cookie`, which `.gitignore`
excludes).

---

## Deployment

`docker compose up -d` starts two services:

* **`pocketbase`** — data in `./pb_data` (bind mount), migrations from
  `./pb_migrations`, hooks from `./pb_hooks`. Published on
  **`127.0.0.1:8090` only**: it is reachable by local tooling (`curl`, the
  integration tests, the dashboard) but is not exposed publicly.
* **`app`** — the nginx image built by the `Dockerfile`: the compiled web
  bundle plus a reverse proxy for `/api/`, published on `0.0.0.0:8080`.

**The nginx container is the public entry point.** It proxies `/api/` to
`http://pocketbase:8090/api/`, which is what makes the app single-origin: the
bundle is built with an empty `PB_URL`, the browser makes no cross-origin
request, and "PocketBase must be reachable from the client machine at the same
URL the build embedded" stops being a deployment constraint. The `/api/` block
also disables buffering and raises the read timeout to an hour so the realtime
SSE stream is not cut (see `docker/nginx.conf`).

Note that nginx resolves the `pocketbase` hostname when the config loads. If the
backend container is recreated with a new address, run
`docker compose restart app`.

### TLS

The shipped nginx config speaks HTTP. To terminate TLS:

1. Put `fullchain.pem` and `privkey.pem` in `./certs` (or point the config at
   wherever they live).
2. `cp docker/nginx-tls.conf.example docker/nginx-tls.conf` and edit
   `server_name` and the certificate paths.
3. Mount it over the bundled config and publish 443 — the file is a drop-in
   replacement for `docker/nginx.conf`, so the two never fight over port 80:

   ```yaml
   services:
     app:
       ports:
         - "80:80"
         - "443:443"
       volumes:
         - ./docker/nginx-tls.conf:/etc/nginx/conf.d/default.conf:ro
         - ./certs:/etc/nginx/certs:ro
   ```

4. `docker compose up -d`. Port 80 now only redirects to HTTPS.

The example adds HSTS and forwards `X-Forwarded-Proto https` (PocketBase builds
password-reset and file URLs from it). Certificates are mounted, never baked
into the image. Terminating TLS upstream instead (cloud LB, Caddy, Traefik) is
equally fine — only the public entry point has to speak TLS.

### CI

`.github/workflows/ci.yml` runs two jobs on every push and pull request:

* **`flutter`** — pinned toolchain check (Dockerfile ↔ workflow ↔ DEVELOPMENT),
  `pub get`, `dart format --set-exit-if-changed` (a gate), `flutter analyze` with
  infos fatal,
  `flutter test`, `flutter build web --release`.
* **`backend`** — downloads PocketBase 0.38.2 (sha256-verified), boots it on a
  temp data dir against `pb_migrations/` + `pb_hooks/`, runs the two integration
  scripts above, and validates `docker-compose.yml` — including asserting that
  the stack *fails* without `PB_ADMIN_PASSWORD`.

## Toolchain versions

| Component | Version | Where it is pinned |
|---|---|---|
| Flutter | 3.44.0 | `.github/workflows/ci.yml` (`FLUTTER_VERSION`), `Dockerfile` |
| Dart | 3.12.0 | ships with Flutter 3.44.0; floor is `^3.12.0` in `pubspec.yaml` |
| PocketBase | 0.38.2 | `docker-compose.yml`, `.github/workflows/ci.yml` |
| nginx | 1.27-alpine | second stage of the `Dockerfile` |

Newer stable Flutter releases build this project too, but CI and the deployed
image both use 3.44.0, and the `flutter` job fails if the workflow, the
`Dockerfile` and this table disagree. Bump all of them together.

## Project layout

```
lib/            client: models, data (repositories, realtime), services, screens, widgets, l10n
pb_migrations/  collection schema (source of truth for a deployed backend)
pb_hooks/       the JavaScript guards described above
scripts/        schema/collection tooling and the backend integration tests
test/           client tests
docker/         nginx config + the TLS example
```
