import 'package:flutter/material.dart';
import '../media/cache_service.dart';
import '../services/storage_service.dart';
import '../widgets/song_actions.dart';
import 'song_collection_screen.dart';

/// Every downloaded song, newest first as stored. Removing a row here deletes
/// the local file and drops the song from every offline set.
class OfflineMusicScreen extends StatelessWidget {
  const OfflineMusicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = StorageService.instance;
    final cache = CacheService();
    return SongCollectionScreen(
      title: 'Offline Music',
      listKey: 'offline_list',
      emptyIcon: Icons.download_done,
      emptyTitle: 'No downloaded songs',
      emptyHint: 'Downloaded tracks are playable without internet',
      load: storage.getDownloadedSongs,
      trailing: (s, i, queue) => SongMenuButton(
        song: s,
        queue: queue,
        index: i,
        onRemoveFromDownloads: () async {
          await storage.removeDownloadedSong(s.id);
          try {
            await cache.invalidate(s);
          } catch (_) {
            // Non-fatal: the file is orphaned but no longer listed.
          }
        },
      ),
    );
  }
}
