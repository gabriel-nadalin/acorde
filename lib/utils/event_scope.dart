import '../models/event.dart';

/// Which of this account's assignments an event touches.
///
/// The one definition of "is this event mine", shared by the screen that lists
/// events and the screen that draws them on a month. It lived twice before —
/// as `_eventCats` in `events_list.dart` and as `_colorFor` in `upcoming.dart` —
/// and the copies did not just differ in style: the calendar used its copy to
/// *filter* and the upcoming list used its copy only to *colour*, so the two
/// screens disagreed about which events they were showing. Three of the seeded
/// bookings appeared in Próximos and then vanished when a day was tapped through
/// to the calendar.
///
/// The categories are a set, not a flag, because an event can be both: a gig at
/// a venue this account manages, played by an act it belongs to, is both, and
/// the palette shows that as its own colour rather than picking one.
///
/// Deliberately not a method on [Event]: this is a question about the *viewer*,
/// not about the booking, and a booking has no idea who is looking at it.
Set<String> eventCategories(
  Event event, {
  required Set<String> performerIds,
  required Set<String> venueIds,
}) {
  final categories = <String>{};
  if (performerIds.isNotEmpty && event.performers.any(performerIds.contains)) {
    categories.add('performer');
  }
  final venueId = event.venueId;
  if (venueId != null && venueId.isNotEmpty && venueIds.contains(venueId)) {
    categories.add('venue');
  }
  return categories;
}

/// Whether [event] touches any assignment of this account.
///
/// The scoping predicate: an event with no category belongs to somebody else's
/// schedule and must not appear in a view framed as this account's own. The
/// calendar applies it through `_eventCats` (a tab shows exactly the categories
/// it was given); the upcoming list applies it directly, so the two agree by
/// construction rather than by both remembering to.
bool eventInScope(
  Event event, {
  required Set<String> performerIds,
  required Set<String> venueIds,
}) => eventCategories(
  event,
  performerIds: performerIds,
  venueIds: venueIds,
).isNotEmpty;
