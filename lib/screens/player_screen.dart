import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_transitions.dart';
import '../widgets/artwork.dart';
import '../widgets/liquid_background.dart';
import '../widgets/lyrics_sheet.dart';
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
    final artSize = coverLogicalSize(context);

    return LiquidBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down,
                size: 30, color: AppColors.ink),
            onPressed: () => Navigator.pop(context),
          ),
          // An eyebrow, not a title: the song owns the typographic weight.
          title: const Text(
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
                icon: const Icon(Icons.more_vert, color: AppColors.inkSoft),
                onPressed: _openSongActions,
              ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  // IntrinsicHeight + Spacer: on a short column the transport
                  // settles near the bottom of the viewport instead of leaving
                  // dead space, while a tall column still scrolls rather than
                  // overflowing. One intrinsic pass per layout, not per frame.
                  child: IntrinsicHeight(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!isLoading &&
                              !isPlaying &&
                              (lastFailure != null ||
                                  (hasSong &&
                                      (pausedForOffline || degraded)))) ...[
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
                                style: const TextStyle(
                                    color: AppColors.mute, fontSize: 12),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (song != null) ...[
                            _cover(song, artPath, artSize),
                            const SizedBox(height: 18),
                            _titleBlock(song, canOpenArtist),
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: VideoStatsBar(
                                  videoId: song.videoId ?? song.id),
                            ),
                            if (upcoming.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              _upNextBlock(upcoming),
                            ],
                            const Spacer(),
                            const _PlayerSlider(),
                            const SizedBox(height: 4),
                            _transport(audioService, isPlaying, shuffle, loop),
                            const SizedBox(height: 16),
                            _actionRow(song, audioService),
                          ] else ...[
                            const Spacer(),
                            const Icon(Icons.music_note,
                                size: 88, color: AppColors.mute),
                            const SizedBox(height: 12),
                            const Text('No song playing',
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
            },
          ),
        ),
      ),
    );
  }

  /// Artwork alone, no frame: a soft drop shadow and a glass rim. A panel
  /// around the cover read as a card inside a card, and made the breathing
  /// animation wobble a border instead of the art.
  Widget _cover(Song song, String? artPath, double artSize) {
    final radius = BorderRadius.circular(22);
    return ScaleTransition(
      scale: _breathScale,
      child: RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1,
          child: Hero(
            tag: 'player_cover',
            createRectTween: (begin, end) =>
                PlayerRectTween(begin: begin, end: end),
            // On close the page slides away as one sheet. Flying the cover
            // separately left its slot empty (a black hole) and dragged a
            // thumb-sized copy across the queue rows, which read as ghosting.
            // Keeping the placeholder but skipping the pop flight gives a
            // clean slide; the shared-element morph stays on open.
            flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                dir == HeroFlightDirection.pop
                    ? const SizedBox.shrink()
                    : CoverFlightShuttle(song.thumbnailUrl,
                        filePath: artPath, animation: anim),
            // While the cover is flying in, leave the landing spot empty.
            // Painting the finished cover there under the fading page made
            // the artwork appear to pop into place before the morph had
            // travelled. It stays mounted (Offstage) so it is already
            // decoded when the shuttle lands instead of blinking in.
            // On close the cover must stay put: the page slides away as one
            // sheet, so the placeholder only hides it on open.
            placeholderBuilder: (context, size, child) {
              final closing = ModalRoute.of(context)?.animation?.status ==
                  AnimationStatus.reverse;
              if (closing) return child;
              return SizedBox(
                width: size.width,
                height: size.height,
                child: Offstage(child: child),
              );
            },
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
                  size: artSize,
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
          style: const TextStyle(
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
                              const Text(' · ',
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
                                    style: const TextStyle(
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
                      style: const TextStyle(
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
                  color: _isLiked ? Colors.white : AppColors.mute,
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
  /// tracks that actually follow. Tapping a row plays it; the full list with
  /// reasons and Rethink is behind the "Next up" button.
  Widget _upNextBlock(List<Song> songs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
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
              return at < 0 ? Future.value(false) : audio.playQueued(at);
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
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.ink)),
                        const SizedBox(height: 1),
                        Text(next.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: AppColors.mute)),
                      ],
                    ),
                  ),
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
      bool shuffle, LoopMode loop) {
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
                  color: shuffle ? Colors.white : AppColors.mute,
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
                const Icon(Icons.skip_previous, size: 34, color: AppColors.ink),
            onPressed: () => _skip(audioService.playPrevious),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
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
                icon: PlayPauseIcon(
                  playing: isPlaying,
                  size: 30,
                  color: AppColors.charcoal,
                ),
                onPressed: () {
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
            icon: const Icon(Icons.skip_next, size: 34, color: AppColors.ink),
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
                color: loop == LoopMode.one ? Colors.white : AppColors.mute,
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
                style: const TextStyle(
                    fontSize: 10, letterSpacing: 0.3, color: AppColors.mute)),
          ],
        ),
      ),
    );
  }
}

/// Slider + time labels isolated: only this row rebuilds per second.
class _PlayerSlider extends StatefulWidget {
  const _PlayerSlider();

  @override
  State<_PlayerSlider> createState() => _PlayerSliderState();
}

class _PlayerSliderState extends State<_PlayerSlider> {
  double? _dragValue;

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
    final audio = context.read<AudioPlayerService>();
    final max = durSec > 0 ? durSec.toDouble() : 1.0;
    final value = (_dragValue ?? posSec.toDouble()).clamp(0.0, max);
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Colors.white,
            inactiveTrackColor: AppColors.line,
            thumbColor: Colors.white,
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
              Text(_fmt(Duration(seconds: posSec)),
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.inkSoft)),
              Text(_fmt(durSec > 0 ? Duration(seconds: durSec) : Duration.zero),
                  style:
                      const TextStyle(fontSize: 11, color: AppColors.inkSoft)),
            ],
          ),
        ),
      ],
    );
  }
}
