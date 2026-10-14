import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:atlas_music/services/identify_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('atlas/identify');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a parked cold-start request is delivered once Dart starts', () async {
    // MainActivity answers consumeInitialIdentify with the parked extra.
    messenger.setMockMethodCallHandler(channel, (call) async {
      return call.method == 'consumeInitialIdentify' ? true : null;
    });

    final bridge = IdentifyBridge.instance..debugReset();
    final request = bridge.requests.first; // subscribed before start()
    bridge.start();

    await request.timeout(const Duration(seconds: 2));
  });

  test('a native push reaches the app while it is already running', () async {
    // No parked extra: the tile invokes `identify` straight through.
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    final bridge = IdentifyBridge.instance..debugReset();
    final request = bridge.requests.first;
    bridge.start();

    await messenger.handlePlatformMessage(
      'atlas/identify',
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('identify')),
      (_) {},
    );

    await request.timeout(const Duration(seconds: 2));
  });

  test('a tapped song-found notification asks for the Auto history', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    final bridge = IdentifyBridge.instance..debugReset();
    final openHistory = bridge.historyRequests.first;
    bridge.start();

    await messenger.handlePlatformMessage(
      'atlas/identify',
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('showHistory')),
      (_) {},
    );

    await openHistory; // Completes only if the request was surfaced.
  });

  test('the Auto-listen shortcut starts listening', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    final bridge = IdentifyBridge.instance..debugReset();
    final start = bridge.autoStartRequests.first;
    bridge.start();

    await messenger.handlePlatformMessage(
      'atlas/identify',
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('autoStart')),
      (_) {},
    );

    await start; // Completes only if the shortcut was surfaced.
  });

  test('startAutoListen reports failure when native has no handler', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final bridge = IdentifyBridge.instance..debugReset();

    expect(await bridge.startAutoListen(), isFalse);
  });

  test('a native autoStop is surfaced on autoStops', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);

    final bridge = IdentifyBridge.instance..debugReset();
    final stopped = bridge.autoStops.first;
    bridge.start();

    await messenger.handlePlatformMessage(
      'atlas/identify',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('autoStop')),
      (_) {},
    );

    await stopped; // Completes only if the stop was surfaced.
  });
}
