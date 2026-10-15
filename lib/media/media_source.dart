/// Which backend produced a [MediaSource]. UI/player never branches on this;
/// it exists for diagnostics, ranking, and health tracking only.
enum MediaProvider { youTube, piped }

/// A normalized, playable-or-downloadable audio stream.
/// Providers return this; [AudioPlayerService] only understands this.
class MediaSource {
  final MediaProvider provider;

  /// Direct (or proxied) playable URL.
  final String url;

  /// e.g. 'audio/mp4', 'audio/webm', 'audio/mpeg'.
  final String? mimeType;

  /// Codec string, e.g. 'mp4a.40.2', 'opus'.
  final String? codec;

  /// Container, e.g. 'mp4', 'webm', 'mp3'.
  final String? container;

  /// Bits per second, if known.
  final int? bitrate;

  /// Full content length in bytes, if known.
  final int? contentLength;

  /// When the URL is known to stop working (googlevideo `expire` param).
  final DateTime? expiresAt;

  /// Opaque provider-side identifier for re-resolution (e.g. YouTube
  /// video ID). Lets a provider fetch alternate URLs without new API.
  final String? mediaId;

  final DateTime resolvedAt;

  const MediaSource({
    required this.provider,
    required this.url,
    this.mimeType,
    this.codec,
    this.container,
    this.bitrate,
    this.contentLength,
    this.expiresAt,
    this.mediaId,
    required this.resolvedAt,
  });

  bool get isExpired =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);

  @override
  String toString() =>
      'MediaSource($provider, $container/$codec, ${bitrate ?? '?'}bps, '
      'len=${contentLength ?? '?'})';
}
