import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/video_handoff.dart';
import '../theme/app_theme.dart';
import 'app_transitions.dart';
import 'artwork.dart';
import '../screens/player_screen.dart';
import 'liquid_background.dart';
import 'song_actions.dart';

/// Floating glass mini player. Thumb+text navigate; transport buttons sit
/// strictly outside the nav InkWell so skip taps never push routes. The bar
/// follows the app's transparency setting.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  /// The track whose full-size cover is already decoded. The flight inside the
  /// player uses a ~936 px bitmap, so decoding it after the tap lands mid-
  /// flight and the first frames paint the fallback card: warm it when the
  /// track changes instead. Guarded here because the bar rebuilds on every
  /// transport change.
  String? _warmedCover;

  void _warmCover(Song song, String? artPath) {
    final key = '${song.id}\u0000${artPath ?? ''}';
    if (key == _warmedCover) return;
    _warmedCover = key;
    unawaited(precacheImage(
      playerCoverProvider(context, song.thumbnailUrl, filePath: artPath),
      context,
      onError: (_, __) {},
    ));
  }

  void _openPlayer(
      BuildContext context, String heroTag, Song song, String? artPath) {
    // A player is already open (an artist page keeps a mini bar above it):
    // go back to it instead of stacking a second page with a second video.
    if (PlayerScreen.isOpen) {
      // Never pop past the first route: the predicate can only miss while the
      // player is mid-close, and popUntil would then pop the home route too,
      // leaving an empty (black) navigator.
      Navigator.of(context).popUntil(isPlayerRouteOrFirst);
      return;
    }
    // The player's close animation is still running, and a popping route
    // ignores pointers, so this bar received the tap. Let the close finish;
    // pushing now would stack a second player under the dying one.
    if (PlayerScreen.isClosing) return;
    // The player's cover shares this bar's per-route Hero tag, so only the bar
    // that was tapped flies it.
    playerHeroTag = heroTag;
    // Where this bar is on screen right now: the player's transition collapses
    // into exactly this rect on the way back, so the card lands on the bar.
    final box = context.findRenderObject();
    playerCardFrom = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    // Warm the exact bitmap the flight and the player's cover use: decoded
    // before the route builds, the shuttle's first frame is the artwork.
    unawaited(precacheImage(
      playerCoverProvider(context, song.thumbnailUrl, filePath: artPath),
      context,
      onError: (_, __) {},
    ));
    pushAppPage(
      context,
      const PlayerScreen(),
      routeName: PlayerScreen.routeName,
      slideUp: true,
    );
  }

  Future<void> _skip(BuildContext context, AudioPlayerService audio,
      Future<bool> Function() action) async {
    final ok = await action();
    if (!ok && context.mounted) {
      final reason = audio.lastFailure;
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

  Widget _playPause({
    required bool playing,
    required bool loading,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: const ValueKey('mini_play_pause'),
      visualDensity: VisualDensity.compact,
      icon: loading
          ? SizedBox(
              width: 26,
              height: 26,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                    strokeWidth: 2.2, color: AppColors.charcoal),
              ),
            )
          : PlayPauseIcon(
              playing: playing, size: 26, color: AppColors.charcoal),
      onPressed: loading ? null : onPressed,
    );
  }

  Widget _glassBar(Widget child) {
    // The card's opaque paper covers this bar from 30% of the flight in both
    // directions; below that it fades and the bar is visible. Skip the frost
    // only in the covered window, so the bar is never seen changing.
    return ValueListenableBuilder<bool>(
      valueListenable: playerRouteOpen,
      builder: (context, covered, _) {
        return SizedBox(
          height: 70,
          child: GlassSurface(
            borderRadius: BorderRadius.circular(22),
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            shadow: false,
            // Frosted: album art and the list scroll underneath it.
            blur: !covered,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Shell subscribes transport only. Position tick lives in
    // [_MiniProgress] so blur/shadow/artwork never rebuild per second.
    final Song? song =
        context.select<AudioPlayerService, Song?>((s) => s.currentSong);
    final bool playing =
        context.select<AudioPlayerService, bool>((s) => s.isPlaying);
    final bool isLoading =
        context.select<AudioPlayerService, bool>((s) => s.isLoading);
    final audio = context.read<AudioPlayerService>();
    // Offline notice: queue paused because the track is neither
    // downloaded nor streamable. Persistent until connectivity returns
    // or playback resumes, so a silent idle is never unexplained.
    final bool pausedOffline =
        context.select<AudioPlayerService, bool>((s) => s.pausedForOffline);
    // Degraded badge: some queued tracks need internet; cached ones keep
    // playing and known-uncached ones are skipped without re-checking.
    final bool degraded =
        context.select<AudioPlayerService, bool>((s) => s.degradedOffline);
    // Downloaded high-res cover (the notification's copy), same one the full
    // player shows, so the cover flight can land on it instead of the thumb.
    final String? artPath = context.select<AudioPlayerService, String?>(
        (s) => s.highResArtPathFor(s.currentSong));
    // Keep the bar mounted while a first track loads (song still null)
    // so it never vanishes on cold start / auto-advance gaps.
    if (song == null) {
      if (!isLoading) {
        if (!pausedOffline) return const SizedBox.shrink();
        return _glassBar(Center(
          child: Text('Track unavailable — no internet and not downloaded',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkSoft, fontSize: 12)),
        ));
      }
      return _glassBar(Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child:
              CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink),
        ),
      ));
    }

    final loading = isLoading && !playing;
    // The cover the flight needs, decoded before the tap instead of during it.
    _warmCover(song, artPath);
    // Route-scoped Hero tag: only a bar on the route this player is pushed from
    // can be the flight source. One global tag let any other MiniPlayer in the
    // stack (an artist page) grab the full-size cover.
    final heroTag = 'player_cover_${identityHashCode(ModalRoute.of(context))}';

    if (pausedOffline) {
      // Queue paused for offline: swap the transport row for the reason.
      return _glassBar(Row(
        children: [
          Icon(Icons.wifi_off, size: 22, color: AppColors.inkSoft),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
                'Track unavailable — no internet and not '
                'downloaded. Waiting for internet…',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.inkSoft, fontSize: 12)),
          ),
        ],
      ));
    }

    return _glassBar(Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('mini_nav_area'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openPlayer(context, heroTag, song, artPath),
                    child: Row(
                      children: [
                        Hero(
                          tag: heroTag,
                          // Linear: the player's curve is applied by the rect
                          // tween instead, so the cover and the card around it
                          // move as one.
                          curve: Curves.linear,
                          // Closing, this bar is the flight's destination, so
                          // the cover settles back into it on the close curve.
                          // The flight rect's own clock still runs forward on a
                          // close (Flutter reverses the route for the tween),
                          // so the curve is mirrored to keep the cover on the
                          // same motion as the card collapsing around it.
                          createRectTween: (b, e) => PlayerFlightRectTween(
                            begin: b,
                            end: e,
                            curve: AppMotion.playerCloseCurve.flipped,
                          ),
                          // The square morphs thumb -> big cover (or the live
                          // video, in Video mode) on open and back on close;
                          // nothing else moves.
                          flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                              CoverFlightShuttle(song.thumbnailUrl,
                                  filePath: artPath,
                                  songId: song.id,
                                  animation: anim,
                                  curve: playerFlightCurve(dir)),
                          // Hidden, but still mounted so it is decoded when the
                          // shuttle lands. Closing reveals this bar while the
                          // cover is still flying, so a thumb left painting
                          // here would show as a second artwork beside it.
                          placeholderBuilder: (context, size, child) =>
                              SizedBox(
                            width: size.width,
                            height: size.height,
                            child: Offstage(child: child),
                          ),
                          child: AnimatedSwitcher(
                            duration: AppMotion.dur(context, AppMotion.micro),
                            switchInCurve: AppMotion.curve,
                            switchOutCurve: AppMotion.curve,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                  scale: animation, child: child),
                            ),
                            child: ListenableBuilder(
                              // Video mode: the square is the live video, so the
                              // flight and the mini bar show what is really
                              // playing.
                              listenable: videoHandoff,
                              builder: (context, _) {
                                final video = videoHandoff.isLiveFor(song.id)
                                    ? videoHandoff.controller
                                    : null;
                                if (video != null) {
                                  return ClipRRect(
                                    key: ValueKey('mini_video_${song.id}'),
                                    borderRadius: BorderRadius.circular(10),
                                    child: SizedBox(
                                      width: kMiniArtworkSize,
                                      height: kMiniArtworkSize,
                                      child: VideoFrame(controller: video),
                                    ),
                                  );
                                }
                                // Loading during a transition: land on the
                                // same spinner the flight is carrying, not on
                                // artwork the full player has already left.
                                if (videoHandoff.isLoadingFor(song.id)) {
                                  return ClipRRect(
                                    key: ValueKey(
                                        'mini_video_loading_${song.id}'),
                                    borderRadius: BorderRadius.circular(10),
                                    child: const SizedBox(
                                      width: kMiniArtworkSize,
                                      height: kMiniArtworkSize,
                                      child: VideoLoadingFrame(),
                                    ),
                                  );
                                }
                                return Artwork(
                                  song.thumbnailUrl,
                                  key: ValueKey(song.id),
                                  size: kMiniArtworkSize,
                                  radius: 10,
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: AppColors.ink)),
                              songArtistLine(song),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (degraded)
                Tooltip(
                  message: 'Offline mode: some queued tracks need '
                      'internet and will be skipped',
                  child: Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Icon(Icons.wifi_off,
                        size: 18, color: AppColors.inkSoft),
                  ),
                ),
              MotionPress(
                scale: 0.9,
                child: IconButton(
                  key: const ValueKey('mini_prev'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.skip_previous,
                      size: 24, color: AppColors.inkSoft),
                  onPressed: loading
                      ? null
                      : () => _skip(context, audio, audio.playPrevious),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.action,
                ),
                child: MotionPress(
                  scale: 0.9,
                  child: ListenableBuilder(
                    listenable: videoHandoff,
                    builder: (context, _) {
                      // A video parked by the closed player is the playback:
                      // the button toggles it, not the paused audio.
                      final video = videoHandoff.controller;
                      if (video != null && videoHandoff.isLiveFor(song.id)) {
                        return ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: video,
                          builder: (context, value, _) => _playPause(
                            // Buffering is a load, not a pause: the audio
                            // path already shows a spinner here, and a tap
                            // that does nothing looked broken.
                            loading: value.isBuffering && value.isPlaying,
                            playing: value.isPlaying,
                            // A disposed controller can throw from an
                            // in-flight tap.
                            onPressed: () {
                              // Pressing play outranks a finished sleep timer.
                              if (!value.isPlaying) audio.clearSleepStop();
                              unawaited(
                                  (value.isPlaying ? video.pause() : video.play())
                                      .catchError((_) {}));
                            },
                          ),
                        );
                      }
                      return _playPause(
                        // One loading language for the whole bar: whatever is
                        // pending (the song's own load, or a video resolving
                        // in Video mode) spins in this button.
                        loading: !playing &&
                            (isLoading || videoHandoff.isLoadingFor(song.id)),
                        playing: playing,
                        onPressed: () =>
                            playing ? audio.pause() : audio.resume(),
                      );
                    },
                  ),
                ),
              ),
              MotionPress(
                scale: 0.9,
                child: IconButton(
                  key: const ValueKey('mini_skip_next'),
                  visualDensity: VisualDensity.compact,
                  icon:
                      Icon(Icons.skip_next, size: 24, color: AppColors.inkSoft),
                  onPressed: loading
                      ? null
                      : () =>
                          _skip(context, audio, () => audio.playNext(0, true)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        _MiniProgress(song: song),
      ],
    ));
  }
}

/// Progress tick isolated: only this 2px bar rebuilds per second.
class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.song});

  final Song song;

  static AlwaysStoppedAnimation<Color> get _fill =>
      AlwaysStoppedAnimation<Color>(AppColors.ink);

  Widget _bar(double pos, double dur) {
    final max = dur > 0 ? dur : 1.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: (pos / max).clamp(0.0, 1.0),
        minHeight: 2,
        backgroundColor: AppColors.ink.withValues(alpha: 0.14),
        valueColor: _fill,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final audio = context.read<AudioPlayerService>();
    // Listens to the handoff so the bar swaps clocks the moment a video is
    // parked by the closed player, or handed back to the audio.
    return ListenableBuilder(
      listenable: videoHandoff,
      builder: (context, _) {
        final video = videoHandoff.controller;
        if (video != null && videoHandoff.isLiveFor(song.id)) {
          // The parked video is the clock: map its position onto the song's, so
          // the bar keeps meaning what the player screen showed.
          final end =
              audio.duration > Duration.zero ? audio.duration : song.duration;
          return ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: video,
            builder: (context, value, _) => _bar(
              mappedSongPosition(
                songStart: videoHandoff.songStart,
                videoStart: videoHandoff.videoStart,
                videoPosition: value.position,
                songDuration: end,
              ).inSeconds.toDouble(),
              end.inSeconds.toDouble(),
            ),
          );
        }
        final int posSec = context
            .select<AudioPlayerService, int>((s) => s.position.inSeconds);
        final int durSec = context
            .select<AudioPlayerService, int>((s) => s.duration.inSeconds);
        return _bar(posSec.toDouble(), durSec.toDouble());
      },
    );
  }
}
