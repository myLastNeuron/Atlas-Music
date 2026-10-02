import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/play_helper.dart';

/// Full listening history, newest first. Raw user data — no discovery
/// filters. Each row can be deleted; the top bin wipes everything locally.
/// Listens to storage so deletes and new plays reflect instantly.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _storage = StorageService.instance;
  List<Song> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _storage.addListener(_onStorageChanged);
    _load();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() => _load();

  Future<void> _load() async {
    final r = await _storage.getRecentlyPlayed();
    if (!mounted) return;
    setState(() {
      _history = r;
      _loading = false;
    });
  }

  Future<void> _remove(Song song) async {
    await _storage.removeFromRecentlyPlayed(song.id);
    // Listener reloads; no manual refresh needed.
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Delete all history?'),
        content: const Text(
          'The action you are gonna do can be severe and it would delete '
          'all song history locally and you won\'t be able to retrieve '
          'them again.',
          style: TextStyle(color: AppColors.inkSoft),
        ),
        actions: [
          // Preselected: Enter/OK cancels unless the user deliberately
          // picks Continue. Keeps the destructive path opt-in.
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _storage.clearRecentlyPlayed();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final hasSong =
        context.select<AudioPlayerService, bool>((s) => s.currentSong != null);
    return LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.ink),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('History',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: AppColors.ink)),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'Delete all history',
              onPressed: _history.isEmpty ? null : _clearAll,
              icon: const Icon(Icons.delete_outline, color: AppColors.ink),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              _loading
                  ? const Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : _history.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.history,
                                    size: 44, color: AppColors.mute),
                                SizedBox(height: 12),
                                Text('No listening history',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.ink)),
                                SizedBox(height: 6),
                                Text(
                                    'Songs you play will appear here',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.inkSoft)),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.only(
                              left: 8,
                              right: 8,
                              top: 8,
                              bottom: hasSong ? 190 : 120),
                          physics: const BouncingScrollPhysics(),
                          itemCount: _history.length,
                          itemBuilder: (_, i) {
                            final s = _history[i];
                            return MotionPress(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => playSongs(context,
                                    song: s, queue: _history, index: i),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 6, horizontal: 4),
                                  child: Row(
                                    children: [
                                      IconButton(
                                        tooltip: 'Remove from history',
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.delete_outline,
                                            size: 20, color: AppColors.mute),
                                        onPressed: () => _remove(s),
                                      ),
                                      Artwork(s.thumbnailUrl,
                                          size: 48, radius: 10),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(s.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                    color: AppColors.ink)),
                                            Text(s.artist,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: AppColors.inkSoft,
                                                    fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(_fmt(s.duration),
                                          style: const TextStyle(
                                              color: AppColors.mute,
                                              fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
              if (hasSong)
                const Positioned(
                    left: 16, right: 16, bottom: 8, child: MiniPlayer()),
            ],
          ),
        ),
      ),
    );
  }
}
