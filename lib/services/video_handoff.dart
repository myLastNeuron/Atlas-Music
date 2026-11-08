import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import 'audio_service.dart';
import '../models/song.dart';
import 'user_prefs.dart';

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
      // Repeat-one is the audio player's job, and it is paused in Video mode:
      // the parked video is the playback, so it repeats itself. A pinned
      // "Play next" is an explicit user choice and beats the loop.
      if ((_audio?.repeatOne ?? false) && _audio?.pinnedNext == null) {
        _songStart = Duration.zero;
        _videoStart = Duration.zero;
        unawaited(controller
            .seekTo(Duration.zero)
            .then((_) => controller.play())
            .catchError((_) {}));
        return;
      }
      _advanced = true;
      // The parked video is still the playback: its end is the song's end.
      unawaited(_audio?.playNext(0, false));
    }
  }
}

/// One handoff for the whole app: playback outlives the page, so it cannot be
/// owned by one.
final videoHandoff = VideoHandoff();

/// Starts the next song's video while only the mini player is visible.
///
/// Video mode is a saved choice, and the mini player is where it is watched
/// when the full player is closed. Without this, a track change fell back to
/// the still cover until the full player was reopened and resolved the video
/// again. The full player owns new loads while open; a load already in flight
/// here is left to finish so that page can adopt the same controller.
class MiniVideo {
  MiniVideo._();

  static final MiniVideo instance = MiniVideo._();

  AudioPlayerService? _audio;
  bool _playerOpen = false;
  int _gen = 0;

  /// The song we paused for an auto-load that has not taken over yet, so a
  /// detach can give playback back.
  String? _pausedForSong;

  /// The song already attempted, so a failed resolve is not retried on every
  /// position tick. A new song resets it.
  String? _attemptedSongId;

  /// Song whose video this loader is resolving/initializing right now.
  String? _loadingSongId;

  /// A play request arrived while that load was in flight: the video is the
  /// playback, so it must start playing once it has a first frame.
  bool _resumedDuringLoad = false;

  void attach(AudioPlayerService audio) {
    if (identical(_audio, audio)) return;
    _audio?.removeListener(_onAudio);
    _audio = audio;
    audio.addListener(_onAudio);
  }

  void detach() {
    _audio?.removeListener(_onAudio);
    _audio = null;
    _attemptedSongId = null;
    _cancelLoading();
  }

  /// The full player is opening (true) or has closed (false). While it is open
  /// it owns the next video load, so an attempt started here is abandoned:
  /// left to finish, it would pause the song the user is already listening to
  /// and park a video of its own choosing on top of the mini bar.
  set playerOpen(bool open) {
    _playerOpen = open;
    if (open) _cancelLoading();
  }

  void _cancelLoading() {
    _gen++;
    final songId = _loadingSongId;
    _loadingSongId = null;
    if (songId != null) videoHandoff.loaded(songId);
    _resumeOurPause(songId);
  }

  /// Give the song back if our attempt paused it and then lost ownership.
  void _resumeOurPause(String? songId) {
    final paused = _pausedForSong;
    if (paused == null) return;
    _pausedForSong = null;
    final audio = _audio;
    if (audio != null && (songId == null || audio.currentSong?.id == paused)) {
      unawaited(audio.resume());
    }
  }

  void _onAudio() {
    final audio = _audio;
    if (audio == null) return;
    final song = audio.currentSong;
    if (song == null) return;
    // Video is the playback: a play request made while this loader is still
    // resolving must not be heard. The pause is ours, so a failed load gives
    // the song back (see the finally in [_start]).
    if (_loadingSongId == song.id && audio.isPlaying) {
      _pausedForSong = song.id;
      _resumedDuringLoad = true;
      unawaited(audio.pause());
      return;
    }
    if (song.id == _attemptedSongId) return;
    // The full player owns this track's video while it is open; remember the
    // song so closing it does not trigger a second background load.
    if (_playerOpen) {
      _attemptedSongId = song.id;
      return;
    }
    // Wait for the track itself: a video cannot take over before the song is
    // actually playing, and the loading spinner already covers that gap.
    if (audio.isLoading || !audio.isPlaying) return;
    _attemptedSongId = song.id;
    if (!UserPrefs.videoMode) return;
    if (videoHandoff.isLiveFor(song.id) || videoHandoff.isLoadingFor(song.id)) {
      return;
    }
    unawaited(_start(song, audio));
  }

  /// Loads [song]'s video for the mini player now, for the full player that
  /// was closed while its video was still starting. [audioAlreadyPaused] means
  /// the caller already paused the song for this video: the load must give it
  /// back if the video never arrives.
  void loadFor(
    AudioPlayerService audio,
    Song song, {
    bool audioAlreadyPaused = false,
  }) {
    _audio ??= audio;
    if (audio.currentSong?.id != song.id) return;
    if (videoHandoff.isLiveFor(song.id) || videoHandoff.isLoadingFor(song.id)) {
      return;
    }
    _attemptedSongId = song.id;
    unawaited(_start(song, audio, audioAlreadyPaused: audioAlreadyPaused));
  }

  bool _alive(int gen, Song song) =>
      gen == _gen && _audio?.currentSong?.id == song.id;

  Future<void> _start(
    Song song,
    AudioPlayerService audio, {
    bool audioAlreadyPaused = false,
  }) async {
    final gen = ++_gen;
    _loadingSongId = song.id;
    videoHandoff.loading(song.id);
    VideoPlayerController? controller;
    var pausedAudio = audioAlreadyPaused;
    var handedOff = false;
    // Video mode is the choice: the song goes quiet while its video starts,
    // instead of playing for the two or three seconds of the lookup and then
    // being cut off when the video takes over.
    var wantPlayback = audio.isPlaying || audioAlreadyPaused;
    if (audioAlreadyPaused) _pausedForSong = song.id;
    try {
      if (audio.isPlaying) {
        pausedAudio = true;
        _pausedForSong = song.id;
        await audio.pause();
        if (!_alive(gen, song)) return;
      }
      // Where the song was when the video took it over.
      final songStart = audio.position;

      final online = await audio.hasInternet;
      if (!_alive(gen, song) || !online) return;

      final source =
          await audio.videoSource(song).timeout(audio.videoSourceTimeout);
      if (!_alive(gen, song) || source == null) return;

      controller = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        formatHint: VideoFormat.hls,
        httpHeaders: audio.videoHeaders,
      );
      await controller.initialize().timeout(const Duration(seconds: 15));
      if (!_alive(gen, song)) return;

      // A video shorter than the song cannot hold that position: start at 0
      // and keep the offset, so the timeline mapping still works.
      final canAlign = songStart <= controller.value.duration;
      final videoStart = canAlign ? songStart : Duration.zero;
      await controller.seekTo(videoStart).timeout(const Duration(seconds: 5));
      if (!_alive(gen, song)) return;

      // The mini bar's transport stays live while the video loads: a resume
      // during it is the user saying play, and the video is the playback here.
      if (audio.isPlaying || _resumedDuringLoad) {
        wantPlayback = true;
        pausedAudio = true;
        _pausedForSong = song.id;
        await audio.pause();
        if (!_alive(gen, song)) return;
      }

      // Parked, not merely published: the mini's play/pause and progress
      // drive it, and the full player takes the same controller on open.
      videoHandoff.park(
        controller: controller,
        songId: song.id,
        songStart: songStart,
        videoStart: videoStart,
        audio: audio,
      );
      videoHandoff.loaded(song.id);
      handedOff = true;
      pausedAudio = false;
      _pausedForSong = null;
      if (wantPlayback) unawaited(controller.play().catchError((_) {}));
      controller = null;
    } on TimeoutException {
      // Best-effort background load: the song is given back in the finally.
    } catch (_) {
      // Best-effort background load: the song is given back in the finally.
    } finally {
      _resumedDuringLoad = false;
      if (controller != null) unawaited(controller.dispose());
      if (_loadingSongId == song.id) {
        _loadingSongId = null;
        videoHandoff.loaded(song.id);
      }
      // The video never took over: give the song back if we paused it for an
      // attempt that was cancelled (song change, player open, failure).
      if (!handedOff) {
        final pausedHere = pausedAudio || _pausedForSong == song.id;
        _pausedForSong = null;
        if (pausedHere && _audio?.currentSong?.id == song.id) {
          unawaited(audio.resume());
        }
      }
    }
  }
}
