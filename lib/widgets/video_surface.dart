import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/song.dart';
import '../services/audio_service.dart';

/// The current track's video, rendered in the same square the artwork uses.
class VideoSurface extends StatefulWidget {
  final Song song;

  /// Square side, identical to the artwork box the player computed.
  final double size;

  /// Audio took the track back (track change / external play): the player
  /// switches itself back to the Song view.
  final VoidCallback onExitToSong;

  const VideoSurface({
    super.key,
    required this.song,
    required this.size,
    required this.onExitToSong,
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

  /// Our pause of the audio finished, so a later `isPlaying` is a takeover.
  bool _audioSettled = false;

  /// The video actually started, so its position is worth seeking audio to.
  bool _played = false;

  /// [startAt] fits inside the video duration.
  bool _aligned = false;

  /// App went to the background (only `paused`, not `inactive`).
  bool _backgrounded = false;

  /// Audio owns playback again: never seek or resume over it on close.
  bool _audioTookOver = false;

  /// [VideoSurface.onExitToSong] was already called.
  bool _exited = false;

  /// The widget is being disposed; every post-await continuation bails.
  bool _closed = false;

  /// Immersive chrome is on and still needs restoring (exactly once).
  bool _chromeHeld = false;

  @override
  void initState() {
    super.initState();
    final audio = context.read<AudioPlayerService>();
    _audio = audio;
    audio.addListener(_onAudio);
    WidgetsBinding.instance.addObserver(this);
    // Deferred: the failure path calls setState and must not run mid-initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  @override
  void dispose() {
    _closed = true;
    _audio?.removeListener(_onAudio);
    WidgetsBinding.instance.removeObserver(this);
    final at = _controller?.value.position ?? Duration.zero;
    _dropController();
    unawaited(_restoreAudio(at));
    _restoreChrome();
    super.dispose();
  }

  Future<void> _open() async {
    if (_closed) return;
    final audio = _audio!;
    final mine = audio.currentSong?.id == widget.song.id;
    if (audio.isLoading) {
      _fail('Track is still loading');
      return;
    }
    _resumeAudio = mine && audio.isPlaying;
    final startAt = mine ? audio.position : Duration.zero;

    if (_resumeAudio) {
      await audio.pause();
      _audioSettled = true;
      if (_closed) {
        await audio.resume();
        return;
      }
    }

    try {
      final online = await audio.hasInternet;
      if (_closed) return;
      if (!online) {
        _fail('Video needs internet');
        return;
      }

      final url = await audio.videoUrl(widget.song);
      if (_closed) return;
      if (url == null) {
        _fail('No video for this track');
        return;
      }

      final c = VideoPlayerController.networkUrl(
        Uri.parse(url),
        // HLS master playlist; its suffix alone is not always detected.
        formatHint: VideoFormat.hls,
        // ExoPlayer's own default UA was never probed against the CDN.
        httpHeaders: _audio!.videoHeaders,
      );
      _controller = c;
      await c.initialize();
      if (_closed) return;
      _aligned = startAt <= c.value.duration;
      await c.seekTo(_aligned ? startAt : Duration.zero);
      if (_closed) return;
      if (!_backgrounded) {
        await c.play();
        if (_closed) return;
      }
      setState(() {
        _played = true;
        _phase = _VideoPhase.playing;
      });
    } catch (_) {
      _dropController();
      _fail('Could not play the video');
    }
  }

  /// Audio took the track back. Called once, pauses the video, never navigates.
  void _onAudio() {
    if (_exited || _closed) return;
    final audio = _audio;
    if (audio == null) return;
    if (audio.currentSong?.id != widget.song.id) {
      _audioTookOver = true;
      _exitToSong();
      return;
    }
    // Lockscreen / car play wins; the failed state resumes on purpose.
    if (_audioSettled && _phase != _VideoPhase.failed && audio.isPlaying) {
      _audioTookOver = true;
      _exitToSong();
    }
  }

  void _exitToSong() {
    if (_exited) return;
    _exited = true;
    final c = _controller;
    if (c != null) unawaited(c.pause());
    widget.onExitToSong();
  }

  void _dropController() {
    final c = _controller;
    _controller = null;
    if (c != null) unawaited(c.dispose());
  }

  Future<void> _restoreAudio(Duration at) async {
    if (_audioTookOver) return;
    final audio = _audio;
    if (audio == null || audio.currentSong?.id != widget.song.id) return;
    if (_played && _aligned) await audio.seek(at);
    if (_resumeAudio) await audio.resume();
  }

  void _fail(String message) {
    if (!mounted) return;
    // Cleared before setState: a failed video never resumes audio twice.
    final resume = _resumeAudio;
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
    unawaited(c.value.isPlaying ? c.pause() : c.play());
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
    );
  }

  Widget _content(VideoPlayerController? c) => switch (_phase) {
        _VideoPhase.loading => const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
          ),
        _VideoPhase.failed => Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
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
