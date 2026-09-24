import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../data/repositories.dart';
import '../l10n/app_localizations.dart';
import '../models/event.dart';

/// How an event's venue and performers are named on screen.
///
/// One implementation because two screens need it — the calendar's day sheet and
/// the upcoming list — and the rule it encodes is easy to get subtly wrong: an
/// id on the wire can outlive the record it points at (the venue was deleted, or
/// the cache has not loaded yet), so a raw id is never an acceptable fallback.
/// Anything that shows an event downstream gets the same wording from here.
class EventLabels {
  EventLabels({
    required this.l10n,
    required this.venues,
    required this.performers,
    this.venueOverrideId,
    this.venueOverrideName,
  });

  /// Builds one from the repositories this [context] provides.
  ///
  /// Deliberately reads rather than watches: the screens that use this already
  /// watch the two repositories (a late-arriving cache has to repaint the
  /// labels), and a second subscription here would only duplicate that.
  factory EventLabels.of(
    BuildContext context, {
    String? venueOverrideId,
    String? venueOverrideName,
  }) => EventLabels(
    l10n: AppLocalizations.of(context),
    venues: context.read<VenueRepository>(),
    performers: context.read<PerformerRepository>(),
    venueOverrideId: venueOverrideId,
    venueOverrideName: venueOverrideName,
  );

  final AppLocalizations l10n;
  final VenueRepository venues;
  final PerformerRepository performers;

  /// A venue name the caller already holds, used instead of a cache lookup when
  /// the event is at [venueOverrideId].
  ///
  /// The calendar is given a venue's name by the route that opened it, and the
  /// title of the event should agree with the title of the page.
  final String? venueOverrideId;
  final String? venueOverrideName;

  /// The venue's name, or the "no longer exists" label when it cannot resolve.
  ///
  /// Empty when the event books no venue at all, which is not a missing record:
  /// a performer's booking does not have to name a room.
  String venueFor(Event e) {
    final id = e.venueId;
    if (id == null || id.isEmpty) return '';
    if (id == venueOverrideId && (venueOverrideName?.isNotEmpty ?? false)) {
      return venueOverrideName!;
    }
    final resolved = venues.byId(id)?.displayName ?? e.venueName;
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return l10n.eventVenueMissing;
  }

  /// Performer names, comma-separated; ids that no longer resolve show the
  /// "no longer exists" label instead of the id.
  String performersFor(Event e) {
    if (e.performers.isEmpty) return e.performerNames.join(', ');
    return [
      for (var i = 0; i < e.performers.length; i++)
        _performerNameAt(e, i) ?? l10n.eventPerformerMissing,
    ].join(', ');
  }

  /// "Venue • Performer, Performer", dropping whichever half is absent.
  String line(Event e) {
    final venue = venueFor(e);
    final acts = performersFor(e);
    return [if (venue.isNotEmpty) venue, if (acts.isNotEmpty) acts].join(' • ');
  }

  /// Name of `e.performers[index]`, preferring the performer cache and falling
  /// back to the `expand`ed name the wire may carry alongside the ids. Null when
  /// neither resolves, i.e. the id is dangling.
  String? _performerNameAt(Event e, int index) {
    final cached = performers.byId(e.performers[index])?.displayName;
    if (cached != null && cached.isNotEmpty) return cached;
    final expanded = index < e.performerNames.length
        ? e.performerNames[index]
        : null;
    if (expanded != null && expanded.isNotEmpty) return expanded;
    return null;
  }
}
