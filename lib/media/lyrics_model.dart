/// Synced-lyrics value objects. Pure Dart, fully unit-tested.
/// LRC format: `[mm:ss.xx] text`, one or more tags per line.
class LyricLine {
  final Duration start;
  final String text;

  const LyricLine({required this.start, required this.text});
}

class SyncedLyrics {
  final String track;
  final String artist;
  final List<LyricLine> lines;
  final bool isSynced;
  final bool instrumental;
  final String? plain;

  const SyncedLyrics({
    required this.track,
    required this.artist,
    required this.lines,
    required this.isSynced,
    this.instrumental = false,
    this.plain,
  });

  /// Index of the last line whose start is at or before [position].
  /// Returns 0 when empty so callers never clamp.
  int indexFor(Duration position) {
    if (lines.isEmpty) return 0;
    var idx = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].start <= position) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// Punctuation and music symbols only, no words.
final RegExp _gapOnly = RegExp(r'^[\s.,;:!?…·•\-–—_*~♪♫♬]+$');

/// True when a timed line carries no words: blank, or only punctuation and
/// music symbols ("...", "♪") that some LRC files ship as a gap marker.
bool isGapText(String text) {
  final t = text.trim();
  return t.isEmpty || _gapOnly.hasMatch(t);
}

/// Lines the sheet must not draw as words: "..." / "♪" filler that some
/// LRC files ship as a gap marker, and timed blanks that sit on the next
/// line's beat (a stanza separator, not a gap). Symbols-only lines are
/// noise, so they are dropped; a blank is kept when it marks real silence.
List<LyricLine> _cleanGaps(List<LyricLine> lines) {
  final out = <LyricLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (isGapText(line.text)) {
      if (line.text.trim().isNotEmpty) continue;
      final next = i + 1 < lines.length ? lines[i + 1].start : null;
      if (next == null || next - line.start < const Duration(seconds: 2)) {
        continue;
      }
    }
    out.add(line);
  }
  return out;
}

/// Rows to draw for a synced track: every timed line, plus a blank marker
/// row (the sheet draws it as ♫) wherever the track plays music only.
///
/// LRC files mark silence with a timed line that has no text — often they
/// do not, and then the last sung line stayed lit through the whole
/// interlude. So a stretch of [_minSilence] after a line with nothing but
/// music is treated as instrumental too: the line is assumed to be sung
/// for about [_perChar] per character plus [_lead], leaving the rest as ♫.
/// Music before the first word and after the last one gets its own marker.
/// Filler lines ("...", "♪") are dropped, not printed.
///
/// [songLength] is the track duration; pass [Duration.zero] when unknown
/// and the trailer is left alone.
// shortcut: sung length is estimated from character count, so a ♫ can start
// a second early or late; use word-level LRC ([mm:ss]word<mm:ss>) for exact.
List<LyricLine> lyricRows(List<LyricLine> lines, Duration songLength) {
  if (lines.isEmpty) return lines;
  const minSilence = Duration(seconds: 12);
  const minIntro = Duration(seconds: 8);
  const lead = Duration(seconds: 2);
  const perChar = 120; // ms
  const trailer = Duration(seconds: 4);

  Duration sungFor(LyricLine line) {
    final ms = (perChar * line.text.trim().length + lead.inMilliseconds)
        .clamp(3000, 12000);
    return Duration(milliseconds: ms);
  }

  // Marker inside a stretch that runs until [next]: never eat its last 4s.
  Duration? markerIn(LyricLine line, Duration next) {
    final stretch = next - line.start;
    if (stretch < minSilence) return null;
    final sung = sungFor(line);
    final tail = stretch - trailer;
    return line.start + (sung < tail ? sung : tail);
  }

  bool blank(LyricLine l) => isGapText(l.text);

  final src = _cleanGaps(lines);
  final out = <LyricLine>[];
  if (src.isNotEmpty && src.first.start >= minIntro) {
    out.add(const LyricLine(start: Duration.zero, text: ''));
  }
  for (var i = 0; i < src.length; i++) {
    final line = src[i];
    out.add(line);
    if (isGapText(line.text)) continue;
    final hasNext = i + 1 < src.length;
    // A following gap line already marks this silence.
    if (hasNext && blank(src[i + 1])) continue;
    final next = hasNext ? src[i + 1].start : songLength;
    if (next <= line.start) continue;
    final at = markerIn(line, next);
    if (at != null) out.add(LyricLine(start: at, text: ''));
  }
  return out;
}

/// Parses an LRC string into sorted lines. Ignores metadata tags
/// ([ti:]/[ar:]/[al:]/[length:]/[by:]), expands multiple timestamps
/// on one line into separate entries, and keeps a timed line with no
/// text as an empty marker: that is an instrumental gap, and the sheet
/// draws its ♫ there.
List<LyricLine> parseLrc(String lrc) {
  final out = <LyricLine>[];
  final tag = RegExp(r'\[(\d+):(\d+(?:[.:]\d+)?)\]');
  for (final raw in lrc.split('\n')) {
    final matches = tag.allMatches(raw).toList();
    if (matches.isEmpty) continue;
    var text = raw.replaceAll(tag, '').trim();
    // Strip inline metadata remnants.
    if (text.startsWith('ti:') ||
        text.startsWith('ar:') ||
        text.startsWith('al:') ||
        text.startsWith('length:') ||
        text.startsWith('by:')) {
      continue;
    }
    for (final m in matches) {
      final min = int.tryParse(m.group(1) ?? '') ?? 0;
      final secRaw = (m.group(2) ?? '0').replaceAll('.', ':');
      double sec = 0;
      if (secRaw.contains(':')) {
        final parts = secRaw.split(':');
        sec = (double.tryParse(parts[0]) ?? 0) +
            (double.tryParse('0.${parts.length > 1 ? parts[1] : 0}') ?? 0);
      } else {
        sec = double.tryParse(secRaw) ?? 0;
      }
      final ms = ((min * 60 + sec) * 1000).round();
      if (ms < 0) continue;
      out.add(LyricLine(
        start: Duration(milliseconds: ms),
        text: text,
      ));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
