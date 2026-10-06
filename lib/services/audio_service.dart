import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:audio_service/audio_service.dart' as audio;
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'atlas_audio_handler.dart';
import '../models/song.dart';
import '../media/cache_service.dart';
import '../media/media_source.dart';
import '../media/resolver_strategy.dart';
import '../media/resolve_failure.dart';
import '../media/providers/youtube_provider.dart';
import 'storage_service.dart';
import 'song_filter.dart';
import 'user_prefs.dart';
import 'youtube_service.dart';
import 'quick_picks.dart';

/// Playback brain. Knows queue, ExoPlayer, and cache â€” nothing else.
/// Audio bytes always arrive via [ResolverStrategy] as normalized
/// [MediaSource]s through one finite chain:
///
///   CACHE â†’ provider 1 â†’ provider 2 â†’ provider 3 â†’ FAIL
///
/// No provider-specific HTTP, parsing, or ranking logic lives here.
class AudioPlayerService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  /// Metadata only (related/search for autoplay). Streams come from providers.
  final YouTubeService _youtubeService = YouTubeService();
  final CacheService _cache = CacheService();
  final StorageService _storage = StorageService();
  final YouTubeProvider _youTube = YouTubeProvider();
  late final ResolverStrategy _strategy = ResolverStrategy([_youTube]);

  // Singleton instance for notification action callbacks.
  static AudioPlayerService? _instance;
  static AudioPlayerService get instance {
    _instance ??= AudioPlayerService._internal();
    return _instance!;
  }

  AudioPlayerService._internal();

  List<Song> _queue = [];
  int _currentIndex = -1;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _shuffle = false;
  LoopMode _loopMode = LoopMode.off;
  // Single-slot "Play next": plays once right after the current song, then
  // normal advance/autofetch resumes. Re-selecting replaces it; a fresh
  // explicit queue drops it. Never injected into _queue.
  Song? _playNextOverride;
  final Random _random = Random();
  ProcessingState _processingState = ProcessingState.idle;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  int _lastNotifiedSecond = -1;
  int _playGen = 0;
  // Monotonic token for "which load most recently claimed the network".
  // Each load captures its own token and installs a matching `stale`
  // closure on the shared provider, so a superseded resolve/download aborts
  // instead of running to completion. Kept separate from _playGen so an
  // explicit download can be superseded by a newer load without disturbing
  // playback ownership.
  int _loadToken = 0;
  int _activeLoadToken = 0;

  /// Live stream subscriptions for [dispose]. Without these, player/state
  /// events keep firing into a disposed notifier (debug assertion, release
  /// warning) and the connectivity stream leaks.
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];
  bool _disposed = false;

  /// Claims the network for a new load and points the provider's staleness
  /// hook at the returned token. Every entry point that does provider work
  /// calls this; an older claim's hook then reports stale.
  int _claimLoad() {
    final token = ++_loadToken;
    _activeLoadToken = token;
    _youTube.stale = () => token != _activeLoadToken;
    return token;
  }

  Song? _currentSong;
  // Committed player ownership: the song id + gen that actually holds the
  // native source. _currentSong only changes on commit (setAudioSource
  // success), so miniplayer never flickers to a track that failed to load.
  // Completion events must match active ownership, otherwise a late
  // teardown from the previous source skips the new song (pos=0 stuck).
  String? _activeSongId;
  int _activeGen = 0;
  DateTime? _activeSince;
  // Load watchdog (safety net only): fires if a load never reaches
  // setSource. Bounded awaits + generation checks guard every step.
  Timer? _loadWatchdog;
  String _loadStage = '-';
  // Listener dedup: ExoPlayer re-emits identical duration/state lines in
  // the same millisecond. Identical consecutive lines are dropped.
  String _lastStateKey = '';
  int _lastDurSec = -1;
  // Pending index for rapid taps: playNext computes from pending when a
  // load is in flight, without mutating committed _currentIndex early.
  int? _pendingIndex;
  Timer? _stallTimer;
  DateTime? _lastSkipAt;
  DateTime? _songPlayStart;
  bool _handlingCompletion = false;
  String? _lastRetrySongId;
  int _retryCount = 0;
  Duration _lastStallPosition = Duration.zero;
  // Background resilience: the OS delivers position updates late while
  // backgrounded, so a single stalled window must never skip, and a
  // failed background load must heal itself instead of sitting paused.
  bool _appBackgrounded = false;
  Timer? _bgRetryTimer;
  int _bgRetryCount = 0;
  // Wall-clock stamp when the current background-heal streak started. The
  // heal must never give up permanently, but it also must not run forever
  // against a permanently dead queue: after _bgRetryBudget it stops and
  // waits for a connectivity change / foreground transition.
  DateTime? _bgRetrySince;
  // Per-song retry count for background heal. Prevents infinite retry loop
  // on a single failing song by skipping to the next after max retries.
  final Map<String, int> _bgRetrySongCounts = <String, int>{};
  // Offline-resume retry: a background resolve/download failure puts the
  // queue in "paused for offline", which otherwise only wakes on a
  // connectivity-changed event or the foreground heal in `_onForeground`.
  // Some ROMs/VPNs never emit that event, so this bounded periodic
  // re-check resumes playback once the network recovers.
  Timer? _offlineResumeTimer;
  int _offlineResumeAttempt = 0;
  int _stallCount = 0;
  String? _stallSongId;
  // Background pre-download: while a song plays, the next songs in the
  // queue are resolved + cached ahead (up to 3 deep), chained one after
  // another. Loads read the cache directly, so only song ids are tracked.
  final Set<String> _preloadingSongIds = <String>{};
  // Songs already handled this queue position (cached hit or downloaded).
  final Set<String> _prefetchedSongIds = <String>{};
  // Preload failure memory per song (offline, or gave up after N failed
  // attempts). Skips every position-tick re-trigger until connectivity
  // returns or the song is downloaded, so a failed preload is not
  // restarted on every tick.
  Timer? _preloadRetryTimer;
  final Set<String> _preloadedBlockedSongIds = <String>{};
  String? _preloadAttemptSongId;
  int _preloadAttemptCount = 0;
  // Foreground queue-end retry: when a never-ending queue (search radio,
  // quick-picks continuation, generic autoplay) finds nothing to play at
  // the end, a transient network blip would otherwise leave playback
  // silently paused until the user taps play. Retry the queue-end build a
  // bounded number of times so it heals itself; give up only after the
  // budget is spent (connectivity-changed then resumes).
  Timer? _queueEndRetryTimer;
  int _queueEndAttempt = 0;
  // Completion guard: a safety net that guarantees an advance is attempted
  // whenever the player sits silent at `completed` (the exact "stuck paused
  // after a song" state). If the normal completion -> playNext chain ever
  // silently fails to start a load, this fires a force-advance after a
  // short grace period. It bails if anything is already progressing
  // (playing, loading, an advance in flight, a queue-end retry pending, a
  // newer generation), so it can never double-advance or fight a real load.
  Timer? _completionGuard;
  int _completionGuardCount = 0;
  // Per-song retry count for completion guard. Prevents infinite retry
  // loop on a single failing song in the foreground.
  final Map<String, int> _completionGuardSongCounts = <String, int>{};
  // Global advance failure counter. After N consecutive advance failures
  // (across all songs), stop retrying and pause gracefully. Prevents the
  // heal/completion-guard loop from running forever when every queued song
  // is unresolvable. Reset on: user interaction, new queue, connectivity.
  int _globalAdvanceFailures = 0;
  static const int _maxGlobalAdvanceFailures = 8;
  // Hard ceiling on one continuous background-heal streak. The heal stays
  // "never permanently give up" (a connectivity change or foreground
  // transition resets the streak), but a permanently dead queue must not
  // resolve+download every 45s for hours on end.
  static const Duration _bgRetryBudget = Duration(minutes: 10);
  // Wall-clock end-of-track preload arm. The OS throttles position events
  // while backgrounded, so the 45s window (driven by positionStream) can
  // be missed and the next song never cached -> a full download at
  // completion. This one-shot timer keeps the window alive even if the
  // position stream stops; re-armed on every in-window position event.
  Timer? _endPreloadTimer;
  // Queue paused because the requested song has no local file and the
  // device is offline (streaming disabled). Auto-resumes on connectivity
  // regain or when that song finishes downloading â€” never on a blind
  // timer, and never for a song the user navigated away from.
  bool _pausedForOffline = false;
  String? _pausedForOfflineSongId;
  int? _pausedForOfflineIndex;
  int? _pausedForOfflineGen;
  // Degraded offline session: songs confirmed uncached + offline
  // (id -> first-confirmed time), and per-song gate counts. The second
  // gate of the same song while still offline enters degraded mode:
  // further advances to known songs skip the host lookup entirely (fast
  // path) while cached songs keep playing. Reset on connectivity regain,
  // download of the song, new queue, or stop.
  final Map<String, DateTime> _offlineKnownUnavailable = <String, DateTime>{};
  final Map<String, int> _offlineGateCounts = <String, int>{};
  bool _degradedOffline = false;
  // Continuation-build cooldown: _prepareContinuation runs on position
  // ticks, so a failing/empty build must not rebuild on every tick.
  DateTime? _continuationNotBefore;
  // Where the current queue came from. 'quickPicks'/'continuation' queues
  // never stop at the end: they grow personalized continuations instead.
  String _queueOrigin = 'default';
  bool _preparingContinuation = false;
  // Queue-end policy: search queues grow seed-based radio instead of
  // stopping (see _playSeedRadio). Playlists/albums/popular keep generic
  // autoplay. Set whenever a new queue is assigned.
  bool _autoplayOnEnd = true;
  // Single-flight gate for queue advancement. Concurrent triggers
  // (duplicate completed events, stall recovery, queue-end chains) must
  // never advance twice â€” that double advance is the random track skip
  // (e.g. 1 -> 3). Exactly one playNext chain owns the transition at a
  // time; the rest collapse. A user tap steals ownership.
  bool _advancing = false;
  // The playback generation that owns the in-flight advance. Lets a forced
  // automatic advance collapse when it duplicates the same generation's
  // chain, while still letting a genuinely new generation proceed.
  int _advancingGen = -1;
  // Seed-based search radio: the song the user tapped to start a search
  // queue. Every queue end fetches tracks similar to this seed.
  Song? _autoplaySeed;
  // Ids + videoIds of finished tracks, excluded from radio batches so the
  // chain never replays or duplicates. Capped to bound memory.
  Set<String> _playedIds = <String>{};

  /// Short human-readable reason for the most recent load failure,
  /// surfaced in toasts so failures are diagnosable, not generic.
  String? _lastFailure;
  String? get lastFailure => _lastFailure;

  /// True while the queue is paused waiting for connectivity because the
  /// requested song is neither downloaded nor streamable. UI shows a
  /// persistent notice; playback auto-resumes when connectivity returns.
  bool get pausedForOffline => _pausedForOffline;

  /// True while in degraded offline mode: at least one queued song was
  /// gated offline_no_cache twice this session. Cached songs keep
  /// playing; known-uncached songs are skipped without fresh lookups.
  /// UI shows a notice that some tracks need internet.
  bool get degradedOffline => _degradedOffline;

  void _noteFailure(String detail) {
    var d = detail.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (d.length > 140) d = '${d.substring(0, 140)}â€¦';
    _lastFailure = d.isEmpty ? null : d;
  }

  // How the last load failed. Transient (network/timeout/offline) means
  // the SAME song should be retried â€” the next one would fail identically.
  // Only a definitive format rejection counts as permanent (skip ahead).
  bool _lastLoadWasTransient = true;

  /// Called from the app lifecycle observer. Never throws.
  void setAppBackgrounded(bool backgrounded) {
    _appBackgrounded = backgrounded;
    if (!backgrounded && _pausedForOffline) {
      // App returned to foreground while paused for offline.
      // Re-check connectivity and resume if network is back.
      unawaited(_onConnectivityMaybeChanged());
    }
    if (!backgrounded) {
      // Foreground owns recovery now (immediate connectivity re-check +
      // stuck-advance heal); the background retry must not double-fire.
      _cancelOfflineResumeRetry('foreground');
      // Foreground is a fresh recovery attempt: restart the heal budget.
      _bgRetrySince = null;
      // Foreground: a song that ended in the background may have its
      // advance stuck (the next load failed under restricted background
      // networking). Heal it immediately instead of waiting for the next
      // backoff tick so music resumes as soon as the app is opened.
      _onForeground();
    } else {
      // Backgrounding with an offline pause still active must (re-)arm the
      // self-heal: foregrounding cancelled it above and nothing else does,
      // so without this the timer is permanently gone after one open.
      if (_pausedForOffline) {
        _armOfflineResumeRetry();
      }
    }
  }

  /// On returning to the foreground, if a song finished and playback is
  /// silent and not progressing, retry the advance now that network is
  /// available. Never double-advances: bails if anything is already
  /// loading, advancing, or playing.
  void _onForeground() {
    if (_currentSong == null || _queue.isEmpty) return;
    if (_isLoading || _advancing || _player.playing) return;
    if (_pausedForOffline) return;
    final st = _player.processingState;
    if (st != ProcessingState.completed && st != ProcessingState.idle) return;
    // Reset global advance failures: foreground transition means the user
    // opened the app, so automatic recovery gets a fresh budget.
    _globalAdvanceFailures = 0;
    unawaited(playNext(0, false, null, true).catchError((Object e) {
      return false;
    }));
  }

  /// True while [songId] + [gen] still own the active player. Every async
  /// sequence that touches [_player] (loads, nudges, resumes, heals)
  /// captures both and bails the moment either changes â€” a stale command
  /// must never seek/stop/play a newer song's source.
  bool _stillCurrent(String? songId, int gen) =>
      gen == _playGen && songId != null && songId == _currentSong?.id;

  /// Record listen stats for the song that just finished or was skipped.
  void _recordPreviousListen({required bool skipped}) {
    final prev = _currentSong;
    final start = _songPlayStart;
    if (prev == null || start == null) return;
    final listenedMs = DateTime.now().difference(start).inMilliseconds;
    if (listenedMs < 1000) return;
    final durMs = prev.duration.inMilliseconds;
    final reallySkipped = skipped || (durMs > 0 && listenedMs < durMs * 0.8);
    _storage.recordListen(prev, listenedMs: listenedMs, skipped: reallySkipped);
  }

  void _startTracking(Song song) {
    _recordPreviousListen(skipped: true);
    _currentSong = song;
    _songPlayStart = DateTime.now();
  }

  void _markCompleted() {
    // Radio exclusion: a finished track must never come back in a later
    // radio batch (no replays, no duplicates).
    final cur = _currentSong;
    if (cur != null) {
      _playedIds.add(cur.id);
      _playedIds.add(cur.videoId ?? cur.id);
      if (_playedIds.length > 1000) {
        _playedIds = _playedIds.skip(500).toSet();
      }
    }
    _recordPreviousListen(skipped: false);
    // Clear start so the next _startTracking doesn't double-record the
    // just-completed track as skipped.
    _songPlayStart = null;
  }

  /// Double-fire guard: Bluetooth double-events, double taps, and pocket
  /// taps on notification buttons can land twice within milliseconds.
  /// Second hit inside window is a no-op (silent success, no toast).
  bool _skipGuard() {
    final now = DateTime.now();
    if (_lastSkipAt != null &&
        now.difference(_lastSkipAt!) < const Duration(milliseconds: 600)) {
      return false;
    }
    _lastSkipAt = now;
    return true;
  }

  AudioPlayer get player => _player;
  List<Song> get queue => _queue;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  bool get shuffleEnabled => _shuffle;
  LoopMode get loopMode => _loopMode;
  ProcessingState get processingState => _processingState;
  Duration get duration => _duration;
  Duration get position => _position;
  Song? get currentSong => _currentSong;

  /// Local path to the resolved high-resolution cover for [song], or null
  /// while it is still downloading (or for non-YouTube sources). The
  /// notification already used this cache; exposing it lets the full-screen
  /// player show the same sharp file instead of the low-res network
  /// thumbnail. Callers rebuild when the service notifies (the path flips
  /// from null to a file once `_resolveArtwork` finishes).
  String? highResArtPathFor(Song? song) {
    if (song == null) return null;
    final videoId = (song.videoId ?? song.id).trim();
    if (videoId.isEmpty) return null;
    return _artFileCache[videoId];
  }

  AudioPlayerService() {
    _instance = this;
    _initSession();
    // Hook the media notification to this service's real queue.
    AtlasAudioHandler.instance?.attach(this);
    // TEMPORARY boot marker: proves which binary is on device.
    _cache.sweep();
    // Listen to player state for notification updates.
    _subs.add(_player.positionStream.listen((position) {
      _position = position;
      // Stall watchdog keeps its own baseline in _lastStallPosition.
      // Do not overwrite it or cancel the timer on every tick, otherwise
      // the watchdog either never fires or always sees zero advancement.
      // Cap rebuilds at 1/sec: every tick rebuilds all watchers (grids,
      // sliders, buttons) and on slow phones that jank eats taps.
      if (position.inSeconds != _lastNotifiedSecond) {
        _lastNotifiedSecond = position.inSeconds;
        notifyListeners();
      }
      _maybePreloadNext(position);
    }));

    _subs.add(_player.durationStream.listen((duration) {
      _duration = duration ?? Duration.zero;
      // Dedup: identical consecutive duration lines are one native event.
      if (_duration.inSeconds == _lastDurSec) return;
      _lastDurSec = _duration.inSeconds;
      // Duration trace: a ~15s reported duration on a minutes-long song
      // means the source itself is truncated (native layer), not a Dart
      // restart. Tagged with the owning source, not the current UI song.
      notifyListeners();
    }));

    _subs.add(_player.playerStateStream.listen((state) {
      // Dedup: identical consecutive state lines are one native event.
      final key =
          '${state.processingState}|${state.playing}|${_position.inSeconds}s';
      if (key == _lastStateKey) return;
      _lastStateKey = key;
      // Tagged with the owning source so a previous source's terminal
      // event can never wear the next song's name.
      _processingState = state.processingState;
      // Drive the UI from the ACTUAL player state. On completion the player
      // still reports playing==true (nothing paused it), which reads as a
      // playing state while the audio is silent. Force it false on
      // completed/idle so the play/pause control matches reality.
      _isPlaying =
          state.playing && state.processingState != ProcessingState.completed;
      if (state.processingState == ProcessingState.completed) {
        if (_loopMode == LoopMode.one) {
          // Witness: repeat-one replays are user intent, logged so a 1->1
          // loop is distinguishable from an automatic advance.
          notifyListeners();
          return;
        }
        _handleCompletion();
      }
      _scheduleCompletionGuard();
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      // Stream-error witness: a background stream that dies (network cut,
      // expired googlevideo URL) would otherwise stop with no trace at
      // all, leaving a silent player that looks like a live process.
      // Log only; recovery stays owned by the stall watchdog / background
      // heal paths.
    }));

    // Connectivity trigger (no polling): preload unblock and offline
    // queue-resume react to REAL connectivity changes only. The event
    // only arms a re-check; truth still comes from _hasConnectivity, so
    // a captive portal (wifi up, no internet) never reads as online.
    _subs.add(Connectivity().onConnectivityChanged.listen((results) {
      // Network transition: a fresh heal streak is justified.
      _bgRetrySince = null;
      unawaited(_onConnectivityMaybeChanged());
    }));
  }

  /// Completion handler that only advances when playback genuinely finished.
  /// A `completed` event with the position far from the end is premature
  /// (truncated range, network cut mid-stream â€” the classic ~15s stall).
  /// Premature => resume IN PLACE from the last known position, never a
  /// full reload: reloading restarts the song from 00:00 and, on a
  /// restricted network, burns the queue and strands playback paused.
  /// Bounded (2 in-place tries): a truly dead source skips ahead instead
  /// of looping. Genuine => record + playNext. The position check runs in
  /// background too â€” backgrounding alone must never read as finished.
  void _handleCompletion() {
    if (_handlingCompletion) return;
    var cur = _currentSong;
    // Heal null UI state: if a false load-failed reverted currentSong while
    // native kept playing, recover from the committed active song so the
    // genuine completion still advances instead of being dropped.
    if (cur == null && _activeSongId != null) {
      try {
        final found = _queue.firstWhere((s) => s.id == _activeSongId);
        cur = found;
        _currentSong = found;
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
    }
    if (cur == null) return;
    final Song song = cur;
    // Root ownership: only the song that actually holds the native source
    // may advance. Both are set together in _commitSong after setAudioSource
    // succeeds. Mismatch = late teardown from the previous source.
    if (_activeSongId == null) return;
    if (song.id != _activeSongId) return;
    final eventGen = _playGen;
    _handlingCompletion = true;

    // Fresh event truth: read position and duration at the event, not the
    // cached _position/_duration (two independent just_audio streams, no
    // ordering guarantee).
    final eventDur = _duration.inSeconds > 0 ? _duration : song.duration;
    final eventPos = _player.position; // sync read at the event
    final pos = eventPos.inSeconds > 0 ? eventPos : _position; // fallback
    // Genuine only when the position proves it: within 5s of the end or
    // past 80%. Anything earlier is an interrupted source, not an ending.
    bool genuine = true;
    if (eventDur.inSeconds > 0) {
      final nearEnd = pos >= eventDur - const Duration(seconds: 5);
      final pastMost = eventDur.inMilliseconds > 0 &&
          pos.inMilliseconds >= eventDur.inMilliseconds * 0.8;
      if (!nearEnd && !pastMost) {
        genuine = false;
        // Truncated file check applies only when clearly short of the end.
        final expected = song.duration;
        if (expected.inSeconds > 0 &&
            eventDur.inSeconds + 10 < expected.inSeconds) {
          genuine = false;
        }
      }
    }

    if (!genuine) {
      // Belt-and-suspenders: if a fresh read proves near-end, it is an
      // ending regardless of any misclassification above. Advance, never
      // fall into the same-song reload.
      if (eventDur.inSeconds > 0 &&
          pos >= eventDur - const Duration(seconds: 5)) {
        _retryCount = 0;
        _lastRetrySongId = null;
        _markCompleted();
        unawaited(Future.microtask(() async {
          try {
            if (song.id != _activeSongId) return;
            await playNext(0, false, null, true);
          } finally {
            _handlingCompletion = false;
          }
        }));
        return;
      }
      // A completed event with pos near zero arriving seconds after commit
      // cannot belong to the just-started source (songs are 45s+): it is
      // the previous source's teardown arriving after the new commit won
      // the race. Ignore it so the new song is not skipped.
      if (pos.inSeconds < 5 &&
          _activeSince != null &&
          DateTime.now().difference(_activeSince!) <
              const Duration(seconds: 10)) {
        _handlingCompletion = false;
        return;
      }
      // Premature completion: continue the SAME source from the SAME
      // position, never stop/reload it, which would restart the track at
      // 00:00. If the track stopped very early (<60s), it is almost
      // certainly a preview/truncated stream that will never recover, so
      // skip ahead instead of looping on the same source.
      if (pos.inSeconds < 60) {
        // Do not restart the same track on a single-item queue (any loop
        // mode): it would immediately replay from 00:00.
        final isSingleItem = _queue.length <= 1;
        _handlingCompletion = false;
        _retryCount = 0;
        _lastRetrySongId = null;
        _markCompleted();
        if (isSingleItem) {
          // Search radio owns the future: a broken seed still yields
          // fresh similar tracks instead of a dead pause.
          if ((_queueOrigin == 'search' || _queueOrigin == 'searchRadio') &&
              _autoplayOnEnd) {
            unawaited(Future.microtask(() async {
              try {
                await playNext();
              } catch (_) {
                // Advance failure falls back to the completion guard.
              }
            }));
            return;
          }
          // Pause instead of re-loading the same broken source.
          Future.microtask(() async {
            try {
              await _player.pause();
            } catch (_) {
              // Player command is best-effort; state re-syncs from the stream.
            }
          });
          return;
        }
        // Off-listener: never run the load inline inside the state-stream
        // callback (re-entrancy deadlock). Same for every advance below.
        unawaited(Future.microtask(() async {
          try {
            await playNext();
          } catch (_) {
            // Advance failure falls back to the completion guard.
          }
        }));
        return;
      }
      if (_lastRetrySongId == song.id) {
        _retryCount++;
      } else {
        _lastRetrySongId = song.id;
        _retryCount = 1;
      }
      if (_retryCount > 2) {
        _retryCount = 0;
        _lastRetrySongId = null;
        _handlingCompletion = false;
        _markCompleted();
        unawaited(Future.microtask(() async {
          try {
            await playNext();
          } catch (_) {
            // Advance failure falls back to the completion guard.
          }
        }));
        return;
      }
      _handlingCompletion = false;
      Future.microtask(() async {
        try {
          // Ownership check: user taps / newer loads own the player now.
          if (!_stillCurrent(song.id, eventGen)) {
            return;
          }
          await _activateSession();
          if (!_stillCurrent(song.id, eventGen)) return;
          // Avoid seek on premature completion: seeking a truncated/preview
          // stream often resets to start, causing the 00:00 restart loop.
          // Reload the source with a fresh URL to recover from token expiry /
          // truncated stream instead of trying to resume in place.
          if (!_stillCurrent(song.id, eventGen)) return;
          // Reload song to get fresh URL / fresh stream. Unblock the next
          // song's prefetch too: if this reload stalls again, the advance
          // after it should find its file already cached.
          _unblockPreloadAhead();
          await playSong(song, index: _currentIndex);
          return;
        } catch (e) {
          try {
            syncPlaybackState();
          } catch (_) {
            // Non-fatal: the surrounding watchdog covers this path.
          }
        }
      });
      return;
    }

    _retryCount = 0;
    _lastRetrySongId = null;
    _markCompleted();
    // Advance immediately: no artificial delay. The active-song check
    // above already filters stale teardown events, so waiting only
    // widens the race and leaves UI paused at 00:00.
    // force: a genuine end-of-song is a hard guarantee â€” a stuck advance
    // flag must never swallow its advance into a silent no-op that leaves
    // the player frozen on the finished song until the user clicks play.
    Future.microtask(() async {
      try {
        if (song.id != _activeSongId) return;
        // force=true: a genuine end-of-song is a hard guarantee. A stuck
        // advance flag must not swallow it into a silent no-op that
        // leaves the player frozen on the finished song until the user
        // clicks play.
        await playNext(0, false, null, true);
      } finally {
        _handlingCompletion = false;
      }
    });
  }

  /// Activates the audio session, never hanging: every await here talks
  /// to the platform and must be bounded, otherwise one stuck call would
  /// freeze playback startup (infinite spinner, "loads, nothing happens").
  Future<void> _activateSession() async {
    try {
      final session =
          await AudioSession.instance.timeout(const Duration(seconds: 5));
      await session.setActive(true).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Audio session activation is best-effort.
    }
  }

  Future<void> _initSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        // Duck (brief volume dip), never full pause, on transient
        // focus loss (notification sounds, assistant blips). True made
        // every notification stop music then auto-resume seconds later.
        androidWillPauseWhenDucked: false,
      ));
    } catch (e) {
      // Audio still plays without a configured session on most devices.
    }
  }

  /// Returns true when audio actually started. False = silent FAIL
  /// (all paths exhausted) or superseded tap â€” caller decides whether
  /// to toast by checking the song is still current.
  /// [autoplayOnEnd] decides queue-end behavior for a newly assigned
  /// queue: true fetches related autoplay content (playlists, popular),
  /// false ends playback normally (search results).
  /// [queueOrigin] tags a newly assigned queue ('quickPicks', ...).
  /// Quick-Picks/continuation queues grow personalized continuations at
  /// the end instead of stopping or playing unrelated autoplay content.
  Future<bool> playSong(Song song,
      {List<Song>? queue,
      int? index,
      bool autoplayOnEnd = true,
      String? queueOrigin}) async {
    // Duplicate request for the song already loading (double-tap, retap
    // during a slow load): absorb it BEFORE bumping the generation. A
    // second sequence would stop the first one's source mid-play and
    // reload it â€” an audible restart from 00:00 seconds later when the
    // second resolve/setSource lands. The in-flight load owns playback.
    // (Deliberate replay of an already-PLAYING song still works: it is
    // not loading, so it falls through.) Retries use queue==null and are
    // unaffected.
    // Latest tap wins: rapid skip taps supersede in-flight loads instead
    // of racing them (two setAudioSource calls interleaved = dead buttons).
    // [gen] is this load's ownership token: every await boundary below
    // re-checks it, so a superseded load can never command the player.
    _lastFailure = null;
    final int gen = ++_playGen;
    // Newest load claims the network: provider work still running for an
    // older load now reports stale and aborts.
    _claimLoad();
    bool stale() => gen != _playGen;
    // Assign synchronously (before the first await) so a second tap that
    // lands during stop() already sees the new index. Otherwise both taps
    // compute next from the same stale _currentIndex and the second tap
    // replays the first tap's song.
    if (queue != null) {
      // GLOBAL rules: discovery queues (search, autoplay, recommendations)
      // never carry out-of-window or wrong-language songs.
      // EXCEPTION: explicit playlists ('playlist') keep every imported song
      // — the user chose them — so the queue is used as-is. A manually
      // tapped song always plays regardless (id remap below).
      List<Song> filtered = queue;
      if (queueOrigin != 'playlist') {
        try {
          final lang = await UserPrefs().getLanguage();
          filtered = SongFilter.apply(queue, language: lang);
        } catch (e) {
          filtered = queue;
        }
      }
      var at = filtered.indexWhere((s) => s.id == song.id);
      if (at < 0) {
        final fallback = List<Song>.from(filtered);
        final rawAt = queue.indexWhere((s) => s.id == song.id);
        at = (rawAt < 0 ? fallback.length : rawAt).clamp(0, fallback.length);
        fallback.insert(at, song);
        filtered = fallback;
      }
      _queue = filtered;
      _currentIndex = at;
      _autoplayOnEnd = autoplayOnEnd;
      _queueOrigin = queueOrigin ?? 'default';
      // A fresh explicit queue owns the future: a "Play next" from the old
      // context no longer applies.
      _playNextOverride = null;
      _preparingContinuation = false;
      // A new queue starts a new offline episode: old known-unavailable
      // memory belongs to a different queue.
      _resetOfflineSession('new_queue');
      _cancelOfflineResumeRetry('new_queue');
      // A newly assigned queue owns the future: cancel any in-flight
      // automatic advance so it cannot advance this fresh queue twice.
      _advancing = false;
      // Reset global advance failures: user intent overrides automatic
      // recovery state.
      _globalAdvanceFailures = 0;
      // (Re)seed search radio on every manual search play; any other
      // fresh queue clears a stale search seed.
      if (_queueOrigin == 'search') {
        _autoplaySeed = song;
      } else if (_queueOrigin != 'searchRadio') {
        _autoplaySeed = null;
      }
    }
    // A new load attempt supersedes any pending background heal.
    _cancelBackgroundRetry();
    // If the SAME song is already playing past 5 s, absorb ANY reload
    // (preload, continuation, retry, background heal) â€” a second
    // setSource would reset position to 0 and cause the 17 s restart.
    if (_activeSongId == song.id &&
        _player.playing &&
        _position.inSeconds > 5) {
      return true;
    }
    // Fresh song => reset retry budgets. Same-song retry (from
    // _handleCompletion or the background healer) keeps its count.
    if (_activeSongId != song.id) {
      _retryCount = 0;
      _lastRetrySongId = null;
      _bgRetryCount = 0;
      _cancelBackgroundRetry();
      _stallCount = 0;
      _stallSongId = null;
      _clearPreloadState();
      _preparingContinuation = false;
      // A new user/navigation load cancels the offline pause: the pause
      // only auto-resumes when the user has NOT navigated away.
      if (_pausedForOffline) {
        _pausedForOffline = false;
      }
    }
    // UI intent publishes immediately so the miniplayer appears during
    // load. Active ownership (_activeSongId/_activeGen) only flips in
    // _commitSong after setAudioSource succeeds, so stale teardown events
    // can't be mis-attributed. Position/duration stay with the active
    // source until commit to avoid 00:00 flicker.
    final Song? prevSong = _currentSong;
    _currentSong = song;
    if (queue == null && index != null && _queue.isNotEmpty) {
      _pendingIndex = index.clamp(0, _queue.length - 1);
    } else {
      _pendingIndex = null;
    }
    void revertPending() {
      // Genuine failure (not superseded): put UI back on the previous song.
      // First-load failure reverts to null (nothing to show) which is correct.
      if (_currentSong?.id == song.id && _activeSongId != song.id) {
        _currentSong = prevSong;
      }
      _pendingIndex = null;
      _cancelLoadWatchdog();
    }

    _isLoading = true;
    notifyListeners();
    // Watchdog (safety net): if this load never reaches setSource, log
    // which stage it died in and restart once. Root safety comes from the
    // bounded awaits + gen checks below.
    _startLoadWatchdog(song, gen,
        queue: queue,
        index: index,
        autoplayOnEnd: autoplayOnEnd,
        queueOrigin: queueOrigin);
    try {
      _cancelStallTimer();
      // Re-activate the session up front: after backgrounding the OS may
      // have taken focus, and starting without it leaves the new track
      // silently paused.
      _loadStage = 'session';
      await _activateSession();
      if (stale()) {
        return false;
      }
      // Root: never call stop() here. stop() after a completed source
      // emits an extra completed/idle pair that gets mis-attributed to
      // the next song (pos=0). setAudioSource replaces the source on its
      // own. Only pause audible audio for an instant cut.
      _loadStage = 'pause';
      try {
        if (_player.playing) {
          await _player.pause().timeout(const Duration(seconds: 5));
        }
      } catch (_) {
        // Player command is best-effort; state re-syncs from the stream.
      }
      if (stale()) {
        return false;
      }

      final report =
          PlaybackReport(song.title, songId: song.videoId ?? song.id);

      // 1. CACHE â€” offline-first replay, zero network. Local file wins:
      // no provider is touched when it hits (saves ~2.5s per track).
      _loadStage = 'cache';
      final cached = await _cache.getValid(song);
      if (stale()) {
        return false;
      }
      if (cached != null) {
        try {
          await _playFile(cached.path, song, stale, gen);
          if (stale()) {
            return false;
          }
          _commitSong(song, gen);
          _finishPlaying();
          return true;
        } catch (e) {
          // Cache playback failure is not necessarily permanent â€” the file
          // may still be valid. Only invalidate if the error is a format/codec
          // issue, not a transient network/timeout issue.
          final t = e.toString().toLowerCase();
          final isTransient = e is TimeoutException ||
              t.contains('timeout') ||
              t.contains('host lookup') ||
              t.contains('socket') ||
              t.contains('connection') ||
              t.contains('unreachable');
          if (isTransient) {
            // Transient error: keep cache, proceed to provider resolution.
            // Don't invalidate â€” the stream may work on retry or via a different path.
          } else {
            // Permanent format/corruption issue: invalidate and report.
            report.add(ResolveFailure(
              provider: null,
              stage: ResolveStage.playback,
              detail: 'cached file unplayable, evicted: $e',
              retryable: true,
            ));
            try {
              await _cache.invalidate(song);
            } catch (_) {
              // The cache entry simply stays until it expires.
            }
          }
        }
      }

      // Degraded-mode fast path: this song was already confirmed
      // uncached + offline this session â€” skip the host lookup entirely
      // (no DNS storm every lap) and go straight to the cache-only skip
      // search. Cache is still checked first above, so a file downloaded
      // since never takes this path.
      final knownSince =
          _degradedOffline ? _offlineKnownUnavailable[song.id] : null;
      if (knownSince != null) {
        _lastLoadWasTransient = false;
        _noteFailure('Track unavailable â€” no internet and not downloaded');
        final base = _pendingIndex ?? _currentIndex;
        return await _skipOrWaitOffline(song, gen, base, revertPending);
      }

      // Skip pre-flight connectivity gate: DNS/connectivity-plus can
      // false-negative on VPNs/custom DNS. Let the provider resolution
      // be the real connectivity proof. If resolution fails (DNS/timeout),
      // THEN treat as offline below.

      // 2. RESOLVE through the provider chain. Bounded: provider budgets
      // are long (60s each), so an outer timeout guarantees this load can
      // never vanish silently no matter what a provider awaits inside.
      _loadStage = 'resolve';
      MediaSource? source;
      try {
        source = await _strategy
            .resolveFirstValid(song, report)
            .timeout(const Duration(seconds: 75));
      } on TimeoutException catch (e) {
        report.add(ResolveFailure(
          provider: null,
          stage: ResolveStage.resolution,
          detail: 'resolve exceeded 75s: $e',
          retryable: true,
        ));
        source = null;
      }
      if (stale()) {
        return false;
      }
      if (source == null) {
        // Nothing resolved at all: fail fast here instead of running a
        // second doomed resolve inside the download step. Transient means a
        // network/DNS/connection problem (regardless of the provider's scope
        // tag, which can be unreliable): the SAME song must be retried, not
        // cascaded past. Check both the scope field AND the detail string so
        // a DNS/socket failure that got mislabelled song-scoped still counts
        // as transient (otherwise the advance burns through the whole queue
        // in milliseconds, hammering the resolver).
        _lastLoadWasTransient = report.attempts.isEmpty ||
            report.attempts.any((a) => a.scope != FailureScope.song) ||
            report.attempts.any((a) {
              final d = a.detail.toLowerCase();
              return d.contains('socket') ||
                  d.contains('dns') ||
                  d.contains('host lookup') ||
                  d.contains('unreachable') ||
                  d.contains('connection') ||
                  d.contains('timeout') ||
                  d.contains('connectivity');
            });
        // Report the last attempt, not the first: the toast must show the
        // final fallback's error rather than an earlier provider's miss.
        _noteFailure(report.attempts.isNotEmpty
            ? report.attempts.last.detail
            : 'no playable source found');
        // If the failure looks like a network error, treat as offline
        // so skip/pause logic kicks in instead of silently stopping.
        final isNetworkFail = report.attempts.any((a) {
          final d = a.detail.toLowerCase();
          return d.contains('socket') ||
              d.contains('dns') ||
              d.contains('host lookup') ||
              d.contains('unreachable') ||
              d.contains('connection') ||
              d.contains('timeout') ||
              d.contains('connectivity');
        });
        if (isNetworkFail) {
          _recordOfflineGate(song);
          final base = _pendingIndex ?? _currentIndex;
          return await _skipOrWaitOffline(song, gen, base, revertPending);
        }
        revertPending();
        _isLoading = false;
        notifyListeners();
        _scheduleBackgroundRetry();
        return false;
      }


      // 3. DOWNLOAD the resolved source, verify it, play the file.
      // The commit size check rejects truncated and preview-length files,
      // so a short snippet can never pose as a song. The already-resolved
      // source downloads directly (no second manifest fetch); a fresh
      // chain is only a fallback.
      _loadStage = 'download';
      File? audioFile;
      try {
        audioFile = await _downloadSource(source, song, report)
            .timeout(const Duration(seconds: 180));
        if (stale()) {
          return false;
        }
      } on TimeoutException catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
        if (stale()) {
          return false;
        }
        report.add(ResolveFailure(
          provider: source.provider,
          stage: ResolveStage.download,
          detail: 'download exceeded 180s: $e',
          retryable: true,
        ));
        audioFile = null;
      } catch (e) {
        if (stale()) {
          return false;
        }
        report.add(ResolveFailure(
          provider: source.provider,
          stage: ResolveStage.download,
          detail: 'download failed: $e',
          retryable: true,
        ));
        audioFile = null;
      }
      if (audioFile != null) {
        try {
          await _playFile(audioFile.path, song, stale, gen);
          if (stale()) {
            return false;
          }
          _commitSong(song, gen);
          _finishPlaying();
          return true;
        } catch (e) {
          // A size-verified local file failing to play is a player-state
          // issue, not a bad song: keep it transient so the same track
          // is retried instead of skipped.
          report.add(ResolveFailure(
            provider: source.provider,
            stage: ResolveStage.playback,
            detail: 'cached file playback failed: $e',
            retryable: true,
          ));
        }
      }

      // 4. FAIL with the full structured chain â€” never throw; keep state stable.
      if (stale()) return false;
      // Do not throw â€” instead report the failure to the user via the
      // playback report and keep the current song state stable.
      report.add(ResolveFailure(
        provider: null,
        stage: ResolveStage.playback,
        detail: 'all providers failed: ${report.toUserMessage()}',
        retryable: false,
      ));
      _lastLoadWasTransient = true;
      _noteFailure(report.attempts.isNotEmpty
          ? report.attempts.last.detail
          : 'all providers failed');
      revertPending();
      _isLoading = false;
      notifyListeners();
      _scheduleBackgroundRetry();
      return false;
    } catch (e) {
      if (stale()) return false;
      _cancelStallTimer();
      revertPending();
      _isLoading = false;
      notifyListeners();
      // Offline gate and unexpected errors: transient by definition.
      _lastLoadWasTransient = true;
      _noteFailure('$e');
      _scheduleBackgroundRetry();
      rethrow;
    }
  }

  /// Self-heal for background loads: a failed autoplay while backgrounded
  /// would otherwise stay paused. Retries with backoff
  /// (3s/8s/15s/25s/45s, then 45s repeat) while silent; any success, new
  /// song, pause, or stop cancels. Must never permanently give up: the
  /// completion-guard retry is foreground-only, so this timer is the sole
  /// background recovery path.
  void _scheduleBackgroundRetry() {
    if (_pausedForOffline) {
      // The heal timer would retry the SAME unplayable song with the
      // SAME missing file. The offline pause already owns recovery
      // (connectivity-changed / download-complete).
      return;
    }
    if (!_appBackgrounded) {
      return;
    }
    final song = _currentSong;
    if (song == null) {
      return;
    }
    // Bounded heal: one continuous streak gets _bgRetryBudget, then it
    // stops. Recovery resumes on a connectivity change or foreground
    // transition (both reset _bgRetrySince), so this is a pause, not a
    // permanent give-up.
    _bgRetrySince ??= DateTime.now();
    if (DateTime.now().difference(_bgRetrySince!) > _bgRetryBudget) {
      return;
    }
    // Heal captures the gen it was scheduled for and never acts on a song
    // that is no longer current.
    final healGen = _playGen;
    _bgRetryTimer?.cancel();
    const delays = [3, 8, 15, 25, 45];
    final delay = delays[_bgRetryCount.clamp(0, delays.length - 1)];
    final q = List<Song>.from(_queue);
    final idx = _currentIndex;
    _bgRetryTimer = Timer(Duration(seconds: delay), () async {
      _bgRetryTimer = null;
      // Only heal a track that never started: still the same gen, still
      // current, silent at 0. Anything else is user intent or newer
      // playback â€” leave alone, but say so out loud.
      if (healGen != _playGen) {
        return;
      }
      if (!_stillCurrent(song.id, healGen)) {
        return;
      }
      if (_player.playing) {
        return;
      }
      // No global-failure bail here: heal advances with force=true, which
      // bypasses the global limit in playNext by design. Bailing would
      // deadlock recovery: failures increment while the heal is blocked by
      // the same counter, so only a foreground reset could recover.
      // The current song ended but the advance to the next failed in the
      // background (network restricted). A finished song is NOT audible —
      // only an actively-playing source is. Retry the ADVANCE, not a
      // replay. A silent-at-start song (never loaded) reloads in place.
      final finished = _processingState == ProcessingState.completed ||
          (_duration.inSeconds > 0 &&
              _position.inSeconds >= _duration.inSeconds - 1);
      _bgRetryCount++;
      try {
        if (finished) {
          // Per-song retry limit: after 3 retries on the SAME next song,
          // skip it and try the following one. Prevents infinite retry loop
          // on a permanently failing song (region-locked, removed, etc.)
          // while still allowing transient network issues to recover.
          final nextIdx = _currentIndex + 1;
          if (nextIdx < _queue.length) {
            final nextSongId = _queue[nextIdx].id;
            final retries = (_bgRetrySongCounts[nextSongId] ?? 0) + 1;
            if (_bgRetrySongCounts.length > 200) _bgRetrySongCounts.clear();
            _bgRetrySongCounts[nextSongId] = retries;
            if (retries > 3) {
              _bgRetrySongCounts.remove(nextSongId);
              // Skip this song by advancing from the next index
              await playNext(0, false, nextIdx + 1, true);
              return;
            }
          }
          // Retry the advance so the next song eventually loads when the
          // background network allows (or when the user foregrounds).
          await playNext(0, false, null, true);
          return;
        }
        // Preserve the queue's origin: a healed Quick Picks queue must
        // stay a never-ending queue, not degrade to generic autoplay.
        final keepOrigin = _queueOrigin;
        await playSong(song,
            queue: q.isNotEmpty ? q : null,
            index: q.isNotEmpty ? idx.clamp(0, q.length - 1) : null,
            autoplayOnEnd: _autoplayOnEnd,
            queueOrigin: keepOrigin);
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
    });
  }

  void _cancelBackgroundRetry([String reason = 'new load']) {
    if (_bgRetryTimer != null) {}
    _bgRetryTimer?.cancel();
    _bgRetryTimer = null;
  }

  /// Background wake-up for the "paused for offline" state. Bounded
  /// backoff (5s..2min); each firing re-checks connectivity and resumes the
  /// paused song when the network is back. Stops re-arming once not paused
  /// anymore. Needed because some ROMs/VPNs never emit a connectivity
  /// change, and the foreground heal only runs when the app is reopened.
  void _armOfflineResumeRetry() {
    // Cancel only the pending timer: the attempt counter must survive the
    // re-arm, otherwise every arm resets it to 0 and the backoff below can
    // never escalate (and the bail-out can never fire).
    _cancelOfflineResumeTimer();
    if (!_appBackgrounded) return;
    if (!_pausedForOffline) return;
    const delays = [5, 12, 25, 45, 60, 90, 120, 120, 120, 120];
    if (_offlineResumeAttempt >= delays.length) return;
    final delay = delays[_offlineResumeAttempt];
    _offlineResumeAttempt++;
    _offlineResumeTimer = Timer(Duration(seconds: delay), () {
      _offlineResumeTimer = null;
      if (!_pausedForOffline) return;
      unawaited(_onConnectivityMaybeChanged().whenComplete(() {
        // Still paused after the re-check (network not back yet): keep
        // trying on the next backoff step.
        if (_pausedForOffline) _armOfflineResumeRetry();
      }));
    });
  }

  void _cancelOfflineResumeTimer() {
    _offlineResumeTimer?.cancel();
    _offlineResumeTimer = null;
  }

  void _cancelOfflineResumeRetry([String reason = '']) {
    if (_offlineResumeTimer != null && reason.isNotEmpty) {}
    _cancelOfflineResumeTimer();
    _offlineResumeAttempt = 0;
  }

  /// When the current song is within [threshold] of its end, resolve and
  /// cache the next song so playNext can start instantly from file.
  void _maybePreloadNext(Duration position) {
    // Backoff retry already scheduled: this song is covered.
    if (_preloadRetryTimer != null) return;
    if (_currentSong == null) return;
    if (_queue.isEmpty || _currentIndex < 0) return;
    if (_player.processingState == ProcessingState.completed) return;
    if (_player.processingState == ProcessingState.idle) return;

    final dur = _duration;
    if (dur.inSeconds <= 0) return;

    // Only trigger when within threshold of the end. 45s gives a slow
    // connection a full minute to finish the download before completion.
    final remaining = dur - position;
    if (remaining > const Duration(seconds: 45)) return;
    if (remaining < Duration.zero) return;

    // Already cached? Skip preload.
    final next = _computeNextSong();
    if (next == null) {
      // At the end of a never-ending queue: grow the continuation now so
      // the next song (and its file) already exists when this one ends.
      _prepareContinuation();
      return;
    }
    // Handled this song already (cached hit or downloaded): matching on
    // the song alone stops the ~190ms tick re-trigger.
    if (_prefetchedSongIds.contains(next.id)) {
      return;
    }
    // Preload gave up on this song (offline / exhausted attempts): do not
    // re-attempt on every position tick. Cleared on connectivity regain
    // or on the song being downloaded.
    if (_preloadedBlockedSongIds.contains(next.id)) {
      return;
    }

    // Fire-and-forget by design: loads never await the preload future.
    // Drive the whole prefetch window, not just this one song.
    _scheduleEndPreload(position);
    _ensurePrefetch();
  }

  /// One-shot preload arm for the end-of-track window. Re-armed on every
  /// in-window position event, so a suppressed background position stream
  /// can never silently drop the next song's cache. Fires a few seconds
  /// before the real end while the track still plays (prefetch is skipped
  /// once processingState == completed).
  void _scheduleEndPreload(Duration position) {
    final dur = _duration;
    if (dur.inSeconds <= 0) return;
    final remaining = dur - position;
    if (remaining < Duration.zero) return;
    if (remaining > const Duration(seconds: 45)) return;
    _endPreloadTimer?.cancel();
    var wait = remaining - const Duration(seconds: 3);
    if (wait < Duration.zero) wait = Duration.zero;
    _endPreloadTimer = Timer(wait, () {
      _endPreloadTimer = null;
      if (_currentSong == null) return;
      if (_queue.isEmpty || _currentIndex < 0) return;
      _ensurePrefetch();
    });
  }

  void _cancelEndPreload() {
    _endPreloadTimer?.cancel();
    _endPreloadTimer = null;
  }

  /// On a genuine advance, stale prefetch-blocked memory (offline /
  /// gave-up) must not starve the NEW song: drop the block for the next
  /// queued song so preload re-attempts it. Re-blocking is cheap and only
  /// happens if the song is genuinely offline again.
  void _unblockPreloadAhead() {
    final i = _currentIndex + 1;
    if (i < 0 || i >= _queue.length) return;
    final s = _queue[i];
    if (_preloadedBlockedSongIds.remove(s.id)) {
      _ensurePrefetch();
    }
  }

  /// Background queue feeder: prefetch the next up-to-3 unhandled songs
  /// while the current one plays, starting with the nearest. Called at
  /// track start, in the end-of-track window, on connectivity regain, and
  /// after every preload terminal state (which chains to the following
  /// song). Fires up to 3 parallel preloads so the window is warm before
  /// the app backgrounds â€” avoids the "next song not cached" gap.
  void _ensurePrefetch() {
    if (_currentSong == null) return;
    if (_queue.isEmpty || _currentIndex < 0) return;
    if (_player.processingState == ProcessingState.completed) return;
    if (_player.processingState == ProcessingState.idle) return;
    int started = 0;
    for (var step = 1; step <= 3 && started < 3; step++) {
      final i = _currentIndex + step;
      if (i >= _queue.length) break;
      final s = _queue[i];
      if (_prefetchedSongIds.contains(s.id)) continue;
      if (_preloadedBlockedSongIds.contains(s.id)) continue;
      if (_preloadingSongIds.contains(s.id)) continue;
      unawaited(_preloadNextSong(s));
      started++;
    }
  }

  /// Determine which song would play next, respecting shuffle/loop.
  Song? _computeNextSong() {
    if (_playNextOverride != null) return _playNextOverride;
    if (_queue.isEmpty || _currentIndex < 0) return null;
    if (_shuffle &&
        _queue.length > 1 &&
        _queueOrigin != 'search' &&
        _queueOrigin != 'searchRadio') {
      int next;
      do {
        next = _random.nextInt(_queue.length);
      } while (next == _currentIndex);
      return _queue[next];
    }
    if (_currentIndex < _queue.length - 1) return _queue[_currentIndex + 1];
    if (_loopMode == LoopMode.all) return _queue.first;
    // Queue end and no repeat: will call _autoPlay, can't predict.
    return null;
  }

  /// Resolve and cache a single song without touching the player or
  /// any playback state. Fire-and-forget. Bounded by timeout, and the
  /// in-flight flag is always released in finally so one stuck preload
  /// can never wedge every future preload (or starve a load).
  /// Loads never await this future: they read the cache directly, so a
  /// hung preload cannot deadlock a track advance.
  /// Retry policy: NO tight re-trigger loop — the ~190ms position ticks
  /// must not restart a failed preload. Instead:
  ///  - offline (and streaming disabled): blocked immediately, no retry
  ///    until connectivity actually returns (connectivity-changed stream),
  ///  - any other failure: exponential backoff 1s/2s/4s/8s/16s/30s...,
  ///    max 8 attempts (~2min coverage), then `preload gave up` + blocked.
  /// Every terminal state chains _ensurePrefetch so the window moves on
  /// to the following song instead of stalling on one hopeless one.
  Future<void> _preloadNextSong(Song song) async {
    if (_preloadingSongIds.contains(song.id)) {
      return;
    }
    _preloadingSongIds.add(song.id);
    final attemptGen = _playGen;
    if (_preloadAttemptSongId != song.id) {
      _preloadAttemptSongId = song.id;
      _preloadAttemptCount = 0;
    }
    var ok = false;
    try {
      ok = await _preloadNextSongInner(song)
          .timeout(const Duration(seconds: 120));
    } on TimeoutException catch (_) {
      // Timed out or failed late: the preload is abandoned this pass.
    } catch (_) {
      // Timed out or failed late: the preload is abandoned this pass.
    } finally {
      _preloadingSongIds.remove(song.id);
    }
    if (ok) {
      _preloadAttemptSongId = null;
      _preloadAttemptCount = 0;
      _prefetchedSongIds.add(song.id);
      _ensurePrefetch();
      return;
    }
    if (_preloadedBlockedSongIds.contains(song.id)) {
      // Nothing preload can do right now (offline, no local file). Wait
      // for the connectivity-changed stream; never spin. Move the window
      // on to the following song.
      _ensurePrefetch();
      return;
    }
    _schedulePreloadRetry(song, attemptGen);
  }

  /// Exponential backoff between preload attempts. Bounded: max 8
  /// attempts, then give up and block until connectivity changes (the
  /// window meanwhile moves on to the following song).
  void _schedulePreloadRetry(Song song, int gen) {
    _preloadAttemptCount++;
    if (_preloadAttemptCount >= 8) {
      _preloadedBlockedSongIds.add(song.id);
      _ensurePrefetch();
      return;
    }
    const delays = [1, 2, 4, 8, 16, 30, 30, 30, 30];
    final delay = delays[_preloadAttemptCount.clamp(0, delays.length - 1)];
    _preloadRetryTimer?.cancel();
    _preloadRetryTimer = Timer(Duration(seconds: delay), () {
      _preloadRetryTimer = null;
      if (gen != _playGen) {
        return;
      }
      if (_preloadedBlockedSongIds.contains(song.id)) return;
      unawaited(_preloadNextSong(song));
    });
  }

  void _cancelPreloadRetry([String reason = 'new load']) {
    if (_preloadRetryTimer != null) {}
    _preloadRetryTimer?.cancel();
    _preloadRetryTimer = null;
  }

  /// Returns true when the song is ready to play from cache. False =
  /// blocked (offline, set inside) or a failed attempt (caller retries
  /// with backoff).
  Future<bool> _preloadNextSongInner(Song song) async {
    // Already fully cached? Nothing to do. Record it so the window
    // stops re-triggering (the ~190ms tick loop).
    final cached = await _cache.getValid(song);
    if (cached != null) {
      _prefetchedSongIds.add(song.id);
      return true;
    }
    // No connectivity gate here: the _hasConnectivity() DNS/interface
    // probe false-negatives on working networks (custom DNS, VPN, captive
    // portal) and wrongly blocks next-song caching, forcing a resolve +
    // download at the transition. Let the REAL resolve attempt prove
    // connectivity; genuine offline songs fail resolve and fall into the
    // bounded backoff instead.
    final report = PlaybackReport(song.title, songId: song.videoId ?? song.id);
    final source = await _strategy.resolveFirstValid(song, report);
    if (source == null) {
      return false;
    }
    // Download into cache so playNext reads file instantly. Shared helper
    // retries with a fresh URL when the first attempt is rejected (too
    // small / truncated) as well as when it throws.
    try {
      await _downloadSource(source, song, report);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Clear preload state so the next preload cycle targets the right song.
  /// Handled-song memory is queue-position based, so a new load clears it;
  /// blocked-song memory survives (offline is still offline).
  void _clearPreloadState() {
    _prefetchedSongIds.clear();
    _preloadingSongIds.clear();
    _cancelPreloadRetry('preload state cleared');
    _cancelEndPreload();
    _cancelCompletionGuard();
  }

  /// Grow a never-ending queue BEFORE the current song ends: build the
  /// personalized continuation and append it, then preload the first new
  /// file. Touches only [_queue] â€” the player and current song are left
  /// alone, so playback never stutters. Fire-and-forget.
  Future<void> _prepareContinuation() async {
    if (_preparingContinuation) return;
    if (_currentSong == null) return;
    if (!_autoplayOnEnd) return;
    if (_queueOrigin != 'quickPicks' && _queueOrigin != 'continuation') {
      return;
    }
    // Failure cooldown: this runs on position ticks, so an empty/failed
    // build must not rebuild storage+network state on every ~190ms tick.
    final now = DateTime.now();
    final notBefore = _continuationNotBefore;
    if (notBefore != null && now.isBefore(notBefore)) return;
    _resyncIndex();
    if (_currentIndex < _queue.length - 1) return; // not at the end
    _preparingContinuation = true;
    final anchor = _currentSong!;
    final contGen = _playGen;
    try {
      final songs = await _buildContinuation(count: 10);
      // Gen check on the async continuation: a newer load owns the queue
      // now â€” never append to it.
      if (contGen != _playGen) {
        return;
      }
      if (songs.isEmpty) {
        _continuationNotBefore = now.add(const Duration(seconds: 30));
        return;
      }
      // User moved on while we worked: discard, fresh cycle owns it.
      if (_currentSong?.id != anchor.id) return;
      _resyncIndex();
      if (_currentIndex < _queue.length - 1) return;
      _queue = [..._queue, ...songs];
      _queueOrigin = 'continuation';
      _continuationNotBefore = null;
      notifyListeners();
      // Next song now known: resolve + cache its file immediately.
      unawaited(_preloadNextSong(songs.first).catchError((Object e) {}));
    } catch (_) {
      // Timed out or failed late: the preload is abandoned this pass.
      _continuationNotBefore = now.add(const Duration(seconds: 30));
    } finally {
      _preparingContinuation = false;
    }
  }

  /// Ranked personalized continuation from on-device behavior signals:
  /// session (strongest), meaningful listens/replays, likes, top
  /// artists/genres, selected prefs, and recent searches. Excludes
  /// everything already played in this queue. Never throws.
  Future<List<Song>> _buildContinuation({int count = 10}) async {
    try {
      final cur = _currentSong;
      if (cur == null) return const [];
      final recent = await _storage.getRecentlyPlayed();
      final stats = await _storage.getListeningStats();
      final topArtists = await _storage.getTopArtists(limit: 10);
      final liked = await _storage.getLikedSongs();
      final searches = await _storage.getSearchHistory();
      MusicLanguage lang = MusicLanguage.all;
      Set<String> selGenres = {};
      Set<String> selArtists = {};
      try {
        final prefs = UserPrefs();
        lang = await prefs.getLanguage();
        selGenres = await prefs.getGenres();
        selArtists = await prefs.getArtists();
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
      // Candidate queries follow the session first, long-term taste next.
      final queries = <String>[];
      if (cur.artist.isNotEmpty) queries.add('${cur.artist} album tracks');
      for (final s in recent.take(4)) {
        if (queries.length >= 4) break;
        if (s.artist.isNotEmpty &&
            s.artist.toLowerCase() != cur.artist.toLowerCase()) {
          queries.add('${s.artist} album tracks');
        }
      }
      for (final a in topArtists) {
        if (queries.length >= 5) break;
        if (a.toLowerCase() == cur.artist.toLowerCase()) continue;
        queries.add('$a album tracks');
      }
      for (final q in searches.take(2)) {
        if (queries.length >= 6) break;
        queries.add('$q official audio');
      }
      if (queries.isEmpty) queries.add('trending songs official audio');
      final pool = <Song>[];
      final seen = <String>{};
      final contGen = _playGen;
      await Future.wait(queries.take(6).map((q) async {
        try {
          final songs = await _youtubeService
              .search(q, limit: 10)
              .timeout(const Duration(seconds: 8));
          if (contGen != _playGen) {
            return;
          }
          for (final s in SongFilter.applyDiscovery(songs, language: lang)) {
            if (seen.add(s.videoId ?? s.id)) pool.add(s);
          }
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
      }));
      if (pool.isEmpty) return const [];
      final playedIds = <String>{
        ..._queue.map((s) => s.id),
        ..._queue.map((s) => s.videoId ?? s.id),
      };
      final sessionRecent = [
        cur,
        ...recent.where((s) => s.id != cur.id).take(4),
      ];
      final picks = QuickPicksEngine.rank(
        recent: sessionRecent,
        candidates: pool,
        stats: stats,
        topArtists: topArtists,
        topGenres: selGenres.toList(),
        likedIds: liked.map((s) => s.id).toSet(),
        queueIds: playedIds,
        userLanguage: lang,
        searchHistory: searches,
        selectedArtists: selArtists.toList(),
        count: count,
        seedHint: cur.id.hashCode,
      );
      return picks.map((p) => p.song).toList();
    } catch (e) {
      return const [];
    }
  }

  /// Queue-end for never-ending queues: play what the background prepare
  /// already appended, else build the continuation now and play it.
  /// Never stops, never pauses, never repeats the finished queue.
  Future<bool> _playContinuation() async {
    _resyncIndex();
    if (_currentIndex < _queue.length - 1) {
      final target = _queue[_currentIndex + 1];
      if (await _playWithRetry(target, _currentIndex + 1)) return true;
    }
    var songs = await _buildContinuation(count: 10);
    // Never strand playback: if the ranked pool came back empty (all
    // candidates were long-form/music videos/unknown length), fall back to
    // the user's own library, which needs no network.
    if (songs.isEmpty) {
      try {
        final liked = await _storage.getLikedSongs();
        final recent = await _storage.getRecentlyPlayed();
        final played = <String>{
          ..._queue.map((s) => s.id),
          ..._queue.map((s) => s.videoId ?? s.id),
        };
        songs = SongFilter.apply([...liked, ...recent])
            .where((s) =>
                !played.contains(s.id) && !played.contains(s.videoId ?? s.id))
            .toList();
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
    }
    if (songs.isEmpty) {
      _noteFailure('could not build continuation (radio end)');
      // Nothing to play: in background schedule the healer instead of
      // sitting paused â€” network may return before the user reopens.
      _scheduleBackgroundRetry();
      _retryQueueEnd();
      return false;
    }
    _resyncIndex();
    final base = _currentIndex + 1;
    _queue = [..._queue, ...songs];
    _queueOrigin = 'continuation';
    notifyListeners();
    final target = songs.first;
    if (await _playWithRetry(target, base)) return true;
    // Load failed after retries: heal in background, never sit paused.
    _scheduleBackgroundRetry();
    _retryQueueEnd();
    return false;
  }

  /// Commit a load to the active source. Called only after setAudioSource
  /// + play() succeed. This is the single place where committed playback
  /// state flips: UI intent becomes active ownership, position resets,
  /// and tracking starts. Until this runs, completion events still belong
  /// to the previous active song.
  void _commitSong(Song song, int gen) {
    if (_pendingIndex != null) {
      _currentIndex = _pendingIndex!;
      _pendingIndex = null;
    }
    _currentSong = song;
    _activeSongId = song.id;
    _activeGen = gen;
    _activeSince = DateTime.now();
    _position = Duration.zero;
    _lastNotifiedSecond = -1;
    _handlingCompletion = false;
    _cancelLoadWatchdog();
    _cancelQueueEndRetry();
    _cancelCompletionGuard();
    _completionGuardCount = 0;
    // Clear background heal retry count for the song that just started
    _bgRetrySongCounts.remove(song.id);
    // Clear completion guard retry count for the song that just started
    _completionGuardSongCounts.remove(song.id);
    // Reset global advance failures: a successful advance means recovery
    // is working.
    _globalAdvanceFailures = 0;
    _startTracking(song);
    // Real playback started: any offline pause is obsolete.
    if (_pausedForOffline) {
      _pausedForOffline = false;
    }
    _cancelOfflineResumeRetry('playing');
  }

  /// Arms the load watchdog for [gen]. Safety net only: every await in the
  /// load path is already bounded, so this fires solely for hangs no bound
  /// covers. It logs the stalled stage and restarts pre-download stalls
  /// exactly once. Every restart bumps the gen, so the stuck attempt goes
  /// stale and bails at its next boundary with a superseded log.
  /// Timeout (120s) exceeds the worst legitimate pre-download path
  /// (session 10s + pause 5s + connect 6s + resolve 75s). Download legs
  /// get re-armed, never restarted â€” a slow download is progress, and two
  /// concurrent downloads of one song would only waste radio.
  void _startLoadWatchdog(Song song, int gen,
      {List<Song>? queue,
      int? index,
      bool autoplayOnEnd = true,
      String? queueOrigin}) {
    _cancelLoadWatchdog();
    _loadStage = 'session';
    final queueCopy = queue == null ? null : List<Song>.from(queue);
    var arms = 0;
    void arm() {
      arms++;
      _loadWatchdog = Timer(const Duration(seconds: 120), () async {
        _loadWatchdog = null;
        if (gen != _playGen) {
          return;
        }
        if (_activeGen == gen) return;
        if (_loadStage == 'download' || _loadStage == 'setSource') {
          // Download legs can legitimately run past the 120s window
          // (150s download + 90s fallback). Re-arm rather than restart, but
          // evaluate the pre-increment value so a download gets more than
          // one extra window.
          if (arms <= 2) {
            arm();
          }
          return;
        }
        if (arms > 1) return;
        try {
          await playSong(song,
              queue: queueCopy,
              index: index,
              autoplayOnEnd: autoplayOnEnd,
              queueOrigin: queueOrigin);
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
      });
    }

    arm();
  }

  void _cancelLoadWatchdog({bool silent = false}) {
    if (_loadWatchdog != null && !silent) {}
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
  }

  void _finishPlaying() {
    _isLoading = false;
    _isPlaying = true;
    _bgRetryCount = 0;
    _bgRetrySince = null;
    _cancelBackgroundRetry('playing');
    notifyListeners();
    _startStallTimer();
    // Synchronous warmup: await first 2 songs' cache so background
    // playback survives immediate app-close. Subsequent songs fire async.
    _warmupPrefetch();
  }

  /// Blocking warmup for the next 2 songs. Called once per track start
  /// while the app is still foregrounded. Returns when cached or fails.
  Future<void> _warmupPrefetch() async {
    if (_currentSong == null || _queue.isEmpty || _currentIndex < 0) return;
    int count = 0;
    for (var step = 1; step <= 2 && count < 2; step++) {
      final i = _currentIndex + step;
      if (i >= _queue.length) break;
      final s = _queue[i];
      if (_prefetchedSongIds.contains(s.id)) {
        count++;
        continue;
      }
      if (_preloadedBlockedSongIds.contains(s.id)) continue;
      if (_preloadingSongIds.contains(s.id)) continue;
      // Register in-flight BEFORE awaiting: _ensurePrefetch (and concurrent
      // warmups) use this set as the dedup guard, so without it the same
      // song is downloaded twice at the moment bandwidth matters most.
      _preloadingSongIds.add(s.id);
      try {
        await _preloadNextSongInner(s).timeout(const Duration(seconds: 30));
        _prefetchedSongIds.add(s.id);
        count++;
      } catch (_) {
        // Ignore — async preload will retry later.
      } finally {
        _preloadingSongIds.remove(s.id);
      }
    }
    // Fire remaining async.
    _ensurePrefetch();
  }

  /// Pushes the current song/state to the media notification on every change.
  /// `audio_service` needs this to update the shade; without it the
  /// notification would freeze on the first track.
  @override
  void notifyListeners() {
    if (_disposed) return;
    AtlasAudioHandler.instance?.syncFromService();
    super.notifyListeners();
  }

  /// Background playback / notification tag builder. The media card is only
  /// populated from these fields, so a title/artist are always non-empty.
  audio.MediaItem mediaTagFor(Song song) {
    Uri? art;
    final videoId = song.videoId ?? song.id;
    // Notification artwork is separately center-cropped to a square. Keep
    // the original image for the in-app player so this never changes its art.
    final cachedArt =
        _notificationArtFileCache[videoId] ?? _artFileCache[videoId];
    if (cachedArt != null && cachedArt.isNotEmpty) {
      art = Uri.file(cachedArt);
    } else {
      final thumb = song.thumbnailUrl.trim();
      if (thumb.startsWith('http')) {
        try {
          art = Uri.parse(thumb);
        } catch (e) {
          art = null;
        }
      }
    }
    // YouTube's medium thumbnail is only 320x180, which the notification and
    // lock screen stretch and render blurry. Resolve a sharper one in the
    // background; when it lands the media item is re-broadcast with the file.
    _ensureArtwork(song);
    // The media card is only populated from these fields. A null title/artist
    // renders an empty card, and Android's shade then falls back to its
    // "No media playing" placeholder. Always carry a non-empty title and
    // artist so the current track is identifiable in the notification.
    final title =
        song.title.trim().isEmpty ? 'Unknown title' : song.title.trim();
    final channel = song.channel.trim();
    final artist = song.artist.trim().isNotEmpty
        ? song.artist.trim()
        : (channel.isNotEmpty ? channel : 'Atlas Music');
    return audio.MediaItem(
      id: song.videoId ?? song.id,
      title: title,
      artist: artist,
      album: channel.isNotEmpty ? channel : null,
      artUri: art,
      duration: song.duration == Duration.zero ? null : song.duration,
    );
  }

  // --- High-resolution cover art -------------------------------------------
  // videoId -> local file path of the best thumbnail found so far.
  final Map<String, String> _artFileCache = <String, String>{};
  final Map<String, String> _notificationArtFileCache = <String, String>{};
  final Set<String> _artResolving = <String>{};
  Directory? _artDir;

  /// Bounds the artwork maps, which otherwise grow one entry per distinct
  /// videoId ever played (hundreds per hour on a radio session).
  void _trimArtCache() {
    const cap = 300;
    if (_artFileCache.length <= cap) return;
    final drop = _artFileCache.keys.take(_artFileCache.length - cap).toList();
    for (final k in drop) {
      _artFileCache.remove(k);
      _notificationArtFileCache.remove(k);
    }
  }

  Future<Directory> _artworkDir() async {
    final existing = _artDir;
    if (existing != null) return existing;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/atlas_art');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _artDir = dir;
    return dir;
  }

  /// Resolves and caches the sharpest available cover for [song] once.
  /// Prefers an upscaled Google square (real album art), then YouTube's
  /// video stills (maxres/hq720 1280x720 -> sd 640x480 -> hq 480x360).
  void _ensureArtwork(Song song) {
    final videoId = (song.videoId ?? song.id).trim();
    if (videoId.isEmpty) return;
    if (_artFileCache.containsKey(videoId) || _artResolving.contains(videoId)) {
      return;
    }
    if (!_hasResolvableArt(song, videoId)) return;
    _artResolving.add(videoId);
    unawaited(_resolveArtwork(song, videoId));
  }

  /// True when [song] carries an image worth resolving: a Google/YouTube CDN
  /// URL, or an 11-char YouTube id whose stills can be tried. YouTube Music
  /// search returns square art from `*.googleusercontent.com`, so both CDNs
  /// must be accepted.
  static bool _hasResolvableArt(Song song, String videoId) {
    final thumb = song.thumbnailUrl.trim();
    if (thumb.contains('i.ytimg.com') ||
        thumb.contains('googleusercontent.com')) {
      return true;
    }
    return youTubeIdPattern.hasMatch(videoId);
  }

  /// YouTube video ids are exactly 11 URL-safe characters.
  static final RegExp youTubeIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// Google image URLs (`*.googleusercontent.com`) carry a size suffix such
  /// as "=w120-h120-l90-rj". Requesting a large square returns real album art
  /// (verified 1080x1080) where the search response only offered 120 px.
  static String? _upgradedGoogleImage(String url) {
    final eq = url.indexOf('=');
    if (eq <= 0) return null;
    final host = Uri.tryParse(url)?.host ?? '';
    if (!host.endsWith('googleusercontent.com')) return null;
    return '${url.substring(0, eq)}=w1080-h1080-l90-rj';
  }

  Future<void> _resolveArtwork(Song song, String videoId) async {
    try {
      final dir = await _artworkDir();
      // Version the path as well as validating dimensions: ImageCache keys
      // Image.file by path, so replacing a low-res file in place can keep its
      // previously-decoded blurry frame alive for the whole process.
      final file = File('${dir.path}/$videoId-hq.jpg');
      final legacyFile = File('${dir.path}/$videoId.jpg');
      if (await legacyFile.exists()) {
        try {
          await legacyFile.delete();
        } catch (_) {}
      }
      if (await file.exists() && await file.length() > 4096) {
        // Only trust a cache that can stay sharp in the full-screen player.
        final cached = await file.readAsBytes();
        final cachedW = _jpegWidth(cached) ?? 0;
        if (cachedW >= _minArtworkWidth) {
          _artFileCache[videoId] = file.path;
          _notificationArtFileCache[videoId] =
              await _notificationArtworkFile(file, videoId);
          _trimArtCache();
          AtlasAudioHandler.instance?.refreshMediaItem();
          // Let the in-app Player pick up the sharp file (it selects on
          // highResArtPathFor, which now returns this path).
          notifyListeners();
          return;
        }
      }
      // Best-first candidates: the upscaled Google square (a true album
      // cover), then the song's own URL, then YouTube's video stills
      // (maxres/hq720 1280x720 -> sd 640x480 -> hq 480x360).
      final candidates = <String>[];
      void add(String? u) {
        final t = u?.trim() ?? '';
        if (t.startsWith('http') && !candidates.contains(t)) candidates.add(t);
      }

      final thumb = song.thumbnailUrl.trim();
      add(_upgradedGoogleImage(thumb));
      add(thumb);
      if (youTubeIdPattern.hasMatch(videoId)) {
        for (final size in const [
          'maxresdefault',
          'hq720',
          'sddefault',
          'hqdefault',
        ]) {
          add('https://i.ytimg.com/vi/$videoId/$size.jpg');
        }
      }
      List<int>? fallbackBytes;
      var fallbackWidth = 0;
      for (final url in candidates) {
        try {
          final resp = await http
              .get(Uri.parse(url))
              .timeout(const Duration(seconds: 10));
          if (resp.statusCode != 200 || resp.bodyBytes.length <= 4096) {
            continue;
          }
          final w = _jpegWidth(resp.bodyBytes) ?? 0;
          // Reject tiny placeholders; keep the best acceptable fallback in
          // case none of the endpoints provide full-screen resolution.
          if (w < _fallbackArtworkWidth) {
            continue;
          }
          if (w < _minArtworkWidth) {
            if (w > fallbackWidth) {
              fallbackWidth = w;
              fallbackBytes = resp.bodyBytes;
            }
            continue;
          }
          await file.writeAsBytes(resp.bodyBytes, flush: true);
          _artFileCache[videoId] = file.path;
          _notificationArtFileCache[videoId] =
              await _notificationArtworkFile(file, videoId);
          _trimArtCache();
          AtlasAudioHandler.instance?.refreshMediaItem();
          notifyListeners();
          return;
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
      }
      if (fallbackBytes != null) {
        await file.writeAsBytes(fallbackBytes, flush: true);
        _artFileCache[videoId] = file.path;
        _notificationArtFileCache[videoId] =
            await _notificationArtworkFile(file, videoId);
        _trimArtCache();
        AtlasAudioHandler.instance?.refreshMediaItem();
        notifyListeners();
        return;
      }
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
    } finally {
      _artResolving.remove(videoId);
    }
  }

  /// Makes a center-cropped square for Android's notification and lock screen.
  /// Cropping uses source pixels (no enlargement); the in-app artwork keeps
  /// the untouched original image. Square album covers are reused as-is.
  Future<String> _notificationArtworkFile(File original, String videoId) async {
    final directory = await _artworkDir();
    final output = File('${directory.path}/$videoId-notification.png');
    if (await output.exists() && await output.length() > 4096) {
      return output.path;
    }

    ui.Codec? codec;
    ui.Image? source;
    ui.Picture? picture;
    ui.Image? cropped;
    try {
      codec = await ui.instantiateImageCodec(await original.readAsBytes());
      source = (await codec.getNextFrame()).image;
      final side = min(source.width, source.height).toInt();
      if (source.width == side && source.height == side) return original.path;

      final left = (source.width - side) / 2;
      final top = (source.height - side) / 2;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(left, top, side.toDouble(), side.toDouble()),
        ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      picture = recorder.endRecording();
      cropped = await picture.toImage(side, side);
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return original.path;
      await output.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return output.path;
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
      // A crop failure must never interrupt playback or remove notification art.
      return original.path;
    } finally {
      cropped?.dispose();
      picture?.dispose();
      source?.dispose();
      codec?.dispose();
    }
  }

  /// Target width for full-screen artwork. Older caches at 480-640px looked
  /// soft when stretched over a high-density player slot.
  static const int _minArtworkWidth = 900;
  static const int _fallbackArtworkWidth = 480;

  /// Reads the pixel width from a JPEG's SOF marker without decoding it.
  /// Returns null when [bytes] isn't a parseable JPEG.
  static int? _jpegWidth(List<int> bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    var i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      // Standalone markers carry no length field.
      if (marker == 0xD8 ||
          marker == 0xD9 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      if (i + 3 >= bytes.length) break;
      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      if (len < 2) break;
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 8 >= bytes.length) break;
        // SOF layout: len(2) precision(1) height(2) width(2) ...
        return (bytes[i + 7] << 8) | bytes[i + 8];
      }
      i += 2 + len;
    }
    return null;
  }


  /// Online gate. Fast path: connectivity_plus confirms network interface
  /// is up (no DNS needed). Slow path: DNS lookup when connectivity_plus
  /// reports none (known false-negative on VPNs/custom DNS setups).
  Future<bool> _hasConnectivity() async {
    // 1. Fast path: is a recognized network interface up?
    try {
      final results = await Connectivity().checkConnectivity();
      final connected = results.any((r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn);
      if (connected) return true;
    } catch (_) {}
    // 2. Slow path: connectivity_plus may report none on VPNs or custom
    // network setups even when internet works. DNS is the real proof.
    const hosts = ['google.com', 'youtube.com', 'youtu.be'];
    final errors = <String>[];
    for (final h in hosts) {
      try {
        final result =
            await InternetAddress.lookup(h).timeout(const Duration(seconds: 2));
        if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
          return true;
        }
      } catch (e) {
        errors.add('$h: $e');
      }
    }
    return false;
  }

  /// Records a confirmed offline_no_cache gate: the song enters the
  /// known-unavailable map (first-confirmation time wins) and its gate
  /// count grows. The SECOND gate of the same song while still offline
  /// means we are lapping the queue â€” enter degraded mode so further
  /// laps skip the host lookup entirely instead of DNS-storming.
  void _recordOfflineGate(Song song) {
    _offlineKnownUnavailable[song.id] ??= DateTime.now();
    final count = (_offlineGateCounts[song.id] ?? 0) + 1;
    _offlineGateCounts[song.id] = count;
    if (count >= 2 && !_degradedOffline) {
      _degradedOffline = true;
      notifyListeners();
    }
  }

  /// Resets the whole offline session (new queue, stop, connectivity
  /// regain handled separately for its own exit log). Logs the degraded
  /// exit only when degraded was actually on.
  void _resetOfflineSession(String reason) {
    _offlineKnownUnavailable.clear();
    _offlineGateCounts.clear();
    if (_degradedOffline) {
      _degradedOffline = false;
      notifyListeners();
    }
  }

  /// Shared tail of both offline paths (fresh gate and degraded fast
  /// path): skip to a cached track via normal load, OR try the next
  /// uncached song if we might be online. Only pauses when truly
  /// nothing ahead is playable. [revertPending] is the owning load's
  /// closure â€” passed in because this runs outside playSong's body.
  Future<bool> _skipOrWaitOffline(
      Song song, int gen, int base, void Function() revertPending) async {
    // (a) Skip to a cached track. Bounded: one cache-check pass.
    final skipIndex = await _findNextCachedIndex(base, song.id);
    if (skipIndex != null) {
      final target = _queue[skipIndex];
      revertPending();
      _isLoading = false;
      notifyListeners();
      unawaited(playSong(target,
              index: skipIndex,
              autoplayOnEnd: _autoplayOnEnd,
              queueOrigin: _queueOrigin)
          .then((_) {}, onError: (Object e) {}));
      return true;
    }
    // (b) No cached songs ahead. If NOT in degraded mode, try the
    // next uncached song in forward order — it might load even if
    // this one didn't. Only pause if at queue end or degraded.
    // Global failure limit: stop burning through the queue when every
    // song is unresolvable (network/ provider down).
    if (!_degradedOffline &&
        _globalAdvanceFailures < _maxGlobalAdvanceFailures) {
      for (var i = base + 1; i < _queue.length; i++) {
        final target = _queue[i];
        if (target.id == song.id) continue;
        revertPending();
        _isLoading = false;
        _globalAdvanceFailures++;
        notifyListeners();
        unawaited(playSong(target,
                index: i,
                autoplayOnEnd: _autoplayOnEnd,
                queueOrigin: _queueOrigin)
            .then((_) {}, onError: (Object e) {}));
        return true;
      }
    }
    // (c) Nothing ahead playable (queue end or degraded). Before silencing
    // the app, replay any cached track (wrapping to earlier ones) so music
    // keeps going while the resolver/network recovers. Silence is the worst
    // outcome; a repeat is recoverable by the user. Pause only when nothing
    // at all is cached.
    final fallback = await _findAnyCachedIndex(base, song.id);
    if (fallback != null) {
      final target = _queue[fallback];
      revertPending();
      _isLoading = false;
      _globalAdvanceFailures = 0;
      notifyListeners();
      unawaited(playSong(target,
              index: fallback,
              autoplayOnEnd: _autoplayOnEnd,
              queueOrigin: _queueOrigin)
          .then((_) {}, onError: (Object e) {}));
      return true;
    }
    // Nothing cached at all (truly offline, empty cache): pause.
    _pausedForOffline = true;
    _pausedForOfflineSongId = song.id;
    _pausedForOfflineIndex = base;
    _pausedForOfflineGen = _playGen;
    _isLoading = false;
    _position = Duration.zero;
    _duration = song.duration;
    _lastNotifiedSecond = -1;
    try {
      if (_player.playing) {
        await _player.pause().timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // Player command is best-effort; state re-syncs from the stream.
    }
    _cancelLoadWatchdog();
    notifyListeners();
    // Self-heal in the background: don't wait for a connectivity event
    // (or the user reopening the app) that may never arrive.
    _armOfflineResumeRetry();
    return false;
  }

  /// Cache keys that cap eviction must never delete: the whole active
  /// queue plus the current song. Passed to every commit so a download
  /// landing mid-playback cannot evict an upcoming queued track.
  Set<String> _protectedCacheKeys() => {
        ..._queue.map(_cache.keyFor),
        if (_currentSong != null) _cache.keyFor(_currentSong!),
      };

  /// Candidate search for skip-unavailable. The candidate set is EVERY
  /// queued song with a valid local file, excluding ONLY the song being
  /// skipped â€” earlier songs and the just-completed song are candidates.
  /// Choice rule: first cached song in circular queue order starting
  /// immediately AFTER the unavailable one. That resumes forward
  /// progress whenever anything is cached ahead, otherwise wraps to the
  /// earliest cached song; every cached song stays reachable, none is
  /// skipped forever. Null = nothing playable: caller waits.
  Future<int?> _findNextCachedIndex(int fromIndex, String skipSongId) async {
    if (_queue.isEmpty) return null;
    final n = _queue.length;

    Future<bool> hasFile(Song s) async {
      try {
        return await _cache.getValid(s) != null;
      } catch (e) {
        return false;
      }
    }

    final cachedIdx = <int>[];
    for (var i = 0; i < n; i++) {
      final s = _queue[i];
      if (s.id == skipSongId) continue;
      // Only forward positions can be chosen below, so probing earlier
      // songs is wasted filesystem work.
      if (i <= fromIndex) continue;
      if (await hasFile(s)) {
        cachedIdx.add(i);
      }
    }
    if (cachedIdx.isEmpty) {
      return null;
    }
    // Only look FORWARD from the unavailable song. Never wrap around to
    // already-played songs. If nothing cached ahead, return null so the
    // caller pauses instead of replaying old tracks.
    return cachedIdx.first;
  }

  /// Last-resort cache search that WRAPS: any queued song with a valid
  /// local file, circular order, preferring forward from [fromIndex].
  /// Used only before silencing playback so a resolver outage still leaves
  /// audible music. Null = no cached song at all.
  Future<int?> _findAnyCachedIndex(int fromIndex, String skipSongId) async {
    if (_queue.isEmpty) return null;
    final n = _queue.length;
    Future<bool> hasFile(Song s) async {
      try {
        return await _cache.getValid(s) != null;
      } catch (e) {
        return false;
      }
    }

    final start = fromIndex % n;
    final candidates = <String>[];
    for (var step = 1; step <= n; step++) {
      final i = (start + step) % n;
      final s = _queue[i];
      if (s.id == skipSongId) continue;
      if (await hasFile(s)) {
        candidates.add(s.id);
        return i;
      }
    }
    return null;
  }

  /// Connectivity-changed trigger (no polling): re-checks real
  /// connectivity, unblocks preload, and resumes a queue paused for
  /// offline. Resume uses a fresh gen via playSong; the gate only checks
  /// that the user has not navigated away since the pause (any later
  /// load bumps the gen, which invalidates the captured pause gen).
  Future<void> _onConnectivityMaybeChanged() async {
    // Don't gate on _hasConnectivity() â€” it can false-negative on VPNs/
    /// custom DNS. Let the resume attempt prove connectivity.
    // The offline episode is over: known-unavailable memory is stale.
    // Reset BEFORE any resume so the resume's own gate re-searches and
    // retries fresh. Never yanks mid-playback: when a fallback track is
    // playing (not waiting), _pausedForOffline is false and nothing below
    // touches the player.
    if (_offlineKnownUnavailable.isNotEmpty || _offlineGateCounts.isNotEmpty) {
      _offlineKnownUnavailable.clear();
      _offlineGateCounts.clear();
    }
    // Connectivity returned: reset global advance failures so the next
    // advance gets a fresh budget.
    _globalAdvanceFailures = 0;
    if (_degradedOffline) {
      _degradedOffline = false;
      notifyListeners();
    }
    if (_preloadedBlockedSongIds.isNotEmpty) {
      _preloadedBlockedSongIds.clear();
      _preloadAttemptSongId = null;
      _preloadAttemptCount = 0;
      _ensurePrefetch();
    }
    if (_pausedForOffline && _pausedForOfflineGen == _playGen) {
      final idx = _pausedForOfflineIndex;
      final inRange =
          idx != null && _queue.isNotEmpty && idx >= 0 && idx < _queue.length;
      final song = inRange ? _queue[idx] : null;
      _pausedForOffline = false;
      if (song == null) {
        return;
      }
      try {
        await playSong(song,
            index: idx,
            autoplayOnEnd: _autoplayOnEnd,
            queueOrigin: _queueOrigin);
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
    }
  }

  Future<void> _playFile(
      String path, Song song, bool Function() stale, int gen) async {
    // If the SAME song is already playing past 5 s, absorb this load.
    if (_currentSong?.id == song.id &&
        _player.playing &&
        _position.inSeconds > 5) {
      return;
    }
    // Reset pos/dur BEFORE setAudioSource so no downstream event ever reads
    // the previous track's time for this one.
    _position = Duration.zero;
    _duration = Duration.zero;
    _lastNotifiedSecond = -1;
    try {
      await _player
          .setAudioSource(AudioSource.file(path, tag: mediaTagFor(song)))
          .timeout(const Duration(seconds: 30));
      _loadStage = 'setSource';
    } catch (e) {
      rethrow;
    }
    if (stale()) {
      throw StateError('superseded during setAudioSource');
    }
    // Preview/truncation guard for cached files: a short or bad download
    // must not start and then stop seconds in, looking like a skip. The
    // commit size check already rejects
    // gross truncation; this catches a file whose container duration is far
    // shorter than the song's known length.
    Duration? actual = _player.duration;
    if (actual == null || actual == Duration.zero) {
      actual = await _player.durationStream
          .firstWhere((d) => d != null && d > Duration.zero, orElse: () => null)
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
    }
    final expectedSec = song.duration.inSeconds;
    if (actual != null && actual.inSeconds > 0) {
      final tooShort = expectedSec > 0
          ? actual.inSeconds < (expectedSec * 0.6)
          : actual.inSeconds < 60;
      if (tooShort) {
        throw StateError('preview/short file '
            '(${actual.inSeconds}s vs ${expectedSec}s) rejected');
      }
    }
    // just_audio's play() future completes when playback STOPS, not when
    // it starts â€” never await it to confirm start. Fire it, derive "is
    // playing" from playerStateStream, and treat a slow/missing ack as
    // nothing. Awaiting it caused the exact-15s "play ack late" stall.
    unawaited(_player.play().then((_) {
      if (stale()) {
        return;
      }
    }).catchError((Object e) {
      if (stale()) {
        return;
      }
    }));
  }

  /// Downloads an already-resolved [source] into the cache and returns the
  /// verified file. Uses the source's own provider first (no second
  /// manifest fetch); falls back to a fresh provider chain. The commit
  /// size check rejects truncated/preview files. Throws on failure.
  ///
  /// A rejected first attempt (tiny/truncated body from a throttled itag)
  /// also triggers the fresh chain: without that, "download too small"
  /// surfaced as a hard failure instead of trying another URL. Fresh
  /// manifest resolutions give a new URL, hence a new throttle counter.
  Future<File> _downloadSource(
      MediaSource source, Song song, PlaybackReport report) async {
    final tmp = await _cache.stageFile(song);

    Future<File> commitWith(MediaSource src) async {
      await _youTube.download(src, tmp).timeout(const Duration(seconds: 150));
      return _cache.commit(song, tmp, src, keepKeys: _protectedCacheKeys());
    }

    Future<File> freshChain() async {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Timed out or failed late: the preload is abandoned this pass.
      }
      final fresh = await _strategy.downloadFirstValid(
        song,
        tmp,
        report,
        budget: const Duration(seconds: 90),
      );
      if (fresh == null) throw StateError('no downloadable source');
      return _cache.commit(song, tmp, fresh, keepKeys: _protectedCacheKeys());
    }

    try {
      return await commitWith(source);
    } catch (e) {
      try {
        return await freshChain();
      } catch (e2) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
        rethrow;
      }
    }
  }

  /// If ExoPlayer reports playing but no audio position advances,
  /// the stream is stalled. Skip ahead instead of sitting silent.
  /// The baseline is captured only here — the position stream must not
  /// overwrite it or cancel the timer every tick. Early playback (<10s or
  /// unknown duration) re-schedules instead of disabling the watchdog.
  void _startStallTimer() {
    _cancelStallTimer();
    _lastStallPosition = _position;
    if (_duration.inSeconds == 0 || _position < const Duration(seconds: 10)) {
      // Initial buffering grace window. Short enough to catch a stream that
      // never starts, long enough not to judge a slow first buffer.
      _stallTimer = Timer(const Duration(seconds: 25), () {
        if (!_isPlaying) return;
        // Re-evaluate once playback has progressed; never judge a stall
        // during initial buffering.
        _startStallTimer();
      });
      return;
    }
    _stallTimer = Timer(const Duration(seconds: 25), () {
      // A stream stuck in buffering/loading is a stall too (no audio, no
      // advancement) — do NOT bail on it forever, or "music not playing"
      // persists indefinitely. Only an idle/paused player is skipped.
      if (!_isPlaying || _processingState == ProcessingState.idle) {
        _startStallTimer();
        return;
      }
      final advanced =
          _position > _lastStallPosition + const Duration(seconds: 1);
      if (!advanced) {
        _recoverStall();
      } else {
        // Still advancing: keep watching with a fresh baseline.
        _stallCount = 0;
        _stallSongId = null;
        _startStallTimer();
      }
    });
  }

  /// First stalled window: the cause is usually transient (background
  /// throttling, brief network dip) and the NEXT song would stall too â€”
  /// so nudge the current track (re-activate session, seek, resume)
  /// instead of skipping. Second consecutive window: skip ahead â€” but
  /// ONLY in foreground. Background position telemetry arrives late, so
  /// a "stall" there is usually a stale reading, not dead audio: nudge
  /// again, never skip. Only genuine completion or explicit user skip
  /// advances the queue.
  void _recoverStall() {
    final cur = _currentSong;
    if (cur == null) return;
    if (_stallSongId == cur.id) {
      _stallCount++;
    } else {
      _stallSongId = cur.id;
      _stallCount = 1;
    }
    if (_stallCount >= 2 && !_appBackgrounded) {
      _stallCount = 0;
      _stallSongId = null;
      playNext();
      return;
    }
    if (_appBackgrounded) {
      // Reset the counter so background nudges never accumulate into a
      // skip; each window is judged on its own.
      _stallCount = 0;
      _stallSongId = null;
    }
    // Ownership snapshot: this nudge belongs to the current song only.
    // A user tap that lands while the nudge is queued must win â€” the
    // nudge aborts instead of seeking/playing the new song's source.
    final nudgeGen = _playGen;
    final nudgeId = cur.id;
    Future.microtask(() async {
      try {
        if (!_stillCurrent(nudgeId, nudgeGen)) {
          return;
        }
        await _activateSession();
        if (!_stillCurrent(nudgeId, nudgeGen)) return;
        // Foreground position is live so re-seeking is safe. Background
        // position can be stale â€” seeking to it would jump the track
        // backwards, so just resume in place.
        if (!_appBackgrounded) {
          try {
            await _player.seek(_position).timeout(const Duration(seconds: 10));
          } catch (_) {
            // Player command is best-effort; state re-syncs from the stream.
          }
          if (!_stillCurrent(nudgeId, nudgeGen)) {
            return;
          }
        }
        if (!_stillCurrent(nudgeId, nudgeGen)) {
          return;
        }
        // play() completes when playback STOPS: never await it here, or
        // the await can hang ~20s and stall the watchdog chain.
        unawaited(_player.play().then((_) {
          if (!_stillCurrent(nudgeId, nudgeGen)) {}
        }).catchError((Object e) {
          try {
            syncPlaybackState();
          } catch (_) {
            // Non-fatal: the surrounding watchdog covers this path.
          }
        }));
      } finally {
        // Reschedule only if still ours: a superseded nudge must not
        // revive a second watchdog over the new song's own timer.
        if (_stillCurrent(nudgeId, nudgeGen)) _startStallTimer();
      }
    });
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// Heals [_currentIndex] only on real drift. Trusts the committed index
  /// when it already points at the committed song (duplicates exist, so
  /// blind first-match search would rewind 1->3 style jumps).
  void _resyncIndex() {
    final cur = _currentSong;
    if (cur == null || _queue.isEmpty) return;
    if (_currentIndex >= 0 &&
        _currentIndex < _queue.length &&
        _queue[_currentIndex].id == cur.id) {
      return;
    }
    final at = _queue.indexWhere((s) => s.id == cur.id);
    if (at != -1) _currentIndex = at;
  }

  /// Loads [target] with bounded same-song retries on transient failures
  /// (network/timeout/offline). One background blip would otherwise burn
  /// through the rest of the queue — every later song fails identically —
  /// and strand playback paused on the wrong song. Permanent format
  /// failures return false immediately so the caller can skip ahead.
  Future<bool> _playWithRetry(Song target, int index) async {
    int tries = 0;
    while (true) {
      // Root: detect supersede by generation, not by _currentSong identity.
      // _currentSong is UI intent (reverted on failure), so identity can't
      // tell failure apart from a newer tap. Generation can.
      final beforeGen = _playGen;
      bool ok;
      try {
        ok = await playSong(target, index: index);
      } catch (e) {
        ok = false;
      }
      if (ok) return true;
      // A newer load started during our attempt: it owns audio now.
      if (_playGen != beforeGen + 1) {
        return true;
      }
      // Queue paused for offline: retrying the same unavailable song is
      // pointless â€” the offline pause owns recovery.
      if (_pausedForOffline) {
        return false;
      }
      final maxTries = _appBackgrounded ? 3 : 2;
      if (!_lastLoadWasTransient || tries >= maxTries) return false;
      tries++;
      await Future.delayed(Duration(
          seconds: _appBackgrounded
              ? (tries == 1
                  ? 4
                  : tries == 2
                      ? 10
                      : 20)
              : (tries == 1 ? 2 : 5)));
      if (_playGen != beforeGen + 1) {
        return true;
      }
    }
  }

  /// Returns true when a new song actually started. UI shows a toast
  /// on false so a failed skip is never silent.
  /// Single-flight: only one advance chain runs at a time. Concurrent
  /// triggers collapse instead of advancing twice (the random skip).
  /// [userInitiated] steals ownership from an in-flight automatic chain.
  Future<bool> playNext(
      [int depth = 0,
      bool userInitiated = false,
      int? fromIndex,
      bool force = false]) async {
    // Root: no settle delay. The delay only widened the window where a
    // stale completed could land mid-load. Ownership is via gen/active.
    // Debounce only user taps; automatic advances must never be dropped.
    if (depth == 0 && userInitiated && !_skipGuard()) return true;
    // Global advance failure limit: after too many consecutive failures
    // across all songs, stop automatic advances. User taps bypass this
    // (they explicitly want to play something). Reset on new queue or
    // connectivity change.
    if (depth == 0 &&
        !userInitiated &&
        !force &&
        _globalAdvanceFailures >= _maxGlobalAdvanceFailures) {
      return false;
    }
    if (depth == 0) {
      // [force] (genuine song completion) is a hard guarantee: a stuck
      // advance flag must never swallow it into a silent no-op, leaving
      // the player idle on a finished song until the user clicks play.
      if (_advancing && !userInitiated && !force) {
        return true;
      }
      // Two automatic triggers for the SAME generation (e.g. a completion
      // racing an app-foreground) would otherwise both run a full
      // resolve+download for the same next song. force still collapses
      // here only when it is a duplicate for the generation already
      // advancing; a new generation's force always proceeds.
      if (_advancing && !userInitiated && force && _advancingGen == _playGen) {
        return true;
      }
      _advancing = true;
      _advancingGen = _playGen;
    }
    try {
      _resyncIndex();
      if (depth > _queue.length + 1) return await _playQueueEnd();
      // Base for next calculation: explicit skip-ahead base wins, then
      // pending load during rapid taps, otherwise committed index. The
      // explicit base matters: after a genuine failure _currentSong is
      // reverted to the previous song, so _resyncIndex points _currentIndex
      // back at it â€” without fromIndex the recursion would retry the SAME
      // failed song (full retry delays each lap) instead of walking
      // forward past it.
      // Self-heal + witness: with no explicit base and no pending load,
      // the committed index MUST point at the playing song. A drifted
      // base advances from the wrong song (e.g. 3->1 instead of 3->4),
      // so re-derive it from the current song and log the correction.
      if (fromIndex == null &&
          _pendingIndex == null &&
          _currentSong != null &&
          _queue.isNotEmpty &&
          (_currentIndex < 0 ||
              _currentIndex >= _queue.length ||
              _queue[_currentIndex].id != _currentSong!.id)) {
        final at = _queue.indexWhere((s) => s.id == _currentSong!.id);
        if (at != -1) _currentIndex = at;
      }
      final baseIndex = fromIndex ?? _pendingIndex ?? _currentIndex;
      // Explicit "Play next" wins over shuffle, loop and queue-end growth.
      // fromIndex==null covers both genuine completion and the Next button;
      // failure paths pass an explicit index and must not re-take it.
      final override = _playNextOverride;
      if (override != null &&
          fromIndex == null &&
          _queue.isNotEmpty &&
          _currentIndex >= 0) {
        _playNextOverride = null;
        final oIdx = _queue.indexWhere((s) => s.id == override.id);
        if (await _playWithRetry(override, oIdx >= 0 ? oIdx : baseIndex)) {
          return true;
        }
        // Failed after retries: fall through to the normal advance.
      }
      int? nextIndex;
      if (_shuffle &&
          _queue.length > 1 &&
          _queueOrigin != 'search' &&
          _queueOrigin != 'searchRadio') {
        // Random track other than the current one.
        do {
          nextIndex = _random.nextInt(_queue.length);
        } while (nextIndex == baseIndex);
      } else if (baseIndex < _queue.length - 1) {
        nextIndex = baseIndex + 1;
      } else if (_loopMode == LoopMode.all && _queue.isNotEmpty) {
        nextIndex = 0; // repeat-all wraps to queue start.
      }
      if (nextIndex != null) {
        final target = _queue[nextIndex];
        _unblockPreloadAhead();
        if (await _playWithRetry(target, nextIndex)) {
          return true;
        }
        // _playWithRetry returns true on supersede, false only on genuine
        // failure. Skip ahead instead of getting stuck â€” but never while
        // paused for offline: every queued song fails identically, and
        // the offline pause owns recovery.
        if (_pausedForOffline) {
          return false;
        }
        // ANY failure (transient or permanent): stop the cascade. The
        // completion guard and background heal will retry the SAME song
        // with backoff. This prevents the 16-resolve DNS storm that
        // occurs when one advance fails, and guarantees gentle retry
        // instead of hammering the resolver.
        _currentIndex = nextIndex;
        _globalAdvanceFailures++;
        return false;
      }
      // End of queue with no repeat-all: online, the queue-end policy
      // below grows autoplay content. Offline it cannot fetch anything,
      // so playback would stop dead at the end of the queue. Wrap to the
      // first cached song instead (infinite offline loop). Online path
      // and loop settings are untouched.
      if (_loopMode != LoopMode.all && await _hasConnectivity() == false) {
        final wrapIdx = await _findNextCachedIndex(-1, '');
        if (wrapIdx != null) {
          final wrapTarget = _queue[wrapIdx];
          if (await _playWithRetry(wrapTarget, wrapIdx)) {
            return true;
          }
        }
      }
      return await _playQueueEnd();
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
      // Never crash from background queue advancement.
      return false;
    } finally {
      if (depth == 0) _advancing = false;
    }
  }

  /// Queue-end policy: never-ending queues (Quick Picks + their
  /// continuations) grow personalized continuations; search queues grow
  /// seed-based radio; playlists/albums/popular fetch related autoplay
  /// content.
  Future<bool> _playQueueEnd() async {
    if (_queueOrigin == 'quickPicks' || _queueOrigin == 'continuation') {
      return await _playContinuation();
    }
    if (_queueOrigin == 'search' || _queueOrigin == 'searchRadio') {
      return await _playSeedRadio();
    }
    if (!_autoplayOnEnd) {
      _isLoading = false;
      notifyListeners();
      return false;
    }
    return await _autoPlay();
  }

  /// Foreground-safe retry for a failed/empty queue-end build. Re-invokes
  /// [_playQueueEnd] after a short backoff so a transient network blip
  /// heals itself instead of stranding playback paused at the end of a
  /// never-ending queue. Bounded (4 attempts), then gives up and stays
  /// paused until a real connectivity change. Never replays the finished
  /// song: the retry re-runs only the queue-end growth (radio /
  /// continuation / autoplay), and it bails if a new source starts or the
  /// generation advances.
  void _retryQueueEnd() {
    _queueEndRetryTimer?.cancel();
    final attempt = _queueEndAttempt + 1;
    if (attempt > 4) {
      _queueEndAttempt = 0;
      return;
    }
    _queueEndAttempt = attempt;
    final retryGen = _playGen;
    _queueEndRetryTimer = Timer(Duration(seconds: attempt == 1 ? 2 : 4), () {
      _queueEndRetryTimer = null;
      if (_currentSong == null) return;
      if (_player.playing) return; // a new source owns playback
      if (_pausedForOffline) return; // offline pause owns recovery
      if (retryGen != _playGen) return; // newer load superseded
      unawaited(_playQueueEnd().then((_) {}, onError: (Object e) {}));
    });
  }

  void _cancelQueueEndRetry() {
    _queueEndRetryTimer?.cancel();
    _queueEndRetryTimer = null;
    _queueEndAttempt = 0;
  }

  /// Arms the completion safety net: if the player is still silent at
  /// `completed` after a short grace period and nothing is progressing,
  /// force an advance. Catches any path where the normal completion
  /// handler failed to start the next load, so the user is never left
  /// staring at a paused player that needs a manual tap.
  void _scheduleCompletionGuard() {
    _completionGuard?.cancel();
    final guardGen = _playGen;
    _completionGuard = Timer(const Duration(seconds: 3), () {
      _completionGuard = null;
      if (guardGen != _playGen) return; // newer load owns playback
      if (_player.playing) return; // audio actually started
      if (_isLoading) return; // a load is in flight
      if (_advancing) return; // an advance chain is running
      if (_queueEndRetryTimer != null) return; // queue-end retry pending
      if (_pausedForOffline) return; // offline pause owns recovery
      if (_currentSong == null) return;
      if (_queue.isEmpty) return;
      // Global failure limit: stop hammering the resolver when every
      // queued song is unresolvable.
      if (_globalAdvanceFailures >= _maxGlobalAdvanceFailures) {
        return;
      }
      final st = _player.processingState;
      if (st != ProcessingState.completed && st != ProcessingState.idle) {
        return; // not a terminal/empty state; something else is happening
      }
      final cur = _currentSong;
      unawaited(playNext(0, false, null, true).then((ok) {
        if (!ok && !_player.playing && !_isLoading && !_advancing) {
          if (cur != null && cur.id == _currentSong?.id) {
            _scheduleCompletionGuardRetry();
          }
        }
      }).catchError((Object e) {
        if (cur != null && cur.id == _currentSong?.id) {
          _scheduleCompletionGuardRetry();
        }
      }));
    });
  }

  /// Re-arms the completion guard after a failed advance, with growing
  /// backoff (6s/10s/15s/25s/40s/60s) capped at 6 retries. Gentler than a
  /// fixed 3s loop, so a DNS/network outage doesn't hammer the resolver.
  /// Per-song retry limit: after 3 retries on the SAME next song, skip it
  /// and try the following one. Prevents infinite retry loop on a
  /// permanently failing song while allowing transient network issues to recover.
  void _scheduleCompletionGuardRetry() {
    // Background retries are owned by the background heal; only re-arm the
    // guard in the foreground so the two never double-advance.
    if (_appBackgrounded) return;
    // Global failure limit: stop retrying when every queued song fails.
    if (_globalAdvanceFailures >= _maxGlobalAdvanceFailures) {
      return;
    }
    _completionGuardCount++;
    if (_completionGuardCount > 4) {
      _completionGuardCount = 0;
      return; // give up; connectivity-changed / manual resume recovers
    }
    const delays = [6, 10, 15, 25];
    final delay = delays[_completionGuardCount - 1];
    _completionGuard?.cancel();
    final guardGen = _playGen;
    _completionGuard = Timer(Duration(seconds: delay), () {
      _completionGuard = null;
      if (guardGen != _playGen) return;
      if (_player.playing) return;
      if (_isLoading || _advancing) return;
      if (_queueEndRetryTimer != null) return;
      if (_pausedForOffline) return;
      if (_currentSong == null || _queue.isEmpty) return;
      final st = _player.processingState;
      if (st != ProcessingState.completed && st != ProcessingState.idle) {
        return;
      }
      // Per-song retry limit for the next song
      final nextIdx = _currentIndex + 1;
      if (nextIdx < _queue.length) {
        final nextSongId = _queue[nextIdx].id;
        final retries = (_completionGuardSongCounts[nextSongId] ?? 0) + 1;
        if (_completionGuardSongCounts.length > 200) {
          _completionGuardSongCounts.clear();
        }
        _completionGuardSongCounts[nextSongId] = retries;
        if (retries > 3) {
          _completionGuardSongCounts.remove(nextSongId);
          unawaited(playNext(0, false, nextIdx + 1, true).then((ok) {
            if (!ok && !_player.playing && !_isLoading && !_advancing) {
              _scheduleCompletionGuardRetry();
            }
          }).catchError((Object e) {
            _scheduleCompletionGuardRetry();
          }));
          return;
        }
      }
      unawaited(playNext(0, false, null, true).then((ok) {
        if (!ok && !_player.playing && !_isLoading && !_advancing) {
          _scheduleCompletionGuardRetry();
        }
      }).catchError((Object e) {
        _scheduleCompletionGuardRetry();
      }));
    });
  }

  void _cancelCompletionGuard() {
    _completionGuard?.cancel();
    _completionGuard = null;
    _completionGuardCount = 0;
  }

  /// Seed-based radio for search queues: when a search queue ends, keep
  /// music going with tracks similar to the initially-tapped song. The
  /// batch is language/duration filtered, de-duplicated, and excludes
  /// queued, finished, and seed tracks. Origin becomes 'searchRadio' so
  /// the chain continues automatically after every completed track.
  /// Never throws; best-effort like all autoplay.
  Future<bool> _playSeedRadio() async {
    _resyncIndex();
    if (_currentIndex < _queue.length - 1) {
      final target = _queue[_currentIndex + 1];
      if (await _playWithRetry(target, _currentIndex + 1)) return true;
    }
    final seed = _autoplaySeed ?? _currentSong;
    if (seed == null) {
      _scheduleBackgroundRetry();
      _retryQueueEnd();
      return false;
    }
    List<Song> pool = const [];
    MusicLanguage lang = MusicLanguage.all;
    try {
      lang = await UserPrefs().getLanguage();
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
    }
    // Filter each source with the strict DISCOVERY gate and keep trying
    // until one yields a usable pool. The emptiness check runs AFTER
    // filtering: a batch that filters out entirely (all music videos /
    // unknown lengths) must fall through to the next source instead of
    // reporting "no similar tracks".
    Future<List<Song>> fromSource(
        Future<List<Song>> Function() fetch, String label) async {
      try {
        final raw = await fetch().timeout(const Duration(seconds: 12));
        final qualified = SongFilter.applyDiscovery(raw, language: lang);
        return qualified;
      } catch (e) {
        return const [];
      }
    }

    final vid = seed.videoId ?? seed.id;
    if (vid.isNotEmpty) {
      pool = await fromSource(
          () => _youtubeService.getRelatedVideos(vid, limit: 20), 'related');
    }
    if (pool.isEmpty && seed.artist.isNotEmpty) {
      pool = await fromSource(
          () => _youtubeService.search('${seed.artist} songs', limit: 15),
          'artist');
    }
    if (pool.isEmpty && seed.title.isNotEmpty) {
      pool = await fromSource(
          () => _youtubeService.search(seed.title, limit: 15), 'title');
    }
    // Never leave the user stuck on a paused player: last resort is their
    // own library (liked + recent), which needs no network and is already
    // known to play.
    if (pool.isEmpty) {
      try {
        final liked = await _storage.getLikedSongs();
        final recent = await _storage.getRecentlyPlayed();
        pool = SongFilter.apply([...liked, ...recent], language: lang);
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
    }
    final doneId = _currentSong?.id;
    final doneVid = _currentSong?.videoId ?? doneId;
    final seedId = seed.id;
    final seedVid = seed.videoId ?? seedId;
    final seen = <String>{};
    final batch = <Song>[];
    for (final s in pool) {
      final v = s.videoId;
      if (v == null || v.isEmpty) continue; // unplayable without a video
      if (s.title.trim().isEmpty) continue; // junk result
      if (!seen.add(v)) continue; // duplicate within this batch
      if (v == doneVid || s.id == doneId) continue; // just finished
      if (v == seedVid || s.id == seedId) continue; // the seed itself
      if (_playedIds.contains(s.id) || _playedIds.contains(v)) continue;
      if (_queue.any((q) => q.id == s.id || (q.videoId ?? q.id) == v)) {
        continue; // already queued
      }
      batch.add(s);
      if (batch.length >= 10) break;
    }
    if (batch.isEmpty) {
      _noteFailure('no similar tracks to continue radio');
      // Nothing suitable: heal in background instead of sitting paused.
      _scheduleBackgroundRetry();
      _retryQueueEnd();
      return false;
    }
    _resyncIndex();
    final base = _currentIndex + 1;
    _queue = [..._queue, ...batch];
    _queueOrigin = 'searchRadio';
    notifyListeners();
    final target = batch.first;
    if (await _playWithRetry(target, base)) return true;
    // Load failed after retries: heal in background, never sit paused.
    _scheduleBackgroundRetry();
    _retryQueueEnd();
    return false;
  }

  /// Keeps music going after the queue ends: related videos first,
  /// then songs by the same artist, then a title search. A failed
  /// autoplay restores the finished track's ended state instead of
  /// stranding playback paused on an unrelated song.
  Future<bool> _autoPlay() async {
    if (_currentSong == null) return false;
    final prevSong = _currentSong!;
    final prevQueue = List<Song>.from(_queue);
    final prevIndex = _currentIndex;
    final prevDur = _duration;
    try {
      final cur = _currentSong!;
      final id = cur.videoId ?? cur.id;
      // Exclude the just-finished track by BOTH id and video: a
      // related/search hit carrying the same video under a different id
      // string would otherwise replay it from 00:00 right after it ended.
      final doneId = cur.id;
      final doneVid = cur.videoId ?? doneId;
      // GLOBAL rules cover autoplay/related content too. Autoplay is not
      // language-restricted, but it must not queue long-form/music-video
      // uploads or entries with no verifiable length. Filter each source
      // and fall through to the next when a source is fully filtered out.
      Future<List<Song>> qualified(Future<List<Song>> Function() fetch) async {
        try {
          final raw = await fetch().timeout(const Duration(seconds: 12));
          final cleaned = raw
              .where((s) =>
                  s.id != doneId && s.id != doneVid && s.videoId != doneVid)
              .toList();
          return SongFilter.applyDiscovery(cleaned,
              language: MusicLanguage.all);
        } catch (e) {
          return const [];
        }
      }

      List<Song> next = const [];
      if (id.isNotEmpty) {
        next = await qualified(
            () => _youtubeService.getRelatedVideos(id, limit: 12));
      }
      if (next.isEmpty && cur.artist.isNotEmpty) {
        next = await qualified(
            () => _youtubeService.search('${cur.artist} songs', limit: 12));
      }
      if (next.isEmpty && cur.title.isNotEmpty) {
        next =
            await qualified(() => _youtubeService.search(cur.title, limit: 12));
      }
      // Never strand playback: fall back to the user's own library, which
      // needs no network and is already known to play.
      if (next.isEmpty) {
        try {
          final liked = await _storage.getLikedSongs();
          final recent = await _storage.getRecentlyPlayed();
          next = SongFilter.apply([...liked, ...recent])
              .where((s) =>
                  s.id != doneId && s.id != doneVid && s.videoId != doneVid)
              .toList();
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
      }
      if (next.isNotEmpty) {
        _queue = next;
        _currentIndex = 0;
        if (await _playWithRetry(next.first, 0)) return true;
        _noteFailure('autoplay could not load next track');
        // Autoplay load failed: restore the finished track so playback
        // ends normally instead of sitting paused on an unrelated song.
        _queue = prevQueue;
        _currentIndex =
            prevQueue.isEmpty ? -1 : prevIndex.clamp(0, prevQueue.length - 1);
        _currentSong = prevSong;
        _duration = prevDur;
        _position = prevDur;
        _isPlaying = false;
        _isLoading = false;
        notifyListeners();
        _retryQueueEnd();
      }
      _retryQueueEnd();
      return false;
    } catch (e) {
      // Autoplay is best-effort, never crash playback state.
      return false;
    }
  }

  Future<bool> playPrevious() async {
    if (!_skipGuard()) return true;
    if (_queue.isEmpty) return false;
    _resyncIndex();
    int prevIndex;
    if (_currentIndex > 0) {
      prevIndex = _currentIndex - 1;
    } else if (_loopMode == LoopMode.all) {
      prevIndex = _queue.length - 1; // repeat-all wraps to queue end.
    } else {
      try {
        await seek(Duration.zero);
        return true;
      } catch (e) {
        return false;
      }
    }
    try {
      final target = _queue[prevIndex];
      final beforeGen = _playGen;
      final ok = await playSong(target, index: prevIndex);
      if (ok) {
        return true;
      }
      // Superseded by a newer tap: silent. Otherwise report failure.
      if (_playGen != beforeGen + 1) return true;
      return false;
    } catch (e) {
      // Keep current track on failure instead of going silent.
      return false;
    }
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  /// Loop the current song on/off. Replaces the old off→all→one cycle;
  /// repeat-all is no longer reachable from the UI.
  Future<void> toggleRepeat() async {
    _loopMode = _loopMode == LoopMode.one ? LoopMode.off : LoopMode.one;
    try {
      await _player.setLoopMode(
        _loopMode == LoopMode.one ? LoopMode.one : LoopMode.off,
      );
    } catch (e) {
      // Cosmetic on failure; manual repeat logic still applies.
    }
    notifyListeners();
  }

  /// Queue [song] to play once, immediately after the current song. A second
  /// call replaces the pending slot; a fresh explicit queue drops it.
  void setPlayNext(Song song) {
    _playNextOverride = song;
    notifyListeners();
  }

  /// Pause is idempotent and never throws, so the Play/Pause button cannot
  /// get stuck after backgrounding. UI updates optimistically then re-syncs
  /// from the real player state.
  Future<void> pause() async {
    try {
      _cancelStallTimer();
      _cancelQueueEndRetry();
      _cancelCompletionGuard();
      // Explicit user pause wins over any pending background heal.
      _cancelBackgroundRetry('user pause');
      // Explicit user pause also cancels the offline auto-resume: user
      // intent wins over automatic recovery.
      if (_pausedForOffline) {
        _pausedForOffline = false;
      }
      _cancelOfflineResumeRetry('user pause');
      if (!_isPlaying) {
        // Already paused: still sync in case native state drifted in background.
        syncPlaybackState();
        return;
      }
      _isPlaying = false;
      notifyListeners();
      // Bounded: a hung platform pause must not wedge the button handler.
      await _player.pause().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Player command is best-effort; state re-syncs from the stream.
      // Ignore native errors; UI must stay responsive.
    } finally {
      syncPlaybackState();
    }
  }

  /// Resume re-activates the audio session (required after background) and
  /// never throws. Handles completed state by seeking to start.
  Future<void> resume() async {
    // play() completes when playback STOPS, so awaiting it here wedged
    // resume for up to 20s on "open app to restart music". Fire it and
    // sync from the state stream instead.
    final resumeGen = _playGen;
    try {
      if (_currentSong == null) return;
      await _activateSession();
      if (resumeGen != _playGen) {
        return;
      }
      // Do NOT seek to zero on completed state: seeking a preview/truncated
      // stream restarts playback from beginning and creates 15-20s loop.
      // Just resume from current position; if completed, just_audio will
      // restart naturally if loop mode is set.
      // Optimistic update for instant button feedback.
      _isPlaying = true;
      notifyListeners();
      _startStallTimer();
      unawaited(_player.play().then((_) {
        if (resumeGen != _playGen) {}
      }).catchError((Object e) {
        try {
          syncPlaybackState();
        } catch (_) {
          // Non-fatal: the surrounding watchdog covers this path.
        }
      }));
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
      // Play failed (focus loss, timeout): sync reality so button stays live.
    } finally {
      try {
        syncPlaybackState();
      } catch (_) {
        // Non-fatal: the surrounding watchdog covers this path.
      }
      // pause() cancelled the recovery timers; pressing play must restore
      // them or a source that failed to load resumes into silence with no
      // pending heal. Re-arm whatever the current state still calls for.
      _rearmRecovery();
    }
  }

  /// Re-establishes the self-heal timers after a user resume. Safe to call
  /// in any state: each arm() bails when its precondition is not met.
  void _rearmRecovery() {
    // A stale heal budget must not block a fresh user-initiated attempt.
    _bgRetrySince = null;
    _scheduleBackgroundRetry();
    if (_pausedForOffline && _appBackgrounded) {
      _armOfflineResumeRetry();
    }
  }

  /// Re-syncs [_isPlaying]/[_processingState] from the underlying player.
  /// Call on app resume (foreground) to heal background drift where the
  /// native player paused but Dart state still said playing (or vice versa).
  void syncPlaybackState() {
    try {
      _processingState = _player.processingState;
      _isPlaying = _player.playing &&
          _player.processingState != ProcessingState.completed;
    } catch (_) {
      // Non-fatal: the surrounding watchdog covers this path.
    }
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Player command is best-effort; state re-syncs from the stream.
    }
  }

  Future<void> stop() async {
    ++_playGen;
    try {
      _cancelStallTimer();
      _cancelBackgroundRetry('stop');
      _cancelOfflineResumeRetry('stop');
      _cancelLoadWatchdog();
      _cancelQueueEndRetry();
      _cancelCompletionGuard();
      _bgRetrySongCounts.clear();
      _completionGuardSongCounts.clear();
      _clearPreloadState();
      _preparingContinuation = false;
      _bgRetryCount = 0;
      _globalAdvanceFailures = 0;
      _recordPreviousListen(skipped: true);
      _songPlayStart = null;
      try {
        await _player.stop().timeout(const Duration(seconds: 5));
      } catch (_) {
        // Player command is best-effort; state re-syncs from the stream.
      }
      _currentSong = null;
      _activeSongId = null;
      _activeSince = null;
      _activeGen = 0;
      _pendingIndex = null;
      _handlingCompletion = false;
      _retryCount = 0;
      _lastRetrySongId = null;
      _isPlaying = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _lastNotifiedSecond = -1;
      if (_pausedForOffline) {
        _pausedForOffline = false;
      }
      _pausedForOfflineSongId = null;
      _pausedForOfflineIndex = null;
      _pausedForOfflineGen = null;
      _resetOfflineSession('stop');
    } finally {
      notifyListeners();
    }
  }

  Future<bool> downloadCurrentSongForSong(Song song,
      {bool addToDownloadedPlaylist = true}) async {
    try {
      // If already cached, just record it â€” no network, no playback glitch.
      final cached = await _cache.getValid(song);
      if (cached != null) {
        await _storage.addDownloadedSong(song);
        if (addToDownloadedPlaylist) {
          await _storage.addSongToDownloadedPlaylist(song);
        }
        return true;
      }
      final report =
          PlaybackReport(song.title, songId: song.videoId ?? song.id);
      // Explicit downloads claim the network too: a later playSong (or
      // another download) supersedes them so stale work stops early.
      _claimLoad();
      // Resolve once, then share the verified-download helper with
      // playback so explicit downloads validate identically.
      final source = await _strategy.resolveFirstValid(song, report);
      if (source == null) {
        return false;
      }
      try {
        await _downloadSource(source, song, report);
      } catch (e) {
        return false;
      }
      await _storage.addDownloadedSong(song);
      if (addToDownloadedPlaylist) {
        await _storage.addSongToDownloadedPlaylist(song);
      }
      // Download-complete callback (no polling): the song may be the one
      // preload gave up on, unblock degraded mode, or resume the queue.
      // A downloaded song is available by definition: drop it from the
      // known-unavailable map so the next gate sees the new file. Exit
      // degraded mode once nothing is known-unavailable anymore.
      final downloadedInQueue = _queue.any((q) => q.id == song.id);
      if (_offlineKnownUnavailable.remove(song.id) != null) {
        if (_offlineKnownUnavailable.isEmpty && _degradedOffline) {
          _degradedOffline = false;
          notifyListeners();
        }
      }
      if (_preloadedBlockedSongIds.remove(song.id)) {
        _ensurePrefetch();
      }
      if (_pausedForOffline &&
          (_pausedForOfflineSongId == song.id || downloadedInQueue) &&
          _pausedForOfflineGen == _playGen) {
        // Resume the PAUSED song, not the downloaded one: its load
        // re-gates and skip-searches fresh, landing on the new file when
        // that is what is playable. Loading the downloaded song at the
        // paused index would play the wrong track.
        Song resumeSong = song;
        int? resumeIdx = _pausedForOfflineIndex;
        final pausedId = _pausedForOfflineSongId;
        if (pausedId != null) {
          final at = _queue.indexWhere((q) => q.id == pausedId);
          if (at >= 0) {
            resumeSong = _queue[at];
            resumeIdx = at;
          }
        }
        _pausedForOffline = false;
        unawaited(playSong(resumeSong,
                index: resumeIdx,
                autoplayOnEnd: _autoplayOnEnd,
                queueOrigin: _queueOrigin)
            .then((_) {}, onError: (Object e) {}));
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Cancel every timer and subscription: a leaked timer fires playNext /
    // player commands on a disposed player, and the connectivity stream
    // keeps calling into a dead notifier.
    _cancelStallTimer();
    _cancelBackgroundRetry();
    _cancelOfflineResumeRetry();
    _cancelLoadWatchdog();
    _cancelQueueEndRetry();
    _cancelCompletionGuard();
    _cancelPreloadRetry();
    _cancelEndPreload();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player.dispose();
    _youtubeService.dispose();
    _youTube.dispose();
    super.dispose();
  }
}
