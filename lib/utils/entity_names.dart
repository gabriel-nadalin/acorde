/// Name matching for duplicate detection.
///
/// Deliberately fuzzy. The goal is to catch the case that actually causes
/// damage — the same room entered twice under trivially different spellings —
/// while staying advisory, because two genuinely different venues *can* share a
/// name in different cities.
///
/// What this cannot do is refuse a duplicate: the check runs client-side
/// against a name query, so two people submitting at the same moment both pass
/// it. It is a prompt, not a constraint, and the UI says so.
library;

/// Case-, whitespace- and punctuation-insensitive key for comparing names.
///
/// `"The Bluebird Club"`, `"bluebird club"` and `"Bluebird-Club!"` all collapse
/// to `bluebirdclub`, as do the accented and unaccented spellings of a name.
String normalizeEntityName(String name) {
  final lower = name.toLowerCase().trim();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    // Keep letters and digits of any script; drop spacing, punctuation and
    // symbols. A Latin-1 accented letter folds to its base letter so "Café" and
    // "Cafe" match; other scripts pass through unchanged, which still makes
    // their spacing and punctuation irrelevant.
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(char)) {
      buffer.write(_fold(char));
    }
  }
  return buffer.toString();
}

/// Strips a Latin diacritic to its base letter. Returns [char] unchanged when it
/// has none, or when its script has no such decomposition.
String _fold(String char) {
  const map = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
    'ý': 'y',
    'ÿ': 'y',
  };
  return map[char] ?? char;
}

/// True when [candidate] names the same entity as [name].
bool sameEntityName(String candidate, String name) {
  final a = normalizeEntityName(candidate);
  final b = normalizeEntityName(name);
  return a.isNotEmpty && a == b;
}
