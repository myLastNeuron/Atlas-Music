import 'package:flutter/services.dart';

/// Bridges the battery-optimization status/opt-in to native code.
///
/// Android does not allow an app to grant the battery-optimization exemption
/// itself — only the system UI can. So the app auto-opens the system dialog
/// once, on the first run (in MainActivity, chained behind the notification
/// ask), and Profile exposes the same request for later changes. (The
/// notification permission is also handled natively on first run.)
class SystemPermissions {
  SystemPermissions._();
  static final SystemPermissions instance = SystemPermissions._();

  static const MethodChannel _channel =
      MethodChannel('atlas/permissions');

  /// True when the app is already on the battery-optimization allowlist.
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "allow background" dialog. Must be called from a user
  /// gesture (e.g. tapping the Profile row) — it cannot be auto-accepted.
  Future<void> requestBatteryExemption() async {
    try {
      await _channel.invokeMethod('requestBatteryExemption');
    } catch (_) {}
  }
}
