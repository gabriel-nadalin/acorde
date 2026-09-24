import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/membership.dart';
import '../router_paths.dart';

/// A place the user can go, described once.
///
/// The icon, the label and the location of a destination live here and nowhere
/// else. Before this module existed the performer list was reached with
/// `person_search` from the calendar and the dashboard but with `person_outline`
/// from the sign-in page and the list itself — one feature drawn as two, with
/// nothing to notice the drift short of opening every screen. Adding a
/// destination now means adding one entry to [Destinations.all]; every top bar
/// picks it up.
class Destination {
  const Destination({
    required this.icon,
    required this.label,
    required this.location,
    this.requiresAuth = true,
  });

  /// Leading icon, wherever this destination is offered.
  final IconData icon;

  /// Tooltip and accessible name, resolved per locale.
  ///
  /// Required rather than optional: these buttons carry no visible text, so the
  /// tooltip is the only thing naming them (`find.byTooltip` reads it, and so
  /// does a screen reader). An icon-only button without one is unlabelled.
  final String Function(AppLocalizations l10n) label;

  /// Route location to navigate to.
  final String location;

  /// Whether opening this destination needs a session.
  ///
  /// Declared here, once, because two very different layers have to agree about
  /// it and used to disagree in silence: [navActions] must not offer a button
  /// that the router will refuse to open, and the router's redirect must let
  /// through exactly the destinations that are meant to be reachable without an
  /// account. Deriving the redirect's allowlist from this flag is what makes
  /// "the list is public" a single fact rather than a comment in one file and a
  /// rule in another.
  ///
  /// A public destination is a *screen* that renders signed-out; the data
  /// behind it needs its own permission on the server (see
  /// `pb_migrations/1790400000_public_entity_lists.js`), which this cannot
  /// express and does not try to.
  final bool requiresAuth;
}

/// The destinations a top bar offers, in the order it offers them.
///
/// One list for the whole app: a screen renders [navActions] for the
/// destination it is showing, so the bar has the same shape everywhere and a new
/// destination appears on every screen at once.
abstract final class Destinations {
  static final venues = Destination(
    icon: entityIcon(TargetType.venue),
    label: (l10n) => l10n.browseVenues,
    location: venuesBrowsePath(),
    // Public: the visitor who cannot sign in is exactly who needs this list —
    // they are looking for the room they work at so they can ask to join it.
    // `pb_migrations/1790400000_public_entity_lists.js` opens the collection to
    // match.
    requiresAuth: false,
  );

  static final performers = Destination(
    icon: entityIcon(TargetType.performer),
    label: (l10n) => l10n.browsePerformers,
    location: performersBrowsePath(),
    // Public, for the same reason as [venues].
    requiresAuth: false,
  );

  static final calendar = Destination(
    icon: Icons.calendar_month,
    label: (l10n) => l10n.calendar,
    location: '/calendar',
  );

  static final mine = Destination(
    icon: Icons.dashboard,
    label: (l10n) => l10n.myEntities,
    location: '/dashboard',
  );

  static final upcoming = Destination(
    // `Icons.schedule` (a clock), not `Icons.event_available`.
    //
    // `event_available` renders nothing under the tree-shaken web font subset:
    // the button is laid out, sized and tappable, and paints an empty gap. It is
    // in `MaterialIcons-Regular.otf` with a valid outline, so this is a quirk of
    // the subsetting rather than a missing glyph — verified by swapping only the
    // icon and re-measuring the bar (4 painted buttons became 5). If you change
    // this, check the icon actually paints in a web build rather than trusting
    // that it exists in `Icons`.
    icon: Icons.schedule,
    label: (l10n) => l10n.upcomingEvents,
    location: '/upcoming',
  );

  /// Every destination, in top-bar order.
  ///
  /// The dashboard leads because it is the app's home: the top bar of any page
  /// reads left-to-right as "the places I can go", starting from where the app
  /// opens.
  static final List<Destination> all = [
    mine,
    upcoming,
    calendar,
    venues,
    performers,
  ];

  /// The destinations that can be opened without a session, in the same order.
  ///
  /// The router's allowlist is built from this (see [createRouter] in
  /// `lib/router.dart`), so a destination's [Destination.requiresAuth] flag is
  /// the only place that decides whether a route is public.
  static final List<Destination> public = [
    for (final destination in all)
      if (!destination.requiresAuth) destination,
  ];
}

/// The icon for a kind of entity.
///
/// One icon per kind, shared by the destination that browses it, the rows of
/// that list and the account picker — so a venue looks like the same thing
/// wherever it appears, and a second kind of entity costs one line.
IconData entityIcon(TargetType type) => switch (type) {
  TargetType.venue => Icons.location_on,
  TargetType.performer => Icons.person,
};

/// The app-bar actions for a screen currently showing [current].
///
/// Every destination except the current one, so a bar never offers a button that
/// goes where the user already is, plus the account action when the screen is
/// one that carries it. Screens that call this get their whole action list from
/// one place, which is what keeps the order, the icons and the tooltips identical
/// between them.
///
/// # Signed out
///
/// Both the offered destinations and the account action depend on the session,
/// because the alternative is a bar full of buttons that do nothing. A
/// signed-out visitor on a public list was shown the dashboard, the upcoming
/// list and the calendar — every one of which the router's redirect answers by
/// sending them back to the sign-in screen — plus a sign-out button for a
/// session they do not have. So: destinations the session cannot open are left
/// out ([Destination.requiresAuth]), and the account action becomes the sign-in
/// route, which is the thing that actually moves them forward.
///
/// The account action stays opt-in: it is an account action rather than a place,
/// and the calendar deliberately omits it (the dashboard, one tap away, is where
/// a session is managed).
List<Widget> navActions(
  BuildContext context, {
  required Destination current,
  bool accountAction = false,
}) {
  final l10n = AppLocalizations.of(context);
  final signedIn = context.watch<SessionController>().isLoggedIn;
  return [
    for (final destination in Destinations.all)
      if (destination.location != current.location)
        // Signed out, only the public destinations are reachable. Leaving the
        // rest in would be a bar of dead ends: each one is redirected straight
        // back to the sign-in screen by [createRouter].
        if (signedIn || !destination.requiresAuth)
          IconButton(
            // Stable per destination, so "is this button offered here?" is a
            // question with an exact answer. Screens nest other screens that
            // bring their own bars (the calendar's tabs), which makes any
            // ancestor-based lookup of "this screen's bar" ambiguous.
            key: navKey(destination.location),
            icon: Icon(destination.icon),
            tooltip: destination.label(l10n),
            onPressed: () => goToDestination(context, destination),
          ),
    if (accountAction)
      if (signedIn)
        IconButton(
          key: navKey('signout'),
          icon: const Icon(Icons.logout),
          tooltip: l10n.signOut,
          onPressed: () {
            context.read<SessionController>().logout();
            context.go('/');
          },
        )
      else
        IconButton(
          key: navKey('signin'),
          icon: const Icon(Icons.login),
          tooltip: l10n.signIn,
          // `go`, not the `replace` the destinations use: this one is a level,
          // not a sibling — the visitor leaves the public list for the account
          // they need to do anything else, and back should return them to the
          // list they were reading.
          onPressed: () => context.go('/'),
        ),
  ];
}

/// Widget key for the nav button leading to [location] (`signout`/`signin` for
/// the account action), so a test can assert a destination is offered — or
/// deliberately absent — without guessing which bar it landed in.
Key navKey(String location) => ValueKey('nav:$location');

/// Moves to [destination] *laterally*: it replaces the current page instead of
/// stacking on it.
///
/// The destinations are siblings, not levels. Pushing one onto another would
/// grow a history of pages the user never asked to revisit, and would make back
/// mean "the previous top-level page" instead of "leave this area" — so back
/// from any of them lands on the dashboard, which is what the top bar promises.
///
/// [GoRouter.replace] rather than [GoRouter.pushReplacement]: both swap the
/// top-most page, but `replace` keeps the page key, so the outgoing page's state
/// is discarded rather than animated across — the right feel for a lateral move
/// between two unrelated screens.
void goToDestination(BuildContext context, Destination destination) =>
    context.replace(destination.location);

/// Returns to the app's home screen from a top-level page.
///
/// `replace`, not `pop`: the destinations are side by side, so there is usually
/// no history to pop — arriving on one from a deep link or straight after
/// sign-in leaves a stack of exactly one. Navigating home explicitly works in
/// both cases, and keeps the stack flat so this button cannot strand a user on a
/// page with nothing behind it.
///
/// Deliberately not `go('/')`: while signed in the router redirects the sign-in
/// route back to home, so that would be a no-op the user would read as a broken
/// button.
void goHome(BuildContext context) =>
    context.replace(Destinations.mine.location);

/// The leading back affordance for a top-level page that is not home.
///
/// A page that is home has none — see the dashboard, which offers [navActions]
/// and the account action instead.
///
/// Returns null when signed out, because the button would be a duplicate of an
/// action the bar already offers. Its destination is [goHome], which is the
/// dashboard, which the router redirects to the sign-in screen for a visitor —
/// so the visitor would get two identically-labelled buttons on the same bar
/// going to the same place, since the account action is *Entrar* too. The public
/// lists are what made this reachable: before them, no signed-out screen drew
/// this button. The account action carries the way out on its own.
///
/// `Widget?` rather than a shrink-to-nothing placeholder: `AppBar.leading`
/// accepts null and simply renders no slot, while an empty box keeps the title
/// pushed over for a control that is not there.
Widget? backToHomeButton(BuildContext context) {
  if (!context.watch<SessionController>().isLoggedIn) return null;
  return IconButton(
    icon: const Icon(Icons.arrow_back),
    tooltip: AppLocalizations.of(context).backToHome,
    onPressed: () => goHome(context),
  );
}
