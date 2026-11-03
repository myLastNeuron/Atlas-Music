import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/song.dart';
import '../services/artwork_color.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/user_prefs.dart';
import '../services/theme_settings.dart';
import '../services/video_handoff.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/lyrics_sheet.dart';
import '../widgets/play_next_badge.dart';
import '../widgets/song_actions.dart';
import '../widgets/video_stats_bar.dart';
import '../widgets/video_surface.dart';
import '../widgets/whats_next_sheet.dart';
import 'artist_screen.dart';

class PlayerScreen extends StatefulWidget {
  static const routeName = '/player';

  /// Players currently mounted. The mini player lives on routes that stay
  /// below the player, so it cannot tell from its own route name whether a
  /// player is already open — this is the guard that stops a second one from
  /// stacking (and playing a second video).
  static int openCount = 0;

  static bool get isOpen => openCount > 0;

  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with SingleTickerProviderStateMixin {
  final StorageService _storageService = StorageService();
  bool _isLiked = false;
  String? _likedForId;

  /// Double-tap burst generation; 0 hides the thumbs-up overlay.
  int _likeBurst = 0;
  bool _videoMode = false;

  /// The video controller while video mode is open (null otherwise). Transport
  /// and slider read it so they drive the video instead of the paused audio.
  final ValueNotifier<VideoPlayerController?> _videoController =
      ValueNotifier(null);
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
    PlayerScreen.openCount++;
    final audio = context.read<AudioPlayerService>();
    _audio = audio;
    // The full player owns the video while it is open; abandon an in-flight
    // mini auto-load so the two never resolve the same song at once.
    MiniVideo.instance.playerOpen = true;
    // Decided before the first frame, never a frame or two into the open:
    // switching the surface mid-flight replaces the destination Hero, and a
    // replaced Hero fades the flying frame out into a ghost over the page. A
    // live video (the mini player was showing it) means Video, whatever the
    // stored choice says.
    _videoMode =
        videoHandoff.isLiveFor(audio.currentSong?.id) || UserPrefs.videoMode;
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
    if (PlayerScreen.openCount > 0) PlayerScreen.openCount--;
    _audio?.removeListener(_audioListener!);
    _storageService.removeListener(_onStorageChanged);
    // The mini player may load the current song's video again the next time a
    // track starts while this page is closed.
    MiniVideo.instance.playerOpen = false;
    // Not disposed: a surface may clear it one frame after the page is gone
    // (a deferred write to a disposed notifier would throw). It dies with this
    // state object anyway.
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

  /// Song/Video is a saved choice, so it also survives a track change: the
  /// surface is keyed by song id, so the next song opens its own video.
  void _setVideoMode(bool on) {
    if (on == _videoMode) return;
    setState(() {
      _videoMode = on;
    });
    UserPrefs().setVideoMode(on);
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

  /// Double-tap on the cover: always ends liked (never unlikes), then pops
  /// a thumbs-up. Skips the burst under reduce motion; the like still lands.
  void _doubleTapLike() {
    if (!_isLiked) unawaited(_toggleLike());
    HapticFeedback.lightImpact();
    if (AppMotion.reduced(context)) return;
    setState(() => _likeBurst++);
    final id = _likeBurst;
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && _likeBurst == id) setState(() => _likeBurst = 0);
    });
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
            icon:
                Icon(Icons.keyboard_arrow_down, size: 30, color: AppColors.ink),
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
                      style: TextStyle(color: AppColors.mute, fontSize: 12),
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
                  Center(
                    child: _ModeToggle(
                      video: _videoMode,
                      onChanged: _setVideoMode,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final side = box.maxWidth < box.maxHeight
                            ? box.maxWidth
                            : box.maxHeight;
                        return Center(
                          // No HeroMode gate: in Video mode the Hero is kept
                          // even before a controller exists, so opening or
                          // closing mid-load still flies — the shuttle carries
                          // VideoSurface's loading screen instead of a cover.
                          child: _videoMode
                              // The Hero is inside the surface: it must not
                              // wrap an owning widget, or the flight would
                              // recreate it and re-park the video
                              // mid-transition.
                              ? VideoSurface(
                                  key: ValueKey('video_${song.id}'),
                                  song: song,
                                  size: side,
                                  // The page keeps Video as the saved mode: a
                                  // close parks the video instead of handing
                                  // playback back to the audio.
                                  keepPlayingOnDetach: () => _videoMode,
                                  controller: _videoController,
                                )
                              : _cover(song, artPath, side),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  _titleBlock(song, canOpenArtist),
                  const SizedBox(height: 10),
                  // The video may be a different music video: these stats
                  // belong to the song's own art-track id.
                  if (!_videoMode)
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
                  _PlayerSlider(
                    accent: accent,
                    videoMode: _videoMode,
                    video: _videoController,
                  ),
                  const SizedBox(height: 4),
                  _transport(audioService, isPlaying, shuffle, loop, accent,
                      isLoading),
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
  static Color _onColor(Color color) =>
      color.computeLuminance() > 0.55 ? const Color(0xFF13131A) : Colors.white;

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
          child: Stack(
            alignment: Alignment.center,
            children: [
              GestureDetector(
                // Double-tap likes without stealing single taps: no onTap
                // here, so transport, slider and video gestures keep theirs.
                onDoubleTap: _doubleTapLike,
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
                          filePath: artPath, songId: song.id, animation: anim),
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
              // One-shot thumbs-up pop; dropped when its run ends, so no
              // controller to own or dispose.
              if (_likeBurst > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: _LikeBurst(key: ValueKey(_likeBurst)),
                  ),
                ),
            ],
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
                      style: TextStyle(fontSize: 14, color: AppColors.inkSoft),
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
                            style:
                                TextStyle(fontSize: 11, color: AppColors.mute)),
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
            icon: Icon(Icons.skip_previous, size: 34, color: AppColors.ink),
            onPressed: () => _skip(audioService.playPrevious),
          ),
        ),
        if (_videoMode)
          // Video mode: the button toggles the video once it is on screen.
          // Until then (resolving, initializing, failed) the audio is still
          // the playback, so the same button drives it — otherwise the song
          // keeps playing with no way to pause or seek it.
          ValueListenableBuilder<VideoPlayerController?>(
            valueListenable: _videoController,
            builder: (context, video, _) => video == null
                ? _playButton(
                    playing: isPlaying,
                    loading: loading,
                    iconColor: iconColor,
                    accent: accent,
                    onPressed: loading
                        ? null
                        : () {
                            if (isPlaying) {
                              audioService.pause();
                            } else {
                              audioService.resume();
                            }
                          },
                  )
                : ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: video,
                    builder: (context, value, _) => _playButton(
                      playing: value.isPlaying,
                      loading: false,
                      iconColor: iconColor,
                      accent: accent,
                      // A disposed controller can throw from an in-flight tap;
                      // the page must not surface an unhandled future for it.
                      onPressed: () =>
                          (value.isPlaying ? video.pause() : video.play())
                              .catchError((_) {}),
                    ),
                  ),
          )
        else
          _playButton(
            playing: isPlaying,
            loading: loading,
            iconColor: iconColor,
            accent: accent,
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

  /// The heavy centre button, shared by Song (audio) and Video (video).
  Widget _playButton({
    required bool playing,
    required bool loading,
    required Color iconColor,
    required Color? accent,
    required VoidCallback? onPressed,
  }) {
    return Container(
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
                      playing: playing,
                      size: 30,
                      color: iconColor,
                    ),
            ),
            onPressed: onPressed,
          ),
        ),
      ),
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

/// Thumbs-up pop for a double-tap like. One TweenAnimationBuilder run: it
/// springs in over the first third, holds, then dissolves. No controller to
/// own or dispose; the parent drops it when the run ends.
class _LikeBurst extends StatelessWidget {
  const _LikeBurst({super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 800),
      builder: (context, t, _) {
        final pop = Curves.easeOutBack.transform((t / 0.35).clamp(0.0, 1.0));
        final fade = t < 0.12
            ? t / 0.12
            : 1.0 -
                Curves.easeIn.transform(((t - 0.55) / 0.45).clamp(0.0, 1.0));
        return Center(
          // Positioned.fill's tight constraints would otherwise stretch the
          // 88px pill over the whole cover; Center loosens them so the burst
          // stays a small badge.
          child: Opacity(
            opacity: fade.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.5 + 0.5 * pop,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Dark scrim + white glyph reads on any artwork; the plain
                  // action fill vanished on bright covers like this one.
                  color: Colors.black.withValues(alpha: 0.55),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.9)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child:
                    const Icon(Icons.thumb_up, size: 40, color: Colors.white),
              ),
            ),
          ),
        );
      },
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

/// Two-option Song/Video pill above the cover: the only entry point to video.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.video, required this.onChanged});

  final bool video;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // Each half sets its own target: deriving it from `selected` inverted the
    // Song half, so tapping Song while in Video re-selected Video.
    Widget half(String label, bool selected, bool value, Key key) =>
        MotionPress(
          scale: 0.94,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(14),
            onTap: selected ? null : () => onChanged(value),
            child: AnimatedContainer(
              duration: AppMotion.dur(context, AppMotion.micro),
              curve: AppMotion.curve,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? AppColors.action : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.4,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.charcoal : AppColors.mute,
                ),
              ),
            ),
          ),
        );

    return Container(
      height: 32,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          half('Song', !video, false, const ValueKey('player_mode_song')),
          half('Video', video, true, const ValueKey('player_mode_video')),
        ],
      ),
    );
  }
}

/// Slider + time labels isolated: only this row rebuilds per second.
class _PlayerSlider extends StatefulWidget {
  const _PlayerSlider({
    this.accent,
    this.videoMode = false,
    this.video,
  });

  /// Artwork colour when the option is on; null keeps the app palette.
  final Color? accent;

  /// Drives the video position/duration instead of the audio's.
  final bool videoMode;

  /// Live video controller while [videoMode] is open; null until it loads.
  final ValueNotifier<VideoPlayerController?>? video;

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
  void didUpdateWidget(_PlayerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The two players are separate clocks; an unfinished drag cannot carry
    // across a mode switch.
    if (oldWidget.videoMode != widget.videoMode) _dragValue = null;
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    if (widget.videoMode && video != null) {
      return ValueListenableBuilder<VideoPlayerController?>(
        valueListenable: video,
        builder: (context, c, _) {
          // No controller yet: the audio is the playback (see the transport).
          if (c == null) return _audioSlider(context);
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: c,
            builder: (context, value, _) => _slider(
              value.position.inSeconds,
              value.duration.inSeconds,
              (at) => c.seekTo(at).catchError((_) {}),
            ),
          );
        },
      );
    }
    return _audioSlider(context);
  }

  Widget _audioSlider(BuildContext context) {
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
    return _slider(posSec, durSec, audio.seek);
  }

  /// Shared row; [seek] null means no player is ready yet (slider disabled).
  Widget _slider(
      int posSec, int durSec, Future<void> Function(Duration)? seek) {
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
            onChanged:
                seek == null ? null : (v) => setState(() => _dragValue = v),
            onChangeEnd: seek == null
                ? null
                : (v) {
                    seek(Duration(seconds: v.toInt()));
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
                  style: TextStyle(fontSize: 11, color: AppColors.inkSoft)),
              Text(_fmt(durSec > 0 ? Duration(seconds: durSec) : Duration.zero),
                  style: TextStyle(fontSize: 11, color: AppColors.inkSoft)),
            ],
          ),
        ),
      ],
    );
  }
}
