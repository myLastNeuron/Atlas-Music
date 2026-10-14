import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges native triggers (the "Find song" Quick Settings tile, the Auto-listen
/// notification and the "Auto listen" launcher shortcut) to the Dart UI.
class IdentifyBridge {
  IdentifyBridge._();
  static final IdentifyBridge instance = IdentifyBridge._();

  static const MethodChannel _channel = MethodChannel('atlas/identify');

  /// Raised by the "Find song" tile: open the sheet and listen.
  final _requests = StreamController<void>.broadcast();
  Stream<void> get requests => _requests.stream;

  /// Raised when a "song found" / Auto-listen notification is tapped: open the
  /// Auto song fetch history.
  final _historyRequests = StreamController<void>.broadcast();
  Stream<void> get historyRequests => _historyRequests.stream;

  /// Raised by the "Auto listen" launcher shortcut: turn Auto-listen on.
  final _autoStartRequests = StreamController<void>.broadcast();
  Stream<void> get autoStartRequests => _autoStartRequests.stream;

  /// Raised when Auto-listen is switched off from its notification.
  final _autoStops = StreamController<void>.broadcast();
  Stream<void> get autoStops => _autoStops.stream;

  bool _started = false;

  /// Call once from the root widget, after subscribing to the streams.
  void start() {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'identify' && !_requests.isClosed) {
        _requests.add(null);
      } else if (call.method == 'showHistory' && !_historyRequests.isClosed) {
        _historyRequests.add(null);
      } else if (call.method == 'autoStart' && !_autoStartRequests.isClosed) {
        _autoStartRequests.add(null);
      } else if (call.method == 'autoStop' && !_autoStops.isClosed) {
        _autoStops.add(null);
      }
      return null;
    });
    _consume<bool>('consumeInitialIdentify', (pending) {
      if (pending == true && !_requests.isClosed) _requests.add(null);
    });
    _consume<bool>('consumeInitialShowHistory', (v) {
      if (v == true && !_historyRequests.isClosed) _historyRequests.add(null);
    });
    _consume<bool>('consumeInitialAutoStart', (v) {
      if (v == true && !_autoStartRequests.isClosed) {
        _autoStartRequests.add(null);
      }
    });
  }

  void _consume<T>(String method, void Function(T?) onValue) {
    _channel.invokeMethod<T>(method).then(onValue).catchError((_) {});
  }

  /// Starts the Auto-listen microphone foreground service. Returns false when
  /// the platform refused to start it.
  Future<bool> startAutoListen() async {
    try {
      final ok = await _channel.invokeMethod<bool>('startAutoListen');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stops the Auto-listen service.
  Future<void> stopAutoListen() async {
    try {
      await _channel.invokeMethod<void>('stopAutoListen');
    } catch (_) {}
  }

  /// Reports Auto-listen state to native, which drives the Quick Settings tile.
  Future<void> setAutoActive(bool active) async {
    try {
      await _channel.invokeMethod<void>('autoActive', active);
    } catch (_) {}
  }

  /// Silently updates the ongoing Auto-listen notification with the latest find.
  /// No new notification is posted, so Auto never nags the user.
  Future<void> autoFound(String label) async {
    try {
      await _channel.invokeMethod<void>('autoFound', label);
    } catch (_) {}
  }

  /// The bridge lives for the whole process, so this exists only to give tests
  /// a clean slate between cases.
  @visibleForTesting
  void debugReset() {
    _started = false;
  }
}
