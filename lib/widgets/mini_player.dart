import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import 'app_transitions.dart';
import 'artwork.dart';
import '../screens/player_screen.dart';
import 'liquid_background.dart';
import 'song_actions.dart';

/// Floating glass mini player. Thumb+text navigate; transport buttons sit
/// strictly outside the nav InkWell so skip taps never push routes. The bar
/// follows the app's transparency setting.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  void _openPlayer(BuildContext context) {
    final cur = ModalRoute.of(context)?.settings.name;
    if (cur == PlayerScreen.routeName) return;
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

  Widget _glassBar(Widget child) {
    // Follows the transparency setting like every other glass surface.
    return SizedBox(
      height: 70,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(22),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        strength: 0.05,
        shadow: false,
        child: child,
      ),
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
        return _glassBar(const Center(
          child: Text('Track unavailable — no internet and not downloaded',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.inkSoft, fontSize: 12)),
        ));
      }
      return _glassBar(const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      ));
    }

    final loading = isLoading && !playing;

    if (pausedOffline) {
      // Queue paused for offline: swap the transport row for the reason.
      return _glassBar(const Row(
        children: [
          Icon(Icons.wifi_off, size: 22, color: AppColors.inkSoft),
          SizedBox(width: 10),
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
                    onTap: () => _openPlayer(context),
                    child: Row(
                      children: [
                        Hero(
                          tag: 'player_cover',
                          createRectTween: (begin, end) =>
                              PlayerRectTween(begin: begin, end: end),
                          // The player closing is a sheet slide: both ends keep
                          // their artwork (placeholders) and no shuttle flies,
                          // so nothing floats over the queue. Opening still
                          // morphs the thumb into the big cover.
                          flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                              dir == HeroFlightDirection.pop
                                  ? const SizedBox.shrink()
                                  : CoverFlightShuttle(song.thumbnailUrl,
                                      filePath: artPath, animation: anim),
                          placeholderBuilder: (context, size, child) => child,
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
                            child: Artwork(
                              song.thumbnailUrl,
                              key: ValueKey(song.id),
                              size: kMiniArtworkSize,
                              radius: 10,
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
                                  style: const TextStyle(
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
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                )
              else ...[
                if (degraded)
                  const Tooltip(
                    message: 'Offline mode: some queued tracks need '
                        'internet and will be skipped',
                    child: Padding(
                      padding: EdgeInsets.only(right: 2),
                      child: Icon(Icons.wifi_off,
                          size: 18, color: AppColors.inkSoft),
                    ),
                  ),
                MotionPress(
                  scale: 0.9,
                  child: IconButton(
                    key: const ValueKey('mini_prev'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.skip_previous,
                        size: 24, color: AppColors.inkSoft),
                    onPressed: () => _skip(context, audio, audio.playPrevious),
                  ),
                ),
                Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                  child: MotionPress(
                    scale: 0.9,
                    child: IconButton(
                      key: const ValueKey('mini_play_pause'),
                      visualDensity: VisualDensity.compact,
                      icon: PlayPauseIcon(
                        playing: playing,
                        size: 26,
                        color: AppColors.charcoal,
                      ),
                      onPressed: () {
                        if (playing) {
                          audio.pause();
                        } else {
                          audio.resume();
                        }
                      },
                    ),
                  ),
                ),
                MotionPress(
                  scale: 0.9,
                  child: IconButton(
                    key: const ValueKey('mini_skip_next'),
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.skip_next,
                        size: 24, color: AppColors.inkSoft),
                    onPressed: () =>
                        _skip(context, audio, () => audio.playNext(0, true)),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        const _MiniProgress(),
      ],
    ));
  }
}

/// Progress tick isolated: only this 2px bar rebuilds per second.
class _MiniProgress extends StatelessWidget {
  const _MiniProgress();

  static const _fill = AlwaysStoppedAnimation<Color>(Colors.white);

  @override
  Widget build(BuildContext context) {
    final int posSec =
        context.select<AudioPlayerService, int>((s) => s.position.inSeconds);
    final int durSec =
        context.select<AudioPlayerService, int>((s) => s.duration.inSeconds);
    final max = durSec > 0 ? durSec.toDouble() : 1.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: LinearProgressIndicator(
        value: (posSec.toDouble() / max).clamp(0.0, 1.0),
        minHeight: 2,
        backgroundColor: Colors.white.withValues(alpha: 0.14),
        valueColor: _fill,
      ),
    );
  }
}
