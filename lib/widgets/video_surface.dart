import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import '../services/audio_service.dart';
import '../services/video_handoff.dart';
import '../theme/app_theme.dart';
import 'artwork.dart';

/// The current track's video, rendered in the same square the artwork uses.
class VideoSurface extends StatefulWidget {
  final Song song;

  /// Square side, identical to the artwork box the player computed.
  final double size;

  /// The live controller, so the page's transport and slider drive the video.
  /// Set once initialized; cleared before the controller is disposed.
  final ValueNotifier<VideoPlayerController?> controller;

  /// Asked at dispose: is the video still the mode the user wants? True on a
  /// close to the mini player (the video keeps playing, and keeps its frame on
  /// the mini bar), false when the page itself dropped back to Song.
  final bool Function() keepPlayingOnDetach;

  const VideoSurface({
    super.key,
    required this.song,
    required this.size,
    required this.controller,
    required this.keepPlayingOnDetach,
  });

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

enum _VideoPhase { loading, playing, failed }

class _VideoSurfaceState extends State<VideoSurface>
    with WidgetsBindingObserver {
  AudioPlayerService? _audio;
  VideoPlayerController? _controller;
  _VideoPhase _phase = _VideoPhase.loading;
  String _message = '';

  /// Audio was playing this track when the video opened; close resumes it.
  bool _resumeAudio = false;

  /// Our pause of the audio actually finished, so a failure has something to
  /// undo. Resolution now happens first, so a failure may precede the pause.
  bool _pausedAudio = false;

  /// Our pause of the audio finished, so a later `isPlaying` is a takeover.
  bool _audioSettled = false;

  /// The video actually started, so its position is worth seeking audio to.
  bool _played = false;

  /// The end of the video already asked the queue to advance.
  bool _advanced = false;

  /// Song position when the video took over, and the video position it started
  /// from. The video opens at the song's position, so the switch never resets
  /// the timeline; their difference maps watched time back onto the song.
  Duration _audioStart = Duration.zero;
  Duration _videoStart = Duration.zero;

  /// App went to the background (only `paused`, not `inactive`).
  bool _backgrounded = false;

  /// Audio owns playback again: never seek or resume over it on close.
  bool _audioTookOver = false;

  /// [VideoSurface._handOverToNextTrack] was already called.
  bool _exited = false;

  /// The widget is being disposed; every post-await continuation bails.
  bool _closed = false;

  /// Immersive chrome is on and still needs restoring (exactly once).
  bool _chromeHeld = false;

  /// The fullscreen route is on top; an audio takeover must pop it before the
  /// page swaps to Song, or it would keep rendering a disposed controller.
  bool _fullscreenOpen = false;

  @override
  void initState() {
    super.initState();
    final audio = context.read<AudioPlayerService>();
    _audio = audio;
    audio.addListener(_onAudio);
    WidgetsBinding.instance.addObserver(this);
    // The player was closed on this video and is opening again: carry on with
    // the same controller instead of resolving and restarting it.
    final parked = videoHandoff.take(widget.song.id);
    if (parked != null) {
      _adopt(parked.controller, parked.songStart, parked.videoStart);
      return;
    }
    // Deferred: the failure path calls setState and must not run mid-initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  /// Takes a parked controller back from [videoHandoff] as if it had just
  /// started: same position mapping, same ownership of playback. Its play
  /// state is left exactly as the mini player left it.
  void _adopt(VideoPlayerController c, Duration songStart, Duration videoStart) {
    _controller = c;
    _audioStart = songStart;
    _videoStart = videoStart;
    _played = true;
    // Our pause owns the audio: a later resume is a takeover, not a request.
    _audioSettled = true;
    _phase = _VideoPhase.playing;
    // Deferred: the page's slider listens to that notifier, and touching it
    // from initState (during a build) would mark it dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller == c) widget.controller.value = c;
    });
    c.addListener(_onVideoEnd);
  }

  @override
  void dispose() {
    _closed = true;
    _audio?.removeListener(_onAudio);
    WidgetsBinding.instance.removeObserver(this);
    final c = _controller;
    _controller = null;
    // Never touch [VideoSurface.controller] here: the widget tree is locked
    // during unmount, and notifying it throws out of the middle of dispose —
    // which left the video neither parked nor released. The page stops reading
    // that notifier the moment this surface is gone (Song view, or the page
    // itself is dying), so a stale value is harmless.
    //
    // Closing the player keeps the video: parking it here is what stops the
    // switch back to the audio stream, and it is what puts the live frame in
    // the mini player's square. A Song tap, a track change or an app close all
    // fall through to the normal hand-back.
    final park = c != null &&
        _played &&
        widget.keepPlayingOnDetach() &&
        _audio?.currentSong?.id == widget.song.id;
    if (park) {
      final at = c.value.position;
      videoHandoff.park(
        controller: c,
        songId: widget.song.id,
        songStart: _audioStart,
        videoStart: _videoStart,
        audio: _audio!,
      );
      // Playback stays with the video, but the paused audio clock is moved to
      // the same place: the saved session then resumes where the video is.
      unawaited(_restoreAudio(at, resume: false));
    } else {
      final at = c?.value.position ?? Duration.zero;
      // Paused stays paused: only playback that was actually running carries
      // back to the audio on the way out.
      final wasPlaying = c?.value.isPlaying ?? false;
      // Released here, not via _dropController: that one also writes the page's
      // notifier, which is not safe from dispose. Skipping the release left the
      // handoff advertising this controller, so the mini player kept painting
      // the dead video's last frame instead of the song's artwork.
      if (c != null) {
        videoHandoff.release(c);
        unawaited(c.dispose());
      }
      unawaited(_restoreAudio(at, resume: wasPlaying));
    }
    _restoreChrome();
    super.dispose();
  }

  Future<void> _open({bool refresh = false}) async {
    if (_closed) return;
    final audio = _audio!;
    final mine = audio.currentSong?.id == widget.song.id;
    if (audio.isLoading) {
      _fail('Track is still loading');
      return;
    }

    try {
      final online = await audio.hasInternet;
      if (_closed) return;
      if (!online) {
        _fail('Video needs internet');
        return;
      }

      // Resolve before pausing: the audio keeps playing while we look.
      if (mounted) setState(() => _message = 'Finding video…');
      final source = await audio
          .videoSource(widget.song, refresh: refresh)
          .timeout(const Duration(seconds: 20));
      if (_closed) return;
      if (source == null) {
        _fail('No music video for this track');
        return;
      }
      // The resolve can take seconds: the user may have paused or resumed the
      // audio meanwhile, so the snapshot from _open's start is stale.
      _resumeAudio = mine && audio.isPlaying;
      // The video opens where the song is, whatever media it is: resetting to
      // 0 made the switch look like it lost the position (and pushed the song
      // to its end on the way back).
      _audioStart = mine ? audio.position : Duration.zero;

      if (_resumeAudio) {
        await audio.pause();
        _pausedAudio = true;
        if (_closed) {
          await audio.resume();
          return;
        }
      }
      // From here the video owns playback: any audio resume is a takeover,
      // even when the audio was already paused on entry.
      _audioSettled = true;

      final c = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        // HLS master playlist; its suffix alone is not always detected.
        formatHint: VideoFormat.hls,
        // ExoPlayer's own default UA was never probed against the CDN.
        httpHeaders: audio.videoHeaders,
      );
      _controller = c;
      await c.initialize().timeout(const Duration(seconds: 15));
      if (_closed) return;
      // A video shorter than the song cannot hold that position: start it at 0
      // and keep the offset, so the mapping still carries the position back.
      final canAlign = _audioStart <= c.value.duration;
      _videoStart = canAlign ? _audioStart : Duration.zero;
      await c.seekTo(_videoStart).timeout(const Duration(seconds: 5));
      if (_closed) return;
      // First frame on screen before play(): the spinner stops right here.
      setState(() {
        _phase = _VideoPhase.playing;
        _message = '';
      });
      widget.controller.value = c;
      // First frame is already on screen: a quick switch back to Song must
      // still map the position even if play() has not resolved yet.
      _played = true;
      // Published so the mini player's square renders the same frames, which is
      // also what the cover flight carries between the two.
      videoHandoff.publish(
        controller: c,
        songId: widget.song.id,
        songStart: _audioStart,
        videoStart: _videoStart,
      );
      // In Video the video is the playback: its end is the song's end, so the
      // queue advances into the next song's video instead of stopping dead.
      c.addListener(_onVideoEnd);
      // Switching modes never changes the play state: a paused song opens its
      // video paused, a playing one keeps playing.
      if (!_backgrounded && _resumeAudio) {
        await c.play().timeout(const Duration(seconds: 5));
        if (_closed) return;
      }
    } on TimeoutException {
      _dropController();
      _fail('Video is taking too long');
    } catch (_) {
      _dropController();
      _fail('Could not play the video');
    }
  }

  /// The video played to its end: hand the queue the advance, so the next
  /// track opens (in Video, because the choice is saved) instead of silence.
  void _onVideoEnd() {
    if (_closed || _exited || !_played || _advanced) return;
    if (!(_controller?.value.isCompleted ?? false)) return;
    _advanced = true;
    unawaited(_audio?.playNext(0, false));
  }

  /// Restarts a failed open from the Retry button.
  void _retry() {
    if (_closed || _phase != _VideoPhase.failed) return;
    setState(() {
      _phase = _VideoPhase.loading;
      _message = 'Finding video…';
      _played = false;
    });
    // Audio may be playing again (a failure resumed it); while we resolve the
    // new attempt it must not count as a takeover.
    _audioSettled = false;
    // A Retry exists because the URL may be dead: skip the cached answer.
    unawaited(_open(refresh: true));
  }

  /// Audio took the track back. Called once, pauses the video, never navigates.
  void _onAudio() {
    if (_exited || _closed) return;
    final audio = _audio;
    if (audio == null) return;
    if (audio.currentSong?.id != widget.song.id) {
      _audioTookOver = true;
      _handOverToNextTrack();
      return;
    }
    // While the video owns the screen, an audio resume is a service retry or
    // a stale platform state, not a user request: pause it again instead of
    // dropping the user out of Video. A real track change exits above, and
    // the Song pill is always one tap away.
    if (_audioSettled && _phase != _VideoPhase.failed && audio.isPlaying) {
      unawaited(audio.pause());
    }
  }

  /// The track changed under this video (skip, or the video finishing). Video
  /// is a saved choice, so the page keeps it and shows the new song's video:
  /// this surface just stops, drops fullscreen and lets itself be replaced.
  void _handOverToNextTrack() {
    if (_exited) return;
    _exited = true;
    final c = _controller;
    if (c != null) unawaited(c.pause());
    if (_fullscreenOpen) {
      // The route owns the screen; _openFullscreen finishes once it has
      // actually popped (and the shared controller is safe to dispose).
      unawaited(Navigator.of(context).maybePop());
    }
  }

  void _dropController() {
    final c = _controller;
    _controller = null;
    if (c != null) videoHandoff.release(c);
    if (c != null) {
      // The page must stop reading this controller. That write is deferred when
      // the tree is locked (this also runs from dispose): marking a listener
      // dirty then throws out of the middle of dispose.
      final notifier = widget.controller;
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance
            .addPostFrameCallback((_) => notifier.value = null);
      } else {
        notifier.value = null;
      }
      unawaited(c.dispose());
    }
  }

  Future<void> _restoreAudio(Duration at, {required bool resume}) async {
    if (_audioTookOver) return;
    final audio = _audio;
    if (audio == null || audio.currentSong?.id != widget.song.id) return;
    // Carry the watched time, not the video's raw clock: a real video shares
    // the song's timeline, a found music video starts at 0 and would otherwise
    // restart the song. Both keep the slider where the user left it.
    if (_played) {
      final end = audio.duration > Duration.zero
          ? audio.duration
          : widget.song.duration;
      await audio.seek(mappedSongPosition(
        songStart: _audioStart,
        videoStart: _videoStart,
        videoPosition: at,
        songDuration: end,
      ));
    }
    // [resume] is the playback state at the moment the page closed: a video
    // the user paused must not start the audio behind their back.
    if (resume) await audio.resume();
  }

  void _fail(String message) {
    if (!mounted) return;
    // Cleared before setState: a failed video never resumes audio twice.
    final resume = _pausedAudio;
    _pausedAudio = false;
    _resumeAudio = false;
    setState(() {
      _phase = _VideoPhase.failed;
      _message = message;
    });
    final audio = _audio;
    if (resume && audio != null) unawaited(audio.resume());
  }

  void _toggle() {
    final c = _controller;
    if (c == null) return;
    // A disposed controller can still surface from an in-flight tap.
    unawaited((c.value.isPlaying ? c.pause() : c.play()).catchError((_) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgrounded = true;
      final c = _controller;
      if (c != null) unawaited(c.pause());
    } else if (state == AppLifecycleState.resumed) {
      // No auto-resume: coming back stays paused until the user taps.
      _backgrounded = false;
    }
  }

  Future<void> _openFullscreen() async {
    final c = _controller;
    if (c == null) return;
    _chromeHeld = true;
    _fullscreenOpen = true;
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    unawaited(SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
    // Same controller: no re-init, no dispose. The page's own dispose and this
    // future both restore chrome; the guard keeps it to one restore.
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => _FullscreenVideo(
          controller: c,
          onToggle: _toggle,
          onChromeRestore: _restoreChrome,
        ),
        transitionsBuilder: (_, __, ___, child) => child,
      ),
    );
    _fullscreenOpen = false;
    _restoreChrome();
  }

  void _restoreChrome() {
    if (!_chromeHeld) return;
    _chromeHeld = false;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      // The Hero lives *inside* this widget on purpose. A Hero swaps its
      // child's wrapper while it flies, which rebuilds the child's element: with
      // the video itself as the hero's child that recreated this state mid-flight
      // (park → adopt → park), and the second park disposed the controller the
      // mini player was still showing. Here only the stateless frame is swapped.
      child: Hero(
        tag: playerHeroTag,
        createRectTween: (begin, end) =>
            PlayerRectTween(begin: begin, end: end),
        flightShuttleBuilder: (ctx, anim, dir, from, to) => CoverFlightShuttle(
          widget.song.thumbnailUrl,
          songId: widget.song.id,
          animation: anim,
        ),
        placeholderBuilder: (context, size, child) => SizedBox(
          width: size.width,
          height: size.height,
          child: Offstage(child: child),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _content(c),
                if (_phase == _VideoPhase.playing && c != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: IconButton(
                        key: const ValueKey('video_fullscreen'),
                        onPressed: _openFullscreen,
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                        color: Colors.white,
                        tooltip: 'Full screen',
                        icon: const Icon(Icons.fullscreen),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(VideoPlayerController? c) => switch (_phase) {
        _VideoPhase.loading => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                ],
              ],
            ),
          ),
        _VideoPhase.failed => Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('video_retry'),
                    onPressed: _retry,
                    child: const Text(
                      'Retry',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        _VideoPhase.playing =>
          c == null ? const SizedBox.shrink() : _playing(c),
      };

  Widget _playing(VideoPlayerController c) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
      child: Center(
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: c,
          builder: (context, value, child) => AspectRatio(
            // Letterbox: never crop or stretch the frame.
            aspectRatio: value.size.isEmpty ? 16 / 9 : value.aspectRatio,
            child: child,
          ),
          child: VideoPlayer(c),
        ),
      ),
    );
  }
}

class _FullscreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onToggle;
  final VoidCallback onChromeRestore;

  const _FullscreenVideo({
    required this.controller,
    required this.onToggle,
    required this.onChromeRestore,
  });

  @override
  State<_FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<_FullscreenVideo> {
  @override
  void dispose() {
    widget.onChromeRestore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: widget.controller,
                builder: (context, value, child) => AspectRatio(
                  aspectRatio: value.size.isEmpty ? 16 / 9 : value.aspectRatio,
                  child: child,
                ),
                child: VideoPlayer(widget.controller),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  key: const ValueKey('video_fullscreen_exit'),
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.fullscreen_exit),
                  color: Colors.white,
                  tooltip: 'Exit full screen',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
