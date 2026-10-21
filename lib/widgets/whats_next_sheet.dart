import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import 'artwork.dart';
import 'liquid_background.dart';

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
    final same = next.length == _songs.length &&
        List.generate(next.length, (i) => next[i].id == _songs[i].id)
            .every((matches) => matches);
    if (same) return;
    setState(() => _songs = next);
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
        border: const Border(top: BorderSide(color: AppColors.line)),
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
                        const Text("What's Next?",
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
                          style: const TextStyle(
                              color: AppColors.mute, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, color: AppColors.mute),
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
                    side: const BorderSide(color: AppColors.line),
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
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Could not build a new queue. Check your connection and try again.',
                  style: TextStyle(color: AppColors.mute, fontSize: 12),
                ),
              ),
            const Divider(color: AppColors.line, height: 1),
            Expanded(
              child: _songs.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _songs.length,
                      itemBuilder: (_, i) {
                        final song = _songs[i];
                        return _UpcomingRow(
                          song: song,
                          reason: widget.audio.reasonFor(song),
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
  final VoidCallback onTap;

  const _UpcomingRow({
    required this.song,
    required this.reason,
    required this.onTap,
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
                      style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    reason == null ? song.artist : '${song.artist} · $reason',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.mute, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.play_arrow_rounded,
                size: 22, color: AppColors.inkSoft),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music, size: 44, color: AppColors.mute),
            SizedBox(height: 12),
            Text('Nothing queued yet',
                style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
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
