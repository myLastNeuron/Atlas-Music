import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/artwork_color.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/theme_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/play_next_badge.dart';
import '../widgets/song_actions.dart';
import '../widgets/video_stats_bar.dart';
import '../widgets/whats_next_sheet.dart';
import 'artist_screen.dart';

class PlayerScreen extends StatefulWidget {
  static const routeName = '/player';
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  final StorageService _storageService = StorageService();
  bool _isLiked = false;
  String? _likedForId;
  AudioPlayerService? _audio;
  VoidCallback? _audioListener;

  /// Anchors the "song actions" menu under the header's overflow button.
  final GlobalKey _moreKey = GlobalKey();

  /// Identity of the two tracks the up-next peek is showing. The queue grows
  /// asynchronously (the service builds a continuation when the queue runs
  /// dry), so the peek has to notice that on its own — none of the selective
  /// subscriptions in [build] change when songs are appended.
  String _upcomingKey = '';

  /// Dominant colour of the current artwork, and the song it was read from.
  /// Null means the player keeps the app palette (option off, or not loaded).
  Color? _accent;
  String? _accentFor;

  // Slow "breathing" scale on the cover while a track is playing. Driven by
  // one controller, applied with Transform only (no layout, no repaint).
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  bool _breathing = false;
  late final Animation<double> _breathScale = Tween<double>(
    begin: 1.0,
    end: 1.02,
  ).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    final audio = context.read<AudioPlayerService>();
    _audio = audio;
    // Re-check on song change (auto-advance) and on any like toggled
    // elsewhere (Liked page / playlist rows) so the heart never goes stale.
    // The same tick keeps the cover breath in sync with play/pause.
    _audioListener = () {
      _syncLiked();
      _syncBreath();
      _syncUpcoming();
    };
    audio.addListener(_audioListener!);
    _storageService.addListener(_onStorageChanged);
  }

  @override
  void dispose() {
    _audio?.removeListener(_audioListener!);
    _storageService.removeListener(_onStorageChanged);
    _breath.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLiked();
    _syncBreath();
  }

  /// Runs the cover breath only while playing and when motion is allowed;
  /// a paused player stays completely calm.
  void _syncBreath() {
    if (!mounted) return;
    final should = (_audio?.isPlaying ?? false) && !AppMotion.reduced(context);
    if (should == _breathing) return;
    _breathing = should;
    if (should) {
      _breath.repeat(reverse: true);
    } else {
      _breath.stop();
      _breath.value = 0;
    }
  }

  void _onStorageChanged() => _syncLiked(force: true);

  /// Rebuild when the up-next peek changes. The service appends a
  /// continuation in the background, and that notify changes none of the
  /// fields [build] selects, so the peek would otherwise stay empty until
  /// something else moved.
  void _syncUpcoming() {
    final key = _audio?.upcoming.take(2).map((s) => s.id).join('|') ?? '';
    if (key == _upcomingKey) return;
    _upcomingKey = key;
    if (mounted) setState(() {});
  }

  Future<void> _syncLiked({bool force = false}) async {
    final audioService = context.read<AudioPlayerService>();
    final cur = audioService.currentSong;
    if (cur == null) return;
    if (!force && _likedForId == cur.id) return;
    _likedForId = cur.id;
    final liked = await _storageService.isSongLiked(cur.id);
    if (mounted && _likedForId == cur.id) {
      setState(() => _isLiked = liked);
    }
  }

  Future<void> _toggleLike() async {
    final audioService = context.read<AudioPlayerService>();
    if (audioService.currentSong != null) {
      await _storageService.toggleLikedSong(audioService.currentSong!);
      // Explicit toggle bypasses song-id guard so heart refreshes.
      _likedForId = null;
      _syncLiked();
    }
  }

  Future<void> _skip(Future<bool> Function() action) async {
    final ok = await action();
    if (!ok && mounted) {
      final reason = context.read<AudioPlayerService>().lastFailure;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(reason == null
              ? 'Could not play that song'
              : 'Could not play: $reason'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// The same per-song menu every list uses, anchored under the header's
  /// overflow button. The player is the one screen with no row to long-press,
  /// so without this its queue/export/add actions were unreachable.
  void _openSongActions() {
    final audio = context.read<AudioPlayerService>();
    final song = audio.currentSong;
    if (song == null) return;
    Rect? anchor;
    final box = _moreKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      anchor = box.localToGlobal(Offset.zero) & box.size;
    }
    showSongActions(
      context,
      song: song,
      queue: audio.queue,
      anchor: anchor,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Selective subscriptions: parent rebuilds on song/transport only,
    // never on 1/sec position ticks (those live in [_PlayerSlider]).
    final audioService = context.read<AudioPlayerService>();
    final song =
        context.select<AudioPlayerService, Song?>((s) => s.currentSong);
    // Resolved high-res cover (same file the notification uses); null until
    // the download finishes, in which case the network thumbnail is shown.
    final artPath = context.select<AudioPlayerService, String?>(
        (s) => s.highResArtPathFor(s.currentSong));
    final hasSong = song != null;
    final artistName = song?.artist.trim() ?? '';
    final canOpenArtist =
        artistName.isNotEmpty && artistName.toLowerCase() != 'unknown';
    final isLoading =
        context.select<AudioPlayerService, bool>((s) => s.isLoading);
    // The queue fills in the background after the audio load ends, so the
    // placeholder follows the refill, not the load.
    final upNextLoading =
        context.select<AudioPlayerService, bool>((s) => s.upNextLoading);
    final isPlaying =
        context.select<AudioPlayerService, bool>((s) => s.isPlaying);
    final lastFailure =
        context.select<AudioPlayerService, String?>((s) => s.lastFailure);
    final pausedForOffline =
        context.select<AudioPlayerService, bool>((s) => s.pausedForOffline);
    final degraded =
        context.select<AudioPlayerService, bool>((s) => s.degradedOffline);
    final shuffle =
        context.select<AudioPlayerService, bool>((s) => s.shuffleEnabled);
    final loop =
        context.select<AudioPlayerService, LoopMode>((s) => s.loopMode);
    final upcoming = audioService.upcoming;

    // Artwork colour is opt-in and player-only: everything else stays on the
    // app palette.
    final artworkColor =
        context.select<ThemeSettings, bool>((s) => s.artworkColor);
    if (artworkColor && song != null) {
      if (song.id != _accentFor) _loadAccent(song, artPath);
    } else if (_accent != null) {
      _accent = null;
      _accentFor = null;
    }
    final accent = artworkColor ? _accent : null;

    return LiquidBackground(
      gradient: accent == null
          ? null
          : LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                    accent.withValues(alpha: 0.38), AppColors.paper),
                Color.alphaBlend(
                    accent.withValues(alpha: 0.12), AppColors.paper),
              ],
            ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.keyboard_arrow_down,
                size: 30, color: AppColors.ink),
            onPressed: () => Navigator.pop(context),
          ),
          // An eyebrow, not a title: the song owns the typographic weight.
          title: Text(
            'NOW PLAYING',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.6,
              color: AppColors.mute,
            ),
          ),
          centerTitle: true,
          actions: [
            if (hasSong)
              IconButton(
                key: _moreKey,
                tooltip: 'Song actions',
                icon: Icon(Icons.more_vert, color: AppColors.inkSoft),
                onPressed: _openSongActions,
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isLoading &&
                    !isPlaying &&
                    (lastFailure != null ||
                        (hasSong && (pausedForOffline || degraded)))) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      hasSong && pausedForOffline
                          ? 'Paused: offline and not downloaded'
                          : hasSong && degraded
                              ? 'Stopped: some tracks need internet'
                              : 'Stopped: $lastFailure',
                      style:
                          TextStyle(color: AppColors.mute, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (song != null) ...[
                  // The cover takes whatever height the fixed rows leave, so
                  // the player always fits its screen. Nothing scrolls, which
                  // is what let the whole page be dragged up and down.
                  // shortcut: an extremely short viewport (landscape) can
                  // still clip the bottom row; add a scroll fallback if the
                  // player has to work in landscape.
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final side = box.maxWidth < box.maxHeight
                            ? box.maxWidth
                            : box.maxHeight;
                        return Center(child: _cover(song, artPath, side));
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  _titleBlock(song, canOpenArtist),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: VideoStatsBar(videoId: song.videoId ?? song.id),
                  ),
                  if (upcoming.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _upNextBlock(upcoming),
                    const SizedBox(height: 12),
                  ] else if (isLoading || upNextLoading) ...[
                    // The queue grows asynchronously, so "nothing next" while a
                    // load or a refill is running means "not known yet", not
                    // "the queue ended".
                    const SizedBox(height: 12),
                    const _UpNextSkeleton(),
                    const SizedBox(height: 12),
                  ],
                  _PlayerSlider(accent: accent),
                  const SizedBox(height: 4),
                  _transport(
                      audioService, isPlaying, shuffle, loop, accent, isLoading),
                  const SizedBox(height: 16),
                  _actionRow(song, audioService),
                ] else ...[
                  const Spacer(),
                  Icon(Icons.music_note, size: 88, color: AppColors.mute),
                  const SizedBox(height: 12),
                  Text('No song playing',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.inkSoft)),
                  const Spacer(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reads the artwork's dominant colour for the tint. Called from [build]
  /// when the song changes; the result only repaints the player.
  void _loadAccent(Song song, String? artPath) {
    _accentFor = song.id;
    _accent = null;
    dominantArtworkColor(song.thumbnailUrl, filePath: artPath).then((color) {
      if (!mounted || _accentFor != song.id) return;
      setState(() => _accent = color);
    });
  }

  /// Ink that stays readable on a filled [color].
  static Color _onColor(Color color) => color.computeLuminance() > 0.55
      ? const Color(0xFF13131A)
      : Colors.white;

  /// Artwork alone, no frame: a soft drop shadow and a glass rim. A panel
  /// around the cover read as a card inside a card, and made the breathing
  /// animation wobble a border instead of the art.
  Widget _cover(Song song, String? artPath, double size) {
    final radius = BorderRadius.circular(22);
    return ScaleTransition(
      scale: _breathScale,
      child: RepaintBoundary(
        // Sized by the layout, not by AspectRatio: the cover shrinks to fit the
        // screen instead of pushing the column into a scroll view.
        child: SizedBox(
          width: size,
          height: size,
          child: Hero(
            // Same per-route tag the tapping mini bar stored: the cover only
            // flies when that exact bar is the source.
            tag: playerHeroTag,
            createRectTween: (begin, end) =>
                PlayerRectTween(begin: begin, end: end),
            // The cover morphs into the big cover on open and back onto the
            // thumb on close.
            flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                CoverFlightShuttle(song.thumbnailUrl,
                    filePath: artPath, animation: anim),
            // The landing spot stays empty while the shuttle flies. It is
            // still mounted (Offstage) so it is already decoded when the
            // shuttle lands instead of blinking in. Hiding it on close too
            // keeps a second copy from sitting under the shrinking page.
            placeholderBuilder: (context, size, child) => SizedBox(
              width: size.width,
              height: size.height,
              child: Offstage(child: child),
            ),
            // Shadow and rim live inside the Hero, so nothing of the cover is
            // left behind at the landing spot during the flight.
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 40,
                    spreadRadius: -6,
                    offset: const Offset(0, 22),
                  ),
                ],
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: AnimatedSwitcher(
                duration: AppMotion.dur(context, AppMotion.micro),
                switchInCurve: AppMotion.curve,
                switchOutCurve: AppMotion.curve,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Artwork(
                  song.thumbnailUrl,
                  key: ValueKey(song.id),
                  filePath: artPath,
                  size: size,
                  radius: 22,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Left-aligned title block. The heart lives with the song instead of in
  /// the app bar, where it competed with the close affordance.
  Widget _titleBlock(Song song, bool canOpenArtist) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          song.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 25,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Expanded(
              child: canOpenArtist
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (var i = 0; i < song.artistNames.length; i++) ...[
                            if (i > 0)
                              Text(' · ',
                                  style: TextStyle(
                                      fontSize: 14, color: AppColors.mute)),
                            InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () => pushAppPage(
                                context,
                                ArtistScreen(
                                  name: song.artistNames[i],
                                  thumbnailUrl: song.thumbnailUrl,
                                ),
                              ),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Text(song.artistNames[i],
                                    style: TextStyle(
                                        fontSize: 14,
                                        color: AppColors.inkSoft)),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : Text(
                      song.artist,
                      style: TextStyle(
                          fontSize: 14, color: AppColors.inkSoft),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _toggleLike,
              visualDensity: VisualDensity.compact,
              icon: AnimatedSwitcher(
                duration: AppMotion.dur(context, AppMotion.micro),
                switchInCurve: AppMotion.spring,
                switchOutCurve: AppMotion.curve,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: Icon(
                  _isLiked ? Icons.favorite : Icons.favorite_border,
                  key: ValueKey(_isLiked),
                  color: _isLiked ? AppColors.ink : AppColors.mute,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Two-track "up next" peek. A full-width square cover plus a couple of
  /// controls never fills a tall phone, so the middle of the screen shows the
  /// tracks that actually follow, in queue order. Tapping a row plays it; the
  /// full list with reasons and Rethink is behind the "Next up" button.
  Widget _upNextBlock(List<Song> songs) {
    final pinned = context.read<AudioPlayerService>().pinnedNext?.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'UP NEXT',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
            color: AppColors.mute,
          ),
        ),
        const SizedBox(height: 2),
        for (final next in songs.take(2))
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _skip(() {
              final audio = context.read<AudioPlayerService>();
              final at = audio.queue.indexWhere((s) => s.id == next.id);
              // The first peek row can be the pending "Play next" override,
              // which is not in the queue yet — play it directly.
              if (at < 0) return audio.playSong(next);
              return audio.playQueued(at);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Artwork(next.thumbnailUrl, size: 36, radius: 7),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(next.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink)),
                        const SizedBox(height: 1),
                        Text(next.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11, color: AppColors.mute)),
                      ],
                    ),
                  ),
                  if (pinned != null && pinned == next.id) ...[
                    const SizedBox(width: 8),
                    const PlayNextBadge(),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }


  /// One row, no pill: play is the only heavy element, shuffle and repeat
  /// are demoted to quiet glyphs at the edges.
  Widget _transport(AudioPlayerService audioService, bool isPlaying,
      bool shuffle, LoopMode loop, Color? accent, bool loading) {
    final iconColor = accent == null ? AppColors.charcoal : _onColor(accent);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        MotionPress(
          scale: 0.9,
          child: IconButton(
            icon: AnimatedSwitcher(
              duration: AppMotion.dur(context, AppMotion.micro),
              child: Icon(Icons.shuffle,
                  key: ValueKey(shuffle),
                  color: shuffle ? AppColors.ink : AppColors.mute,
                  size: 21),
            ),
            onPressed: audioService.toggleShuffle,
          ),
        ),
        MotionPress(
          scale: 0.9,
          child: IconButton(
            key: const ValueKey('player_prev'),
            icon:
                Icon(Icons.skip_previous, size: 34, color: AppColors.ink),
            onPressed: () => _skip(audioService.playPrevious),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent ?? AppColors.action,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: MotionPress(
            scale: 0.9,
            child: SizedBox(
              width: 60,
              height: 60,
              child: IconButton(
                icon: AnimatedSwitcher(
                  duration: AppMotion.dur(context, AppMotion.micro),
                  switchInCurve: AppMotion.curve,
                  child: loading
                      // Resume/pause is answered by a load, not instantly:
                      // a spinner is the honest state, and the service would
                      // ignore a second press anyway.
                      ? SizedBox(
                          key: const ValueKey('player_loading'),
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: iconColor),
                        )
                      : PlayPauseIcon(
                          key: const ValueKey('player_play_pause'),
                          playing: isPlaying,
                          size: 30,
                          color: iconColor,
                        ),
                ),
                onPressed: loading
                    ? null
                    : () {
                        if (isPlaying) {
                          audioService.pause();
                        } else {
                          audioService.resume();
                        }
                      },
              ),
            ),
          ),
        ),
        MotionPress(
          scale: 0.9,
          child: IconButton(
            key: const ValueKey('player_next'),
            icon: Icon(Icons.skip_next, size: 34, color: AppColors.ink),
            onPressed: () => _skip(() => audioService.playNext(0, true)),
          ),
        ),
        MotionPress(
          scale: 0.9,
          child: IconButton(
            icon: AnimatedSwitcher(
              duration: AppMotion.dur(context, AppMotion.micro),
              child: Icon(
                loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                key: ValueKey(loop == LoopMode.one),
                color: loop == LoopMode.one ? AppColors.ink : AppColors.mute,
                size: 21,
              ),
            ),
            onPressed: audioService.toggleRepeat,
          ),
        ),
      ],
    );
  }

  /// Replaces the two outlined pills. Borders at the bottom of a player are
  /// what made it read as a settings screen.
  Widget _actionRow(Song song, AudioPlayerService audioService) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _action(
          Icons.lyrics_outlined,
          'Lyrics',
          key: const ValueKey('player_lyrics'),
          onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => LyricsSheet(song: song, audio: audioService),
            );
          },
        ),
        _action(
          Icons.queue_music,
          'Next up',
          onTap: () => showWhatsNextSheet(context, audioService),
        ),
        _action(
          Icons.download_outlined,
          'Download',
          onTap: () => downloadSongFlow(context, song),
        ),
      ],
    );
  }

  Widget _action(IconData icon, String label,
      {Key? key, required VoidCallback onTap}) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: AppColors.inkSoft),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 10, letterSpacing: 0.3, color: AppColors.mute)),
          ],
        ),
      ),
    );
  }
}

/// Placeholder for the up-next peek while the next tracks are being resolved.
/// Same geometry as a real row, so nothing jumps when the songs land.
class _UpNextSkeleton extends StatefulWidget {
  const _UpNextSkeleton();

  @override
  State<_UpNextSkeleton> createState() => _UpNextSkeletonState();
}

class _UpNextSkeletonState extends State<_UpNextSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A pulsing placeholder is motion too: hold it still under reduce motion.
    if (AppMotion.reduced(context)) {
      if (_pulse.isAnimating) _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _bar(double? width, double height) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.ink.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_pulse),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'UP NEXT',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
              color: AppColors.mute,
            ),
          ),
          const SizedBox(height: 2),
          for (var i = 0; i < 2; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.mist,
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(double.infinity, 11),
                        const SizedBox(height: 6),
                        _bar(96, 9),
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
}

/// Slider + time labels isolated: only this row rebuilds per second.
class _PlayerSlider extends StatefulWidget {
  const _PlayerSlider({this.accent});

  /// Artwork colour when the option is on; null keeps the app palette.
  final Color? accent;

  @override
  State<_PlayerSlider> createState() => _PlayerSliderState();
}

class _PlayerSliderState extends State<_PlayerSlider> {
  double? _dragValue;
  String? _dragSongId;

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final posSec =
        context.select<AudioPlayerService, int>((s) => s.position.inSeconds);
    final durSec =
        context.select<AudioPlayerService, int>((s) => s.duration.inSeconds);
    final songId =
        context.select<AudioPlayerService, String?>((s) => s.currentSong?.id);
    if (songId != _dragSongId) {
      // A track change must not carry an unfinished drag onto the new song.
      _dragSongId = songId;
      _dragValue = null;
    }
    final audio = context.read<AudioPlayerService>();
    final max = durSec > 0 ? durSec.toDouble() : 1.0;
    final value = (_dragValue ?? posSec.toDouble()).clamp(0.0, max);
    final shownSec = _dragValue?.round() ?? posSec;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: widget.accent ?? AppColors.ink,
            inactiveTrackColor: AppColors.line,
            thumbColor: widget.accent ?? AppColors.ink,
          ),
          child: Slider(
            value: value,
            max: max,
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) {
              audio.seek(Duration(seconds: v.toInt()));
              setState(() => _dragValue = null);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // The clock follows the thumb while dragging, not the stream.
              Text(_fmt(Duration(seconds: shownSec)),
                  style:
                      TextStyle(fontSize: 11, color: AppColors.inkSoft)),
              Text(_fmt(durSec > 0 ? Duration(seconds: durSec) : Duration.zero),
                  style:
                      TextStyle(fontSize: 11, color: AppColors.inkSoft)),
            ],
          ),
        ),
      ],
    );
  }
}
