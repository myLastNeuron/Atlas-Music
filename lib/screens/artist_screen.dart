import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/play_helper.dart';
import '../widgets/song_actions.dart';
import 'song_collection_screen.dart';

/// An artist's page: header, top songs and an albums/singles rail. Opened from
/// the full player's artist name. Built entirely from YouTube Music browse
/// data on open — nothing here is stored, so it stays correct for every song
/// (local, imported, cached) that only carries an artist *name*.
class ArtistScreen extends StatefulWidget {
  static const routeName = '/artist';
  final String name;
  final String? thumbnailUrl;

  const ArtistScreen({super.key, required this.name, this.thumbnailUrl});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  final YouTubeService _yt = YouTubeService();
  ArtistPage? _page;
  bool _loading = true;
  String? _error;
  // Overlapping loads (retry tapped fast): only the latest may publish.
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _yt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _yt.artistByName(widget.name,
          fallbackThumbnail: widget.thumbnailUrl);
      if (!mounted || gen != _gen) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
      });
    }
  }

  void _playSong(Song song, List<Song> songs) {
    final index = songs.indexWhere((s) => s.id == song.id);
    playSongs(context,
        song: song,
        queue: songs,
        index: index < 0 ? 0 : index,
        queueOrigin: 'artist');
  }

  void _openAlbum(AlbumRef album) {
    pushAppPage(
      context,
      SongCollectionScreen(
        title: album.title,
        listKey: 'album_${album.browseId}',
        emptyIcon: Icons.album_outlined,
        emptyTitle: 'No songs found',
        emptyHint: 'This release has no playable tracks right now.',
        reloadOnStorage: false,
        load: () => _yt.albumSongs(album.browseId),
        trailing: (s, i, queue) => SongMenuButton(
          song: s,
          queue: queue,
          index: i,
          queueOrigin: 'album',
        ),
      ),
    );
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
          title: Text(widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
                child: _body(),
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

  Widget _body() {
    if (_loading) {
      return const Center(
        key: ValueKey('artist_loading'),
        child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final error = _error;
    if (error != null) {
      return Center(
        key: const ValueKey('artist_error'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 44, color: AppColors.mute),
              const SizedBox(height: 12),
              const Text('Could not load artist',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink)),
              const SizedBox(height: 6),
              Text(error,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.inkSoft)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final page = _page;
    if (page == null || page.isEmpty) {
      return const Center(
        key: ValueKey('artist_empty'),
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_outline, size: 44, color: AppColors.mute),
              SizedBox(height: 12),
              Text('No music found',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink)),
              SizedBox(height: 6),
              Text('Nothing to show for this artist right now.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
            ],
          ),
        ),
      );
    }
    final hasAlbums = page.albums.isNotEmpty;
    final hasSongs = page.songs.isNotEmpty;
    final count = 1 +
        (hasAlbums ? 2 : 0) +
        (hasSongs ? 1 + page.songs.length : 0);
    return ListView.builder(
      key: const ValueKey('artist_content'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(top: 8, bottom: 190),
      itemCount: count,
      itemBuilder: (context, i) {
        if (i == 0) return _header(page);
        var idx = i - 1;
        if (hasAlbums) {
          if (idx == 0) return _albumsTitle();
          if (idx == 1) return _albumsRail(page.albums);
          idx -= 2;
        }
        if (idx == 0) return _songsTitle();
        return _songTile(page.songs[idx - 1], idx - 1, page.songs);
      },
    );
  }

  Widget _header(ArtistPage page) {
    final image = page.imageUrl ?? widget.thumbnailUrl ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Column(
        children: [
          Artwork(image, size: 120, radius: 60, fit: BoxFit.cover),
          const SizedBox(height: 14),
          Text(page.name.isEmpty ? widget.name : page.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.ink)),
          const SizedBox(height: 4),
          const Text('Artist',
              style: TextStyle(fontSize: 13, color: AppColors.mute)),
        ],
      ),
    );
  }

  Widget _albumsTitle() => const Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text('Albums & singles',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      );

  Widget _albumsRail(List<AlbumRef> albums) {
    return SizedBox(
      height: 196,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final album = albums[i];
          return MotionPress(
            child: GestureDetector(
              onTap: () => _openAlbum(album),
              child: Container(
                width: 140,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(album.thumbnailUrl ?? '',
                        width: 140, height: 140, radius: 14),
                    const SizedBox(height: 8),
                    Text(album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.ink,
                            fontSize: 13,
                            fontWeight: FontWeight.w500)),
                    if (album.year != null)
                      Text(album.year!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.inkSoft, fontSize: 11)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _songsTitle() => const Padding(
        padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Text('Songs',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.ink)),
      );

  Widget _songTile(Song song, int i, List<Song> songs) {
    return MotionPress(
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Artwork(song.thumbnailUrl, size: 48, radius: 10),
        title: Text(song.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.ink)),
        subtitle: Text(
            song.duration.inSeconds > 0
                ? formatClock(song.duration)
                : song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.inkSoft, fontSize: 12)),
        trailing: SongMenuButton(
          song: song,
          queue: songs,
          index: i,
          queueOrigin: 'artist',
        ),
        onTap: () => _playSong(song, songs),
      ),
    );
  }
}
