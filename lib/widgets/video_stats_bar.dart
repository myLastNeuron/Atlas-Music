import 'package:flutter/material.dart';
import '../models/video_stats.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';

final _youtube = YouTubeService();
Future<VideoStats?> _fetchStats(String id) => _youtube.getVideoStats(id);

/// Compact, read-only YouTube engagement for the current video: likes and
/// dislikes. Purely informational — the row contains no tap handlers and
/// ignores pointers, so nothing here can like or dislike. Values YouTube does
/// not expose render as "N/A".
///
/// Fetches once per video and again when the video changes.
class VideoStatsBar extends StatefulWidget {
  final String? videoId;

  /// Injectable for tests; defaults to the real YouTube lookup.
  final Future<VideoStats?> Function(String videoId)? fetch;

  const VideoStatsBar({super.key, required this.videoId, this.fetch});

  @override
  State<VideoStatsBar> createState() => _VideoStatsBarState();
}

class _VideoStatsBarState extends State<VideoStatsBar> {
  late final Future<VideoStats?> Function(String) _fetch =
      widget.fetch ?? _fetchStats;
  VideoStats _stats = VideoStats.unavailable;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant VideoStatsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoId != widget.videoId) {
      // New video: drop the old numbers so the previous song's likes are
      // never shown under the new title.
      _stats = VideoStats.unavailable;
      _refresh();
    }
  }

  void _refresh() {
    final id = widget.videoId;
    if (id == null || id.isEmpty) return;
    final token = ++_token;
    _fetch(id).then((stats) {
      // Outdated refresh: the widget moved to another video (or was
      // disposed) while this request was in flight — drop it.
      if (!mounted || token != _token || widget.videoId != id) return;
      setState(() => _stats = stats ?? VideoStats.unavailable);
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _stat(Icons.thumb_up_alt_outlined, 'Likes', _stats.likes),
          const SizedBox(width: 20),
          _stat(Icons.thumb_down_alt_outlined, 'Dislikes', _stats.dislikes),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String label, int? value) {
    return Semantics(
      label: '$label: ${VideoStats.formatCount(value)}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.mute),
          const SizedBox(width: 5),
          Text(
            VideoStats.formatCount(value),
            style: const TextStyle(fontSize: 12, color: AppColors.inkSoft),
          ),
        ],
      ),
    );
  }
}
