import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/auto_find.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/play_helper.dart';
import '../widgets/song_actions.dart';

/// Songs Auto listen identified, newest first, each with the moment it was
/// heard. Rows match the app's other song lists; the 3-dot menu carries an
/// extra "Remove from Song Fetch List" action.
class AutoFindsScreen extends StatefulWidget {
  const AutoFindsScreen({super.key});

  @override
  State<AutoFindsScreen> createState() => _AutoFindsScreenState();
}

class _AutoFindsScreenState extends State<AutoFindsScreen> {
  final _storage = StorageService.instance;
  List<AutoFind> _finds = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _storage.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _storage.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final finds = await _storage.getAutoFinds();
    if (!mounted) return;
    setState(() {
      _finds = finds;
      _loading = false;
    });
  }

  String _stamp(DateTime t) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    final time = TimeOfDay.fromDateTime(t).format(context);
    if (days == 0) return 'Today · $time';
    if (days == 1) return 'Yesterday · $time';
    return '${t.day}/${t.month}/${t.year} · $time';
  }

  @override
  Widget build(BuildContext context) {
    final songs = _finds.map((f) => f.song).toList();
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
          title: const Text('Auto song fetch history',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                  color: AppColors.ink)),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'Delete all',
              onPressed: _finds.isEmpty ? null : _storage.clearAutoFinds,
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
                  : _finds.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.headphones,
                                    size: 44, color: AppColors.mute),
                                SizedBox(height: 12),
                                Text('Nothing found yet',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.ink)),
                                SizedBox(height: 6),
                                Text(
                                    'Songs Auto listen hears will appear here',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppColors.inkSoft)),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(
                              8, 8, 8, hasSong ? 190 : 120),
                          physics: const ClampingScrollPhysics(),
                          itemCount: _finds.length,
                          itemBuilder: (_, i) {
                            final find = _finds[i];
                            return MotionPress(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () => playSongs(context,
                                    song: find.song, queue: songs, index: i),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 6, horizontal: 4),
                                  child: Row(
                                    children: [
                                      Artwork(find.song.thumbnailUrl,
                                          size: 48, radius: 10),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(find.song.title,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                    color: AppColors.ink)),
                                            Text(find.song.artist,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: AppColors.inkSoft,
                                                    fontSize: 12)),
                                            Text(_stamp(find.foundAt),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: AppColors.mute,
                                                    fontSize: 11)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      songTrailing(find.song, [
                                        SongMenuButton(
                                          song: find.song,
                                          queue: songs,
                                          index: i,
                                          onRemoveFromAutoFinds: () =>
                                              _storage.removeAutoFind(i),
                                        ),
                                      ]),
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
