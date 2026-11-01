import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'audio_service.dart';

/// Maps a video position back onto the song's timeline. [songStart]/[videoStart]
/// are the two clocks at the moment the video took over; their difference is
/// the offset (equal when the video could start at the song's position, 0 vs
/// that position when it is too short). Clamped so seeking cannot leave the
/// song.
Duration mappedSongPosition({
  required Duration songStart,
  required Duration videoStart,
  required Duration videoPosition,
  required Duration songDuration,
}) {
  final target = songStart + (videoPosition - videoStart);
  if (target < Duration.zero) return Duration.zero;
  if (songDuration > Duration.zero && target > songDuration) {
    return songDuration;
  }
  return target;
}

/// The video of the moment, wherever it is on screen.
///
/// One controller is rendered by whichever surface shows it — the mini player's
/// square in Video mode and the full player's video box — so the cover flight
/// can carry the live frame instead of a still, and nothing restarts or pauses
/// when the video changes places. The full player opens and owns it; closing
/// parks it here, and the mini player keeps playing it.
///
/// A parked video ends itself as soon as the audio service plays or moves to
/// another song: whoever does that wants audio, not the parked video.
class VideoHandoff extends ChangeNotifier {
  VideoPlayerController? _controller;
  String? _songId;
  Duration _songStart = Duration.zero;
  Duration _videoStart = Duration.zero;

  /// Set while the full player is resolving/initializing a video: nothing to
  /// render yet, but the cover flight should carry the loading screen instead.
  String? _loadingSongId;

  /// Set only while parked: the service whose playback ends the handoff, and
  /// the owner of the controller.
  AudioPlayerService? _audio;
  bool _owned = false;
  bool _advanced = false;
  bool _playing = false;

  /// The video to render, or null when there is none.
  VideoPlayerController? get controller => _controller;

  /// The song that video belongs to.
  String? get songId => _songId;

  /// Song position when the video took over, and the video position it started
  /// from: together they put the video clock back on the song's timeline.
  Duration get songStart => _songStart;
  Duration get videoStart => _videoStart;

  bool isLiveFor(String? id) => _controller != null && _songId == id;

  /// [id]'s video is loading, not playing: surfaces show the spinner.
  bool isLoadingFor(String? id) => id != null && _loadingSongId == id;

  /// The full player started resolving/initializing [songId]'s video.
  void loading(String songId) {
    if (_loadingSongId == songId) return;
    _loadingSongId = songId;
    _notify();
  }

  /// The attempt for [songId] ended (played, failed or was closed).
  void loaded(String songId) {
    if (_loadingSongId != songId) return;
    _loadingSongId = null;
    _notify();
  }

  /// Announces the video the player just opened. Ownership stays with the
  /// caller; this only lets other surfaces render the same frames.
  void publish({
    required VideoPlayerController controller,
    required String songId,
    required Duration songStart,
    required Duration videoStart,
  }) {
    if (identical(_controller, controller)) {
      _songStart = songStart;
      _videoStart = videoStart;
      _songId = songId;
      return;
    }
    _forget(disposeOwned: true);
    _controller = controller;
    _songId = songId;
    _songStart = songStart;
    _videoStart = videoStart;
    _playing = controller.value.isPlaying;
    controller.addListener(_onVideo);
    _notify();
  }

  /// The full player closed on this video: park it so it keeps playing (or
  /// keeps its paused frame on screen) and the mini player drives it.
  void park({
    required VideoPlayerController controller,
    required String songId,
    required Duration songStart,
    required Duration videoStart,
    required AudioPlayerService audio,
  }) {
    // Already parked: refreshing the clocks must not forget (and dispose) the
    // very controller that is being kept.
    if (identical(_controller, controller) && _owned) {
      _songId = songId;
      _songStart = songStart;
      _videoStart = videoStart;
      _audio = audio;
      return;
    }
    _forget(disposeOwned: true);
    _controller = controller;
    _songId = songId;
    _songStart = songStart;
    _videoStart = videoStart;
    _audio = audio;
    _owned = true;
    _advanced = false;
    _playing = controller.value.isPlaying;
    controller.addListener(_onVideo);
    audio.addListener(_onAudio);
    _notify();
  }

  /// The full player opened again: it owns the controller from here. The frame
  /// stays published so the mini player behind keeps rendering it mid-flight.
  ({
    VideoPlayerController controller,
    Duration songStart,
    Duration videoStart,
  })? take(String songId) {
    final controller = _controller;
    if (controller == null || _songId != songId) return null;
    _audio?.removeListener(_onAudio);
    _audio = null;
    _owned = false;
    return (
      controller: controller,
      songStart: _songStart,
      videoStart: _videoStart,
    );
  }

  /// The owner disposed [controller]: stop advertising it. Nothing is disposed
  /// here — the owner already did, or is about to.
  void release(VideoPlayerController controller) {
    if (!identical(_controller, controller)) return;
    _forget(disposeOwned: false);
  }

  /// Nobody wants the video any more: stop it and let it go.
  void drop() {
    if (_controller == null) return;
    _forget(disposeOwned: true);
    _notify();
  }

  void _forget({required bool disposeOwned}) {
    final controller = _controller;
    final owned = _owned;
    _controller = null;
    _songId = null;
    _audio?.removeListener(_onAudio);
    _audio = null;
    _owned = false;
    _playing = false;
    controller?.removeListener(_onVideo);
    if (controller != null && owned && disposeOwned) {
      // Pause first: disposing a playing controller is a hard stop that some
      // platforms report as an error.
      unawaited(controller
          .pause()
          .catchError((_) {})
          .whenComplete(controller.dispose));
    }
    _notify();
  }

  /// Listeners are widgets. Park/release run from a widget's dispose, where the
  /// tree is locked and marking one dirty throws — so a change made during a
  /// frame is announced right after it.
  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
      return;
    }
    notifyListeners();
  }

  void _onAudio() {
    final audio = _audio;
    if (audio == null) return;
    if (audio.isPlaying || audio.currentSong?.id != _songId) drop();
  }

  void _onVideo() {
    final controller = _controller;
    if (controller == null) return;
    // Only the state the mini player shows: not every position tick.
    final playing = controller.value.isPlaying;
    if (playing != _playing) {
      _playing = playing;
      _notify();
    }
    if (!_advanced && _owned && controller.value.isCompleted) {
      _advanced = true;
      // The parked video is still the playback: its end is the song's end.
      unawaited(_audio?.playNext(0, false));
    }
  }
}

/// One handoff for the whole app: playback outlives the page, so it cannot be
/// owned by one.
final videoHandoff = VideoHandoff();
