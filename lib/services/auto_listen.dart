import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shazam_identifier/shazam_identifier.dart';

import 'identify_bridge.dart';
import 'identify_flow.dart';
import 'storage_service.dart';

/// Auto Shazam-style continuous listening.
///
/// It must be started *while the app is visible*: Android only lets a visible
/// app start a microphone foreground service. After that the service keeps the
/// microphone available, so Atlas keeps naming songs that play around the
/// device — including songs in other apps you are looking at — from the
/// background, behind an ongoing notification.
class AutoListenController extends ChangeNotifier {
  AutoListenController._();
  static final AutoListenController instance = AutoListenController._();

  bool _active = false;

  /// Whether Auto-listen is currently running.
  bool get active => _active;

  String? _lastTrackId;
  StreamSubscription<void>? _stopSub;

  /// Starts listening. Returns false if the microphone is unavailable or the
  /// foreground service could not be started.
  Future<bool> start() async {
    if (_active) return true;
    // Subscribe first so a service-side failure (autoStop) is never missed.
    _stopSub ??= IdentifyBridge.instance.autoStops.listen((_) => stop());
    if (!await ensureMicPermission()) return false;
    if (!await IdentifyBridge.instance.startAutoListen()) return false;
    _active = true;
    _lastTrackId = null;
    await IdentifyBridge.instance.setAutoActive(true);
    notifyListeners();
    unawaited(_listen());
    return true;
  }

  /// Stops listening and tears the foreground service down.
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    notifyListeners();
    await IdentifyBridge.instance.setAutoActive(false);
    await IdentifyBridge.instance.stopAutoListen();
  }

  /// Records a clip, identifies it, and repeats until [stop] runs. A track is
  /// reported once (no repeats while the same song keeps playing) and misses
  /// stay silent, so the notification shade is never spammed.
  Future<void> _listen() async {
    while (_active) {
      final status = await identifyRaw(ensurePermission: false);
      final result = status.result;
      if (status.state == RecognitionStatusState.success && result != null) {
        if (result.trackId != _lastTrackId) {
          _lastTrackId = result.trackId;
          try {
            final song = await resolveSong(result);
            if (song != null) {
              await StorageService.instance.addAutoFind(song);
              // Silent: just refresh the ongoing notification, never post a new
              // alert for each song.
              await IdentifyBridge.instance
                  .autoFound('${song.title} · ${song.artist}');
            }
          } catch (_) {
            // Network hiccup resolving the match; keep listening.
          }
        }
      }
      if (_active) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }
}
