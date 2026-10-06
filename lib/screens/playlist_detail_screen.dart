import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../media/cache_service.dart';
import '../widgets/mini_player.dart';
import '../widgets/play_helper.dart';
import '../widgets/liquid_background.dart';
import '../widgets/artwork.dart';
import '../widgets/song_actions.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Playlist _playlist;
  final _storage = StorageService();

  /// Playlists show every song they contain. The global language/duration
  /// rules govern discovery (search, trending, recommendations), not an
  /// explicit import.
  List<Song> get _songs => _playlist.songs;

  @override
  void initState() {
    super.initState();
    _playlist = widget.playlist;
    _storage.addListener(_onStorageChanged);
    _refreshFromStorage();
    _loadLiked();
    _loadDownloaded();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    super.dispose();
  }

  void _onStorageChanged() {
    _loadLiked();
    _loadDownloaded();
  }

  Set<String> _likedIds = {};

  /// Global downloaded ids: a song is offline when its file is in the
  /// downloads list, independent of this playlist's own offline flags.
  Set<String> _downloadedIds = {};

  // Multi-select: indices point into the frozen _songs snapshot so a
  // background reload cannot shift the row a tap targets.
  final MultiSelectController _sel = MultiSelectController();
  bool get _selecting => _sel.selecting;
  Set<int> get _selected => _sel.selected;
  bool _downloadingSingle = false;

  Future<void> _applyIds(Future<List<Song>> Function() load,
      Set<String> current, void Function(Set<String>) apply) async {
    final ids = (await load()).map((s) => s.id).toSet();
    if (!mounted) return;
    if (ids.length == current.length && ids.every(current.contains)) return;
    setState(() => apply(ids));
  }

  Future<void> _loadDownloaded() => _applyIds(_storage.getDownloadedSongs,
      _downloadedIds, (ids) => _downloadedIds = ids);

  /// Likes/unlikes anywhere (player, Liked page) must reflect on these rows.
  Future<void> _loadLiked() =>
      _applyIds(_storage.getLikedSongs, _likedIds, (ids) => _likedIds = ids);

  Future<void> _toggleLike(Song song) async {
    await _storage.toggleLikedSong(song);
    await _loadLiked();
  }

  Future<void> _refreshFromStorage() async {
    final playlists = await _storage.getPlaylists();
    final match = playlists.where((p) => p.id == _playlist.id);
    if (match.isNotEmpty && mounted) {
      setState(() {
        _playlist = match.first;
      });
    }
  }

  static Widget _fallbackBackground() => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [AppColors.charcoal, AppColors.inkSoft],
          ),
        ),
        child: const Icon(Icons.queue_music, size: 80, color: Colors.white),
      );

  Future<void> _downloadPlaylist() async {
    if (_songs.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final close = showBlockingProgress(context, 'Downloading playlist...');
    final audioService = context.read<AudioPlayerService>();
    final downloadedIds = Set<String>.from(_playlist.downloadedSongIds);
    // Dismiss the modal unconditionally once the work is done, even if this
    // screen was popped meanwhile — otherwise the barrier-blocked route
    // outlives its owner and hard-locks the app.
    try {
      for (final song in _songs) {
        if (downloadedIds.contains(song.id)) continue;
        final ok = await audioService.downloadCurrentSongForSong(song,
            addToDownloadedPlaylist: false);
        if (ok) downloadedIds.add(song.id);
      }
    } finally {
      await close();
    }
    if (!mounted) return;
    // Protect only while offline content exists. Empty (all failed) stays normal.
    final updated = _playlist.copyWith(
      isDownloaded:
          downloadedIds.length == _songs.length && downloadedIds.isNotEmpty,
      downloadedSongIds: downloadedIds,
      isSystemManaged: downloadedIds.isNotEmpty,
    );
    await _storage.savePlaylist(updated);
    setState(() {
      _playlist = updated;
    });
    messenger.showSnackBar(
      SnackBar(
          content: Text(
              'Downloaded ${downloadedIds.length}/${_songs.length} songs')),
    );
    await _loadDownloaded();
  }

  Future<void> _addSongDialog() async {
    final ctrl = TextEditingController();
    final yt = YouTubeService();
    List<Song> results = [];
    bool searched = false;
    bool loading = false;

    final song = await showDialog<Song>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppColors.card,
          title: const Text('Add Song'),
          content: SizedBox(
            width: double.maxFinite,
            height: 350,
            child: Column(
              children: [
                TextField(
                  controller: ctrl,
                  decoration: const InputDecoration(
                    hintText: 'Search songs...',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (q) async {
                    if (q.trim().isEmpty) return;
                    // The dialog may be dismissed while the search is in
                    // flight: every state write must be guarded, including
                    // the one in `catch`, or the next write throws outside
                    // any handler.
                    if (!ctx.mounted) return;
                    setDialogState(() => loading = true);
                    try {
                      final r = await yt.search(q.trim(), limit: 10);
                      if (!ctx.mounted) return;
                      setDialogState(() {
                        results = r;
                        searched = true;
                        loading = false;
                      });
                    } catch (_) {
                      if (!ctx.mounted) return;
                      setDialogState(() => loading = false);
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (loading)
                  const Expanded(
                      child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2))),
                if (!loading && searched && results.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Text('No results',
                          style: TextStyle(color: AppColors.inkSoft)),
                    ),
                  ),
                if (results.isNotEmpty)
                  Expanded(
                    child: ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final s = results[i];
                        final already =
                            _playlist.songs.any((ps) => ps.id == s.id);
                        return MotionPress(
                          child: ListTile(
                            dense: true,
                            leading:
                                Artwork(s.thumbnailUrl, size: 40, radius: 8),
                            title: Text(s.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Text(s.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.inkSoft)),
                            trailing: already
                                ? const Icon(Icons.check,
                                    color: Colors.white, size: 20)
                                : null,
                            onTap: already ? null : () => Navigator.pop(ctx, s),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );

    yt.dispose();
    ctrl.dispose();
    if (song == null) return;
    await _storage.addSongToPlaylist(_playlist.id, song);
    await _refreshFromStorage();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added "${song.title}"')),
      );
    }
  }

  Future<void> _removeSong(Song song) async {
    // Deleting a downloaded track deletes the local file too; an online-only
    // track is simply removed from the playlist.
    if (_downloadedIds.contains(song.id)) {
      await _storage.removeSongAndDownload(_playlist.id, song.id);
      try {
        await CacheService().invalidate(song);
      } catch (_) {}
    } else {
      await _storage.removeSongFromPlaylist(_playlist.id, song.id);
    }
    await _refreshFromStorage();
    await _loadDownloaded();
  }

  bool get _playlistHasDownloads =>
      _songs.any((s) => _downloadedIds.contains(s.id));

  /// Recomputes this playlist's offline set from the global downloaded list.
  /// Runs after single/selected downloads so flags and the "downloaded"
  /// badge stay accurate when songs are added or removed.
  Future<void> _syncPlaylistDownloads() async {
    final dl = (await _storage.getDownloadedSongs()).map((s) => s.id).toSet();
    final ids =
        _songs.map((s) => s.id).where(dl.contains).toSet();
    final isDl = ids.isNotEmpty && ids.length == _songs.length;
    final updated = _playlist.copyWith(
      downloadedSongIds: ids,
      isDownloaded: isDl,
      isSystemManaged: ids.isNotEmpty,
    );
    await _storage.savePlaylist(updated);
    if (!mounted) return;
    setState(() {
      _playlist = updated;
      _downloadedIds = dl;
    });
  }

  Future<void> _downloadOne(Song song) async {
    if (_downloadingSingle || _downloadedIds.contains(song.id)) return;
    _downloadingSingle = true;
    try {
      await downloadSongFlow(context, song);
    } finally {
      _downloadingSingle = false;
    }
    await _loadDownloaded();
    await _syncPlaylistDownloads();
  }

  void _startSelection(int i) => setState(() => _sel.start(i));

  void _toggle(int i) => setState(() => _sel.toggle(i));

  void _exitSelection() {
    if (!_sel.selecting && _sel.selected.isEmpty) return;
    setState(_sel.exit);
  }

  Future<void> _downloadSelected() async {
    final todo = _selected
        .map((i) => _songs[i])
        .where((s) => !_downloadedIds.contains(s.id))
        .toList();
    if (todo.isEmpty) {
      _exitSelection();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final audio = context.read<AudioPlayerService>();
    final close = showBlockingProgress(context, 'Downloading selected...');
    var done = 0;
    try {
      for (final s in todo) {
        final ok = await audio.downloadCurrentSongForSong(s);
        if (ok) done++;
      }
    } finally {
      await close();
    }
    if (!mounted) return;
    _exitSelection();
    await _syncPlaylistDownloads();
    messenger.showSnackBar(
      SnackBar(content: Text('Downloaded $done/${todo.length} songs')),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final songs = _selected.map((i) => _songs[i]).toList();
    for (final s in songs) {
      if (_downloadedIds.contains(s.id)) {
        await _storage.removeSongAndDownload(_playlist.id, s.id);
        try {
          await CacheService().invalidate(s);
        } catch (_) {}
      } else {
        await _storage.removeSongFromPlaylist(_playlist.id, s.id);
      }
    }
    if (!mounted) return;
    _exitSelection();
    await _refreshFromStorage();
    await _loadDownloaded();
  }

  Widget _selectionBar() {
    final count = _selected.length;
    return SelectionBar(
      count: count,
      onCancel: _exitSelection,
      actions: [
        TextButton(
          onPressed: count == 0 ? null : _downloadSelected,
          child: const Text('Download'),
        ),
        if (_playlistHasDownloads)
          TextButton(
            onPressed: count == 0 ? null : _deleteSelected,
            child: const Text('Delete',
                style: TextStyle(
                    color: Colors.red, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSong =
        context.select<AudioPlayerService, bool>((s) => s.currentSong != null);
    final playlist = _playlist;
    final songs = _songs;

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              CustomScrollView(
                slivers: [
                  SliverAppBar(
                    expandedHeight: 250,
                    pinned: true,
                    flexibleSpace: FlexibleSpaceBar(
                      title: Text(
                        playlist.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (playlist.coverPath != null &&
                              playlist.coverPath!.isNotEmpty)
                            Image.file(
                              File(playlist.coverPath!),
                              fit: BoxFit.cover,
                              cacheWidth: 1024,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, __, ___) =>
                                  _fallbackBackground(),
                            )
                          else if (playlist.thumbnailUrl != null)
                            Artwork(
                              playlist.thumbnailUrl!,
                              radius: 0,
                              fillWidth: true,
                              fit: BoxFit.cover,
                              height: 250,
                            )
                          else
                            _fallbackBackground(),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0xFF0D0D0D)],
                                stops: [0.5, 1.0],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      if (songs.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.play_circle_fill),
                          onPressed: () {
                            playSongs(
                              context,
                              song: songs.first,
                              queue: songs,
                              index: 0,
                              queueOrigin: 'playlist',
                            );
                          },
                        ),
                      PopupMenuButton(
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'add_song',
                            child: Text('Add Song'),
                          ),
                          const PopupMenuItem(
                            value: 'play_all',
                            child: Text('Play All'),
                          ),
                          const PopupMenuItem(
                            value: 'shuffle',
                            child: Text('Shuffle'),
                          ),
                          const PopupMenuItem(
                            value: 'download',
                            child: Text('Download playlist'),
                          ),
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('Rename playlist'),
                          ),
                          const PopupMenuItem(
                            value: 'cover',
                            child: Text('Change cover'),
                          ),
                          if (playlist.coverPath != null &&
                              playlist.coverPath!.isNotEmpty)
                            const PopupMenuItem(
                              value: 'remove_cover',
                              child: Text('Remove cover'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete Playlist'),
                          ),
                        ],
                        onSelected: (value) async {
                          if (value == 'download') {
                            _downloadPlaylist();
                          } else if (value == 'add_song') {
                            _addSongDialog();
                          } else if (value == 'play_all' && songs.isNotEmpty) {
                            playSongs(
                              context,
                              song: songs.first,
                              queue: songs,
                              index: 0,
                              queueOrigin: 'playlist',
                            );
                          } else if (value == 'shuffle' && songs.isNotEmpty) {
                            final shuffled = List<Song>.from(songs)..shuffle();
                            playSongs(
                              context,
                              song: shuffled.first,
                              queue: shuffled,
                              index: 0,
                              queueOrigin: 'playlist',
                            );
                          } else if (value == 'rename') {
                            await _renamePlaylist();
                          } else if (value == 'cover') {
                            final picked = await _pickPlaylistCover(context);
                            if (picked != null && mounted) {
                              setState(() {});
                            }
                          } else if (value == 'remove_cover') {
                            final old = playlist.coverPath;
                            await _storage.updateCover(playlist.id, null);
                            if (old != null && old.isNotEmpty) {
                              try {
                                await File(old).delete();
                              } catch (_) {}
                            }
                            if (mounted) {
                              setState(() {
                                _playlist = _playlist.copyWith(coverPath: null);
                              });
                            }
                          } else if (value == 'delete') {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete Playlist?'),
                                content: Text(
                                  'Delete "${playlist.name}"? This cannot be undone.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text(
                                      'Delete',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await _storage.deletePlaylist(playlist.id);
                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            }
                          }
                        },
                      ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (playlist.description != null &&
                              playlist.description!.isNotEmpty)
                            Text(
                              playlist.description!,
                              style: const TextStyle(color: AppColors.inkSoft),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            '${songs.length} songs',
                            style: const TextStyle(color: AppColors.inkSoft),
                          ),
                          if (playlist.source != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  playlist.source == 'youtube'
                                      ? Icons.youtube_searched_for
                                      : Icons.music_note,
                                  size: 14,
                                  color: AppColors.mute,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Imported from ${playlist.source}',
                                  style: const TextStyle(
                                    color: AppColors.mute,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (songs.isEmpty)
                    const SliverFillRemaining(
                      child: Center(
                        child: Text(
                          'No songs yet — tap + to add',
                          style: TextStyle(color: AppColors.inkSoft),
                        ),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final s = songs[index];
                          final selected = _selected.contains(index);
                          final isDownloaded =
                              _downloadedIds.contains(s.id);
                          return MotionPress(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              onLongPress: _selecting
                                  ? null
                                  : () => _startSelection(index),
                              leading: Stack(
                                children: [
                                  Artwork(s.thumbnailUrl, size: 50, radius: 8),
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: const BoxDecoration(
                                        color: Colors.black54,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.play_arrow,
                                          color: Colors.white, size: 14),
                                    ),
                                  ),
                                  // Online-only tracks show a tappable
                                  // download sign on the left.
                                  if (!isDownloaded)
                                    Positioned(
                                      bottom: 0,
                                      left: 0,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: _selecting
                                            ? null
                                            : () => _downloadOne(s),
                                        child: Container(
                                          padding: const EdgeInsets.all(3),
                                          decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                              Icons.download_for_offline_outlined,
                                              color: Colors.white,
                                              size: 14),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              title: Text(s.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w500)),
                              subtitle: Text(s.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: AppColors.inkSoft, fontSize: 13)),
                              trailing: _selecting
                                  ? SelectionCheck(selected)
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: _likedIds.contains(s.id)
                                              ? 'Unlike'
                                              : 'Like',
                                          icon: Icon(
                                            _likedIds.contains(s.id)
                                                ? Icons.favorite
                                                : Icons.favorite_border,
                                            size: 20,
                                            color: AppColors.ink,
                                          ),
                                          onPressed: () => _toggleLike(s),
                                        ),
                                        SongMenuButton(
                                          song: s,
                                          queue: songs,
                                          index: index,
                                          queueOrigin: 'playlist',
                                          // Removing a track from a playlist
                                          // also deletes its download.
                                          onRemoveFromPlaylist: () =>
                                              _removeSong(s),
                                        ),
                                      ],
                                    ),
                              onTap: () {
                                if (_selecting) {
                                  _toggle(index);
                                  return;
                                }
                                playSongs(
                                  context,
                                  song: s,
                                  queue: songs,
                                  index: index,
                                  queueOrigin: 'playlist',
                                );
                              },
                            ),
                          );
                        },
                        childCount: songs.length,
                      ),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 170)),
                ],
              ),
              if (hasSong)
                const Positioned(
                    left: 16, right: 16, bottom: 8, child: MiniPlayer()),
              if (_selecting)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: hasSong ? 100 : 16,
                  child: _selectionBar(),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Future<void> _renamePlaylist() async {
    final ctrl = TextEditingController(text: _playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text('Rename playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
              hintText: 'Playlist name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    await _storage.renamePlaylist(_playlist.id, name);
    if (!mounted) return;
    setState(() => _playlist = _playlist.copyWith(name: name));
  }

  Future<File?> _pickPlaylistCover(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
      maxWidth: 512,
      maxHeight: 512,
    );
    if (picked == null) return null;
    final dir = await getApplicationDocumentsDirectory();
    final dest = File('${dir.path}/playlist_cover_${widget.playlist.id}.jpg');
    await File(picked.path).copy(dest.path);
    await _storage.updateCover(widget.playlist.id, dest.path);
    if (mounted) {
      setState(() {
        _playlist = _playlist.copyWith(coverPath: dest.path);
      });
    }
    return dest;
  }
}
