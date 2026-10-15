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

  /// True when Atlas may launch the package installer for a downloaded APK.
  /// Android 8.0+ gates this behind a per-app "install unknown apps" toggle
  /// that only the user can grant.
  Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "install unknown apps" screen for Atlas so the user can
  /// grant the permission the installer needs.
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// Hands a downloaded APK to the Android package installer. Returns false
  /// when the platform refused to open the installer.
  Future<bool> installApk(String path) async {
    try {
      return await _channel
              .invokeMethod<bool>('installApk', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
