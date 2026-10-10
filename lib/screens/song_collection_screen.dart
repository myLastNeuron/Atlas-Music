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

/// Shared list scaffold for a stored song collection (liked, downloaded).
/// Reloads whenever storage notifies, so changes made anywhere reflect here.
class SongCollectionScreen extends StatefulWidget {
  final String title;
  final String listKey;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyHint;
  final Future<List<Song>> Function() load;
  final Widget Function(Song, int, List<Song>) trailing;

  /// Remote lists (an artist's release) load once; local collections
  /// (liked/downloads) reload on any storage change. Remote reloads would
  /// otherwise re-hit the network on every like or download anywhere.
  final bool reloadOnStorage;

  const SongCollectionScreen({
    super.key,
    required this.title,
    required this.listKey,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyHint,
    required this.load,
    required this.trailing,
    this.reloadOnStorage = true,
  });

  @override
  State<SongCollectionScreen> createState() => _SongCollectionScreenState();
}

class _SongCollectionScreenState extends State<SongCollectionScreen> {
  final _storage = StorageService.instance;
  List<Song> _songs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    if (widget.reloadOnStorage) _storage.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    if (widget.reloadOnStorage) _storage.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    List<Song> songs;
    try {
      songs = await widget.load();
    } catch (_) {
      // A throwing loader (e.g. an album fetch while offline) must not leave
      // the screen spinning forever.
      songs = const [];
    }
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
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
          title: Text(widget.title,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: AppColors.ink)),
          centerTitle: true,
        ),
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              AnimatedSwitcher(
                duration: AppMotion.dur(context, AppMotion.modal),
                switchInCurve: AppMotion.curve,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: fadeRiseTransition,
                child: _loading
                    ? const Center(
                        key: ValueKey('songs_loading'),
                        child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : _songs.isEmpty
                        ? Center(
                            key: const ValueKey('songs_empty'),
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(widget.emptyIcon,
                                      size: 44, color: AppColors.mute),
                                  const SizedBox(height: 12),
                                  Text(widget.emptyTitle,
                                      style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.ink)),
                                  const SizedBox(height: 6),
                                  Text(widget.emptyHint,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.inkSoft)),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            key: ValueKey(widget.listKey),
                            padding: EdgeInsets.only(
                                left: 8,
                                right: 8,
                                top: 8,
                                bottom: hasSong ? 190 : 120),
                            physics: const BouncingScrollPhysics(),
                            itemCount: _songs.length,
                            itemBuilder: (_, i) {
                              final s = _songs[i];
                              return MotionPress(
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                  leading: Artwork(s.thumbnailUrl,
                                      size: 48, radius: 10),
                                  title: Text(s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.ink)),
                                  subtitle: Text(s.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: AppColors.inkSoft,
                                          fontSize: 12)),
                                  trailing:
                                      widget.trailing(s, i, _songs),
                                  onTap: () => playSongs(context,
                                      song: s, queue: _songs, index: i),
                                ),
                              );
                            },
                          ),
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
