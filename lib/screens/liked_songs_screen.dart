import 'package:flutter/material.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/song_actions.dart';
import 'song_collection_screen.dart';

/// Liked songs collection. Unfiltered explicit user data, so the count here
/// always matches Profile and Library. Reloads on any like/unlike.
class LikedSongsScreen extends StatelessWidget {
  const LikedSongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = StorageService.instance;
    return SongCollectionScreen(
      title: 'Liked Songs',
      listKey: 'liked_list',
      emptyIcon: Icons.favorite_outline,
      emptyTitle: 'No liked songs yet',
      emptyHint: 'Tap the heart on any song and it will appear here',
      load: storage.getLikedSongs,
      trailing: (s, i, queue) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.favorite, size: 20, color: AppColors.ink),
            tooltip: 'Unlike',
            onPressed: () => storage.toggleLikedSong(s),
          ),
          SongMenuButton(song: s, queue: queue, index: i),
        ],
      ),
    );
  }
}
