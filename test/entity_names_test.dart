import 'package:flutter_test/flutter_test.dart';

import 'package:event_calendar/utils/entity_names.dart';

/// The duplicate prompt is only as good as this comparison: too strict and it
/// never fires (the duplicate gets created anyway, which is the bug it exists to
/// prevent), too loose and it fires on unrelated names until users learn to
/// dismiss it without reading.
void main() {
  group('normalizeEntityName', () {
    test('ignores case, surrounding space and internal spacing', () {
      expect(normalizeEntityName('  Harbor Hall '), 'harborhall');
      expect(normalizeEntityName('HARBOR   HALL'), 'harborhall');
      expect(normalizeEntityName('harbor\thall'), 'harborhall');
    });

    test('ignores punctuation and symbols', () {
      expect(normalizeEntityName('Harbor Hall!'), 'harborhall');
      expect(normalizeEntityName('The Bluebird-Club'), 'thebluebirdclub');
      expect(normalizeEntityName("Bluebird's"), 'bluebirds');
      expect(normalizeEntityName('Loft & Stage'), 'loftstage');
    });

    test('folds Latin accents so accented and plain spellings match', () {
      expect(
        normalizeEntityName('Café Central'),
        normalizeEntityName('Cafe Central'),
      );
      expect(normalizeEntityName('Teatro São'), 'teatrosao');
    });

    test(
      'keeps digits, which can be the only thing telling two rooms apart',
      () {
        expect(normalizeEntityName('Studio 54'), 'studio54');
        expect(
          normalizeEntityName('Studio 54'),
          isNot(normalizeEntityName('Studio 5')),
        );
      },
    );

    test('keeps non-Latin scripts rather than erasing them', () {
      // A name in a non-Latin script must not normalize to nothing, or every
      // such venue would compare equal to every other one.
      expect(normalizeEntityName('東京ホール').isNotEmpty, isTrue);
      expect(normalizeEntityName('東京ホール'), isNot(normalizeEntityName('大阪ホール')));
    });

    test('an empty or punctuation-only name normalizes to empty', () {
      expect(normalizeEntityName(''), '');
      expect(normalizeEntityName('   '), '');
      expect(normalizeEntityName('!!!'), '');
    });
  });

  group('sameEntityName', () {
    test('matches the spellings a person would consider the same place', () {
      expect(sameEntityName('Harbor Hall', 'harbor hall'), isTrue);
      expect(
        sameEntityName('The Bluebird Club', 'The  Bluebird-Club!'),
        isTrue,
      );
      expect(sameEntityName('Café Central', 'Cafe Central'), isTrue);
    });

    test('does not match genuinely different names', () {
      expect(sameEntityName('Harbor Hall', 'Harbor Rooms'), isFalse);
      expect(sameEntityName('Bluebird Club', 'Eastside Loft'), isFalse);
      expect(sameEntityName('Studio 54', 'Studio 5'), isFalse);
    });

    test('never matches when either name carries no letters or digits', () {
      // Otherwise a punctuation-only name would look like every other one and
      // the prompt would fire on unrelated records.
      expect(sameEntityName('', 'Harbor Hall'), isFalse);
      expect(sameEntityName('!!!', 'Harbor Hall'), isFalse);
      expect(sameEntityName('', ''), isFalse);
    });
  });
}
