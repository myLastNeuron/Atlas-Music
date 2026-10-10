/// Read-only YouTube engagement for one video.
///
/// Every field is nullable because YouTube does not expose all of them:
/// - likes: public.
/// - dislikes: YouTube stopped publishing dislike counts (Nov 2021), so this
///   is normally null. Some responses may still carry it; we pass it through
///   when present rather than guessing.
///
/// A null field renders as "N/A". Values are never fabricated or inferred.
class VideoStats {
  final int? likes;
  final int? dislikes;

  const VideoStats({this.likes, this.dislikes});

  /// No statistics available. Fresh state and fetch failures use this.
  static const VideoStats unavailable = VideoStats();

  bool get isUnavailable => likes == null && dislikes == null;

  /// Compact count: 999 -> "999", 1500 -> "1.5K", 3_400_000 -> "3.4M".
  /// A null (or negative) value is unavailable and renders as "N/A".
  static String formatCount(int? n) {
    if (n == null || n < 0) return 'N/A';
    if (n < 1000) return '$n';
    const units = ['K', 'M', 'B'];
    var value = n.toDouble();
    var unit = -1;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    // Rounding can push the mantissa to 1000 (e.g. 999_999 -> "1000K"):
    // step up a unit so it reads "1M" instead.
    if (value >= 999.5 && unit < units.length - 1) {
      value /= 1000;
      unit++;
    }
    final text =
        value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    final trimmed =
        text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
    return '$trimmed${units[unit]}';
  }
}
