import 'package:flutter_test/flutter_test.dart';

import 'package:acorde/models/event.dart';
import 'package:acorde/utils/event_scope.dart';

/// The one definition of "is this event mine".
///
/// This predicate lived twice — `_eventCats` in `events_list.dart` and
/// `_colorFor` in `upcoming.dart` — and the two copies were used differently:
/// the calendar filtered by its copy, the upcoming list only coloured by its.
/// The result was a screen listing bookings that vanished the moment you tapped
/// through to the calendar, which is the bug these tests exist to keep closed.
///
/// Pure unit tests, deliberately: the predicate is the whole contract, and the
/// screens' agreement is asserted separately, on the observable behaviour of two
/// screens reading the same fixtures.
void main() {
  Event event({String? venueId, List<String> performers = const []}) => Event(
    id: 'e1',
    title: 'Gig',
    start: DateTime(2026, 9, 25, 20),
    end: DateTime(2026, 9, 25, 22),
    venueId: venueId,
    performers: performers,
  );

  const myVenues = {'v1'};
  const myActs = {'p1'};

  group('event categories', () {
    test('an act this account belongs to', () {
      expect(
        eventCategories(
          event(performers: const ['p1']),
          performerIds: myActs,
          venueIds: myVenues,
        ),
        {'performer'},
      );
    });

    test('a venue this account manages', () {
      expect(
        eventCategories(
          event(venueId: 'v1'),
          performerIds: myActs,
          venueIds: myVenues,
        ),
        {'venue'},
      );
    });

    /// A gig at a venue you manage, played by an act you are in, is both — and
    /// the palette has a colour for exactly that, so the two categories have to
    /// survive together rather than the second overwriting the first.
    test('both at once', () {
      expect(
        eventCategories(
          event(venueId: 'v1', performers: const ['p1']),
          performerIds: myActs,
          venueIds: myVenues,
        ),
        {'performer', 'venue'},
      );
    });

    test('neither, for somebody else\'s booking', () {
      expect(
        eventCategories(
          event(venueId: 'v2', performers: const ['p2']),
          performerIds: myActs,
          venueIds: myVenues,
        ),
        isEmpty,
      );
    });

    /// A booking with no venue at all is normal — an act's gig does not have to
    /// name a room — and must not be mistaken for a match. `venueId` is a String
    /// and the stored value for "none" is `""`, which is not an id.
    test('no venue, no act, and an empty venue id are all non-matches', () {
      for (final e in [
        event(),
        event(performers: const ['p2']),
        event(venueId: ''),
      ]) {
        expect(
          eventCategories(e, performerIds: myActs, venueIds: myVenues),
          isEmpty,
        );
      }
    });

    /// A new account has no assignments. Everything is then somebody else's,
    /// which is what makes the signed-out and just-signed-up empty states
    /// correct rather than a bug.
    test('nothing is mine when the account has no assignments', () {
      expect(
        eventCategories(
          event(venueId: 'v1', performers: const ['p1']),
          performerIds: const {},
          venueIds: const {},
        ),
        isEmpty,
      );
    });
  });

  group('scope', () {
    test('is the presence of any category', () {
      final mine = event(venueId: 'v1', performers: const ['p1']);
      final theirs = event(venueId: 'v2', performers: const ['p2']);
      expect(
        eventInScope(mine, performerIds: myActs, venueIds: myVenues),
        isTrue,
      );
      expect(
        eventInScope(theirs, performerIds: myActs, venueIds: myVenues),
        isFalse,
      );
    });

    test('agrees with the categories it is derived from', () {
      for (final e in [
        event(),
        event(venueId: 'v1'),
        event(performers: const ['p1']),
        event(venueId: 'v1', performers: const ['p1']),
        event(venueId: 'v2', performers: const ['p2']),
      ]) {
        final cats = eventCategories(
          e,
          performerIds: myActs,
          venueIds: myVenues,
        );
        expect(
          eventInScope(e, performerIds: myActs, venueIds: myVenues),
          cats.isNotEmpty,
          reason:
              'scope and categories disagree for ${e.venueId}/${e.performers}',
        );
      }
    });
  });
}
