import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'audio_service.dart' as app;

/// Bridges the app's own queue ([app.AudioPlayerService]) to
/// `audio_service`, so the media notification drives — and reflects — the
/// app's real queue.
///
/// The app loads one source at a time (each track is resolved/downloaded
/// itself), so an AudioSource sequence always has length 1 and cannot
/// supply next/previous. Here the controls call the service's
/// [app.AudioPlayerService.playNext] / [app.AudioPlayerService.playPrevious]
/// directly.
class AtlasAudioHandler extends BaseAudioHandler {
  AtlasAudioHandler() {
    instance = this;
  }

  static AtlasAudioHandler? instance;

  app.AudioPlayerService? _service;
  String? _lastMediaId;
  String? _lastArtUri;
  PlaybackState _state = PlaybackState();

  void attach(app.AudioPlayerService service) {
    _service = service;
    syncFromService();
  }

  /// Re-sends the current media item (e.g. after a higher-resolution cover
  /// finished downloading) so the notification swaps the artwork.
  void refreshMediaItem() {
    _lastMediaId = null;
    syncFromService();
  }

  /// Rebuilds the media item / playback state from the service. Called from
  /// [app.AudioPlayerService.notifyListeners] so the notification always
  /// matches the app.
  void syncFromService() {
    final service = _service;
    if (service == null) return;

    final song = service.currentSong;
    if (song == null) {
      _lastMediaId = null;
      _lastArtUri = null;
      _state = _state.copyWith(
        controls: const [],
        systemActions: const {},
        androidCompactActionIndices: const [],
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        queueIndex: null,
      );
      playbackState.add(_state);
      return;
    }

    final item = service.mediaTagFor(song);
    final id = item.id;
    final artUri = item.artUri?.toString();
    if (id != _lastMediaId || artUri != _lastArtUri) {
      _lastMediaId = id;
      _lastArtUri = artUri;
      mediaItem.add(item);
    }

    // A momentary `idle` while a song is still selected is a transition, not a
    // stop: just_audio deactivates its platform at the start of every
    // setAudioSource (track change), which briefly reports ProcessingState.idle.
    // Relaying that as AudioProcessingState.idle makes the plugin's
    // _observePlaybackState call stopService() — tearing down the notification
    // and making SystemUI flash its "No media playing" placeholder on every
    // skip. A null song (real stop) already returned above, so idle here is
    // always transient: report loading instead.
    final mapped = _mapProcessingState(service.processingState);
    final effectiveProcessing = mapped == AudioProcessingState.idle
        ? AudioProcessingState.loading
        : mapped;
    final playing = service.isPlaying;
    _state = _state.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToPrevious,
        MediaAction.skipToNext,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: effectiveProcessing,
      playing: playing,
      updatePosition: service.position,
      bufferedPosition: service.position,
      speed: 1.0,
      // No queue is ever published (mediaItem.add is used, not
      // mediaItem.addQueue), so a queueIndex would point into a queue no
      // consumer can see. Omit it.
      queueIndex: null,
    );
    playbackState.add(_state);
  }

  static AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> play() async {
    await _service?.resume();
  }

  @override
  Future<void> pause() async {
    await _service?.pause();
  }

  @override
  Future<void> stop() async {
    await _service?.stop();
    await super.stop();
  }

  /// Android fires the notification delete intent on updates and carousel
  /// migration as well as on a real dismissal, and the default
  /// implementation calls [stop] — so handling it would end playback on
  /// routine notification updates. The user-facing Stop control is a
  /// separate ACTION_STOP, so ignoring the delete event is safe.
  @override
  Future<void> onNotificationDeleted() async {}

  @override
  Future<void> skipToNext() async {
    await _service?.playNext(0, true, null, true);
  }

  @override
  Future<void> skipToPrevious() async {
    await _service?.playPrevious();
  }

  @override
  Future<void> seek(Duration position) async {
    await _service?.seek(position);
  }

  @override
  Future<void> fastForward() async {
    final service = _service;
    if (service == null) return;
    await service.seek(service.position + const Duration(seconds: 10));
  }

  @override
  Future<void> rewind() async {
    final service = _service;
    if (service == null) return;
    final target = service.position - const Duration(seconds: 10);
    await service.seek(target < Duration.zero ? Duration.zero : target);
  }
}
