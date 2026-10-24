import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import 'play_next_badge.dart';
import 'artwork.dart';
import 'liquid_background.dart';
import 'skeleton_card.dart';

/// Bottom sheet behind the player's "What's Next?" button: the tracks that
/// will actually play after the current one, why each was picked, and a
/// "Rethink" action that rebuilds the upcoming queue from fresh signals.
Future<void> showWhatsNextSheet(
  BuildContext context,
  AudioPlayerService audio,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => WhatsNextSheet(audio: audio),
  );
}

class WhatsNextSheet extends StatefulWidget {
  final AudioPlayerService audio;

  const WhatsNextSheet({super.key, required this.audio});

  @override
  State<WhatsNextSheet> createState() => _WhatsNextSheetState();
}

class _WhatsNextSheetState extends State<WhatsNextSheet> {
  late List<Song> _songs = widget.audio.upcoming;
  late bool _loading = widget.audio.upNextLoading;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.audio.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    widget.audio.removeListener(_onQueueChanged);
    super.dispose();
  }

  /// The service grows the queue on its own as soon as playback starts with
  /// nothing queued. Follow it live so the list fills itself instead of
  /// sitting empty until someone hits "Rethink".
  void _onQueueChanged() {
    if (!mounted) return;
    final next = widget.audio.upcoming;
    final loading = widget.audio.upNextLoading;
    final same = loading == _loading &&
        next.length == _songs.length &&
        List.generate(next.length, (i) => next[i].id == _songs[i].id)
            .every((matches) => matches);
    if (same) return;
    setState(() {
      _songs = next;
      _loading = loading;
    });
  }

  Future<void> _rethink() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    final picks = await widget.audio.rethinkUpcoming();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _songs = widget.audio.upcoming;
      _failed = picks.isEmpty;
    });
  }

  Future<void> _play(Song song) async {
    final at = widget.audio.queue.indexWhere((s) => s.id == song.id);
    if (at >= 0) {
      await widget.audio.playQueued(at);
    } else {
      await widget.audio.playSong(song);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.audio.currentSong;
    final height = MediaQuery.of(context).size.height * 0.72;
    return SizedBox(
      height: height,
      child: GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: AppColors.line)),
        shadow: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("What's Next?",
                            style: TextStyle(
                                color: AppColors.ink,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          current == null
                              ? 'Nothing is playing'
                              : widget.audio.shuffleEnabled
                                  ? 'After ${current.title} · shuffle on'
                                  : 'After ${current.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.mute, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: Icon(Icons.close, color: AppColors.mute),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('whats_next_rethink'),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.autorenew, size: 18),
                  label: Text(_busy ? 'Rethinking…' : 'Rethink'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.ink,
                    side: BorderSide(color: AppColors.line),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: _busy || current == null ? null : _rethink,
                ),
              ),
            ),
            if (_failed)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Could not build a new queue. Check your connection and try again.',
                  style: TextStyle(color: AppColors.mute, fontSize: 12),
                ),
              ),
            Divider(color: AppColors.line, height: 1),
            Expanded(
              child: _songs.isEmpty
                  ? (_loading ? const _FillingState() : const _EmptyState())
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _songs.length,
                      itemBuilder: (_, i) {
                        final song = _songs[i];
                        return _UpcomingRow(
                          song: song,
                          reason: widget.audio.reasonFor(song),
                          pinned: widget.audio.pinnedNext?.id == song.id,
                          onTap: () => _play(song),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  final Song song;
  final String? reason;

  /// True for the row the user pinned with "Play next": it plays next and the
  /// rest of the list keeps its order behind it.
  final bool pinned;
  final VoidCallback onTap;

  const _UpcomingRow({
    required this.song,
    required this.reason,
    required this.onTap,
    this.pinned = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            Artwork(song.thumbnailUrl, size: 44, radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    reason == null ? song.artist : '${song.artist} · $reason',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.mute, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (pinned)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: PlayNextBadge(),
              ),
            Icon(Icons.play_arrow_rounded,
                size: 22, color: AppColors.inkSoft),
          ],
        ),
      ),
    );
  }
}

/// Placeholder rows while the queue is still being built, so opening the
/// sheet right after a song starts shows progress instead of "nothing queued".
class _FillingState extends StatelessWidget {
  const _FillingState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(5, (_) => const SkeletonListItem()),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music, size: 44, color: AppColors.mute),
            const SizedBox(height: 12),
            Text('Nothing queued yet',
                style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Rethink builds a radio from the song that is playing.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mute, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
