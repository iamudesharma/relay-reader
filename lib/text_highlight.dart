/// A range in [text] that corresponds to the sentence being narrated.
typedef PassageRange = ({int start, int end});

/// Finds [passage] inside [text], tolerating changed whitespace and line
/// wrapping. Returns null when the passage is not part of this text.
PassageRange? findPassageRange(String text, String passage) {
  final needle = passage.trim();
  if (needle.isEmpty || text.isEmpty) return null;

  final exact = text.indexOf(needle);
  if (exact >= 0) {
    return (start: exact, end: exact + needle.length);
  }

  final words = needle
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(RegExp.escape)
      .toList(growable: false);
  if (words.isEmpty) return null;

  final pattern = RegExp(words.join(r'\s+'), multiLine: true);
  final match = pattern.firstMatch(text);
  if (match == null) return null;
  return (start: match.start, end: match.end);
}
