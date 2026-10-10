import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/spotify_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/friendly_error.dart';
import '../widgets/liquid_background.dart';
import '../widgets/artwork.dart';
import 'history_screen.dart';
import 'liked_songs_screen.dart';
import 'offline_music_screen.dart';
import 'playlist_detail_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _storage = StorageService.instance;
  final _yt = YouTubeService();
  List<Playlist> _playlists = [];
  bool _loading = true;
  bool _loadBusy = false;
  bool _loadQueued = false;
  // Guards the quick actions (Import / Liked / Recent) against a second
  // tap firing while the first dialog/route is still opening.
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _storage.addListener(_onStorageChanged);
    _load();
  }

  @override
  void dispose() {
    _storage.removeListener(_onStorageChanged);
    _yt.dispose();
    super.dispose();
  }

  void _onStorageChanged() {
    if (_loadBusy) {
      _loadQueued = true;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    if (_loadBusy) {
      _loadQueued = true;
      return;
    }
    _loadBusy = true;
    try {
      final p = (await _storage.getPlaylists())
          .where((pl) => pl.id != StorageService.downloadedPlaylistId)
          .toList();
      if (!mounted) return;

      setState(() {
        _playlists = p;
        _loading = false;
      });
    } finally {
      _loadBusy = false;
      if (_loadQueued) {
        _loadQueued = false;
        _load();
      }
    }
  }

  Future<void> _import() async {
    if (_actionBusy) return;
    _actionBusy = true;
    try {
      await _importFlow();
    } finally {
      _actionBusy = false;
    }
  }

  Future<void> _importFlow() async {
    final src = await _importSource();
    if (src == null) return;
    if (src == 'spotify') {
      await _importSpotify();
      return;
    }
    if (src == 'paste') {
      await _importPasted();
      return;
    }
    if (!mounted) return;
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Import YouTube Playlist'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
              hintText: 'Paste playlist URL or ID',
              border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Import')),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return;
    final text = result.trim();
    final m = RegExp(r'[?&]list=([a-zA-Z0-9_-]+)').firstMatch(text);
    final id = m != null
        ? m.group(1)!
        : (RegExp(r'^[a-zA-Z0-9_-]{10,}$').hasMatch(text) ? text : null);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (id == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Import failed. Check link.')),
      );
      return;
    }
    await _runYouTubeImport(id);
  }

  /// Shared YouTube import runner: progress, fetch, save, toast.
  Future<void> _runYouTubeImport(String id) async {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: AppColors.glass,
        content: Row(children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Text('Importing playlist...')
        ]),
      ),
    ).whenComplete(() => dialogOpen = false);
    try {
      final pl = await _yt.getPlaylist(id);
      await _storage.savePlaylist(pl);
      if (dialogOpen && navigator.canPop()) navigator.pop();
      _load();
      messenger.showSnackBar(
        SnackBar(content: Text('Imported "${pl.name}" (${pl.songs.length})')),
      );
    } catch (_) {
      if (dialogOpen && navigator.canPop()) navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Import failed. Check link.')),
      );
    }
  }

  /// YouTube vs Spotify source picker for import/clone.
  Future<String?> _importSource() {
    return showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Import playlist'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'youtube'),
            child: const Row(
              children: [
                Icon(Icons.smart_display_outlined,
                    size: 20, color: AppColors.inkSoft),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('YouTube',
                          style: TextStyle(fontWeight: FontWeight.w500)),
                      Text('Paste playlist URL or ID',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'spotify'),
            child: const Row(
              children: [
                Icon(Icons.music_note_outlined,
                    size: 20, color: AppColors.inkSoft),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Spotify (clone)',
                          style: TextStyle(fontWeight: FontWeight.w500)),
                      Text('Needs API keys · match each track',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'paste'),
            child: const Row(
              children: [
                Icon(Icons.content_paste_outlined,
                    size: 20, color: AppColors.inkSoft),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Paste track list',
                          style: TextStyle(fontWeight: FontWeight.w500)),
                      Text('No keys needed · one per line',
                          style: TextStyle(
                              fontSize: 12, color: AppColors.inkSoft)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Clone a Spotify playlist: read its tracks via Spotify Web API, match
  /// each to a playable song, save as a local playlist. Needs the user's
  /// own Spotify Client ID/Secret once (free at
  /// developer.spotify.com/dashboard).
  Future<void> _importSpotify() async {
    final sp = SpotifyService();
    try {
      if (!await sp.hasCredentials()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Add Spotify keys in Profile → Spotify first')),
        );
        return;
      }
      if (!mounted) return;
      final linkCtrl = TextEditingController();
      final link = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.glass,
          title: const Text('Clone Spotify playlist'),
          content: TextField(
            controller: linkCtrl,
            decoration: const InputDecoration(
                hintText: 'Paste Spotify playlist link or ID',
                border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(context, linkCtrl.text),
                child: const Text('Clone')),
          ],
        ),
      );
      linkCtrl.dispose();
      if (link == null || link.trim().isEmpty) return;
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context, rootNavigator: true);

      var matched = 0;
      var total = 0;
      void Function(void Function())? setProg;
      var dialogOpen = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => StatefulBuilder(
          builder: (_, setSt) {
            setProg = setSt;
            return AlertDialog(
              backgroundColor: AppColors.glass,
              content: Row(children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(
                  child: Text(total == 0
                      ? 'Reading Spotify tracks...'
                      : 'Matching $matched/$total...'),
                ),
              ]),
            );
          },
        ),
      ).whenComplete(() => dialogOpen = false);
      Playlist pl;
      try {
        pl = await sp.clonePlaylist(
          yt: _yt,
          playlistIdOrUrl: link.trim(),
          onProgress: (d, t) {
            matched = d;
            total = t;
            try {
              setProg?.call(() {});
            } catch (_) {}
          },
        );
      } catch (_) {
        if (dialogOpen && navigator.canPop()) navigator.pop();
        rethrow;
      }
      if (dialogOpen && navigator.canPop()) navigator.pop();
      await _storage.savePlaylist(pl);
      if (!mounted) return;
      _load();
      messenger.showSnackBar(
        SnackBar(content: Text('Cloned "${pl.name}" (${pl.songs.length})')),
      );
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      final authish = raw.toLowerCase().contains('auth') ||
          raw.contains('401') ||
          raw.toLowerCase().contains('credential');
      if (authish) {
        // Bad secret: forget it so the next attempt re-prompts.
        await sp.clearCredentials();
      }
      if (!mounted) return;
      await showFriendlyError(context,
          title: 'Couldn\'t clone this Spotify playlist', error: e);
    }
  }

  /// Keyless clone: paste "Title - Artist" lines (or a Spotify desktop
  /// copy), match each to playable audio. No API, no keys.
  Future<void> _importPasted() async {
    final nameCtrl = TextEditingController();
    final tracksCtrl = TextEditingController();
    final input = await showDialog<List<String>>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Paste track list'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                      hintText: 'Playlist name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                const Text(
                  'One per line: Title - Artist. Spotify copies paste as-is.',
                  style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tracksCtrl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                      hintText: 'Blinding Lights - The Weeknd\n...',
                      border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.pop(context, [nameCtrl.text, tracksCtrl.text]),
              child: const Text('Clone')),
        ],
      ),
    );
    final name = (input != null && input.isNotEmpty ? input[0] : '');
    final text = (input != null && input.length > 1 ? input[1] : '');
    nameCtrl.dispose();
    tracksCtrl.dispose();
    if (input == null || text.trim().isEmpty) return;
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    var matched = 0;
    var total = 0;
    void Function(void Function())? setProg;
    var dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (_, setSt) {
          setProg = setSt;
          return AlertDialog(
            backgroundColor: AppColors.glass,
            content: Row(children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(
                child: Text(total == 0
                    ? 'Reading tracks...'
                    : 'Matching $matched/$total...'),
              ),
            ]),
          );
        },
      ),
    ).whenComplete(() => dialogOpen = false);
    try {
      final pl = await SpotifyService().cloneFromText(
        yt: _yt,
        name: name,
        text: text,
        onProgress: (d, t) {
          matched = d;
          total = t;
          try {
            setProg?.call(() {});
          } catch (_) {}
        },
      );
      // Pop exactly once, before the save. If savePlaylist below throws, the
      // catch must NOT pop again or it dismisses the Library screen too.
      if (dialogOpen && navigator.canPop()) navigator.pop();
      await _storage.savePlaylist(pl);
      if (!mounted) return;
      _load();
      messenger.showSnackBar(
        SnackBar(content: Text('Cloned "${pl.name}" (${pl.songs.length})')),
      );
    } catch (e) {
      // Only close the dialog if it is still open (save failure after pop).
      if (dialogOpen && navigator.canPop()) navigator.pop();
      if (!mounted) return;
      await showFriendlyError(context,
          title: 'Couldn\'t clone this playlist', error: e);
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.glass,
        title: const Text('Create Playlist'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Playlist name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Create')),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return;
    await _storage.savePlaylist(Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: result,
      songs: [],
      createdAt: DateTime.now(),
      source: 'local',
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final hasSong =
        context.select<AudioPlayerService, bool>((s) => s.currentSong != null);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: AppMotion.dur(context, AppMotion.modal),
          switchInCurve: AppMotion.curve,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: fadeRiseTransition,
          child: _loading
              ? const Center(
                  key: ValueKey('library_loading'),
                  child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : CustomScrollView(
                  key: const ValueKey('library_content'),
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding:
                            const EdgeInsets.only(left: 20, right: 12, top: 14),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Your Library',
                                style: TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w700)),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: _create,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: GlassPanel(
                          radius: 20,
                          padding: const EdgeInsets.all(6),
                          opacity: 0.07,
                          child: Row(
                            children: [
                              _quick(Icons.download, 'Import', _import),
                              _quick(
                                  Icons.favorite_outline, 'Liked', _openLiked),
                              _quick(Icons.history, 'Recent', _openHistory),
                              _quick(Icons.download_done, 'Offline Music',
                                  _openOfflineMusic),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Text('Playlists',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (_playlists.isEmpty)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(
                            child: Text(
                              'No playlists yet\nTap + to create or import',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.inkSoft),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final p = _playlists[i];
                            return MotionPress(
                              child: ListTile(
                                leading: (p.thumbnailUrl ?? '').isEmpty
                                    ? Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          color: AppColors.mist,
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.queue_music,
                                            color: AppColors.mute),
                                      )
                                    : Artwork(
                                        p.thumbnailUrl!,
                                        size: 48,
                                        radius: 10,
                                      ),
                                title: Text(p.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text('${p.songs.length} songs',
                                    style: const TextStyle(
                                        color: AppColors.inkSoft)),
                                trailing: const Icon(Icons.chevron_right,
                                    color: AppColors.mute),
                                onTap: () async {
                                  await pushAppPage(
                                    context,
                                    PlaylistDetailScreen(playlist: p),
                                  );
                                  _load();
                                },
                              ),
                            );
                          },
                          childCount: _playlists.length,
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.only(bottom: hasSong ? 190 : 120),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _openLiked() async {
    if (_actionBusy) return;
    _actionBusy = true;
    try {
      await pushAppPage(context, const LikedSongsScreen());
      _load();
    } finally {
      _actionBusy = false;
    }
  }

  Future<void> _openHistory() async {
    if (_actionBusy) return;
    _actionBusy = true;
    try {
      await pushAppPage(context, const HistoryScreen());
      // History may have been pruned; playlists/state are unaffected but a
      // reload keeps counts fresh if anything changed.
      _load();
    } finally {
      _actionBusy = false;
    }
  }

  Future<void> _openOfflineMusic() async {
    if (_actionBusy) return;
    _actionBusy = true;
    try {
      await pushAppPage(context, const OfflineMusicScreen());
      _load();
    } finally {
      _actionBusy = false;
    }
  }

  Widget _quick(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: MotionPress(
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(height: 6),
                Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
