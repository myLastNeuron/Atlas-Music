import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'screens/auto_finds_screen.dart';
import 'screens/welcome_flow.dart';
import 'services/auto_listen.dart';
import 'services/identify_bridge.dart';
import 'widgets/app_transitions.dart';
import 'widgets/identify_sheet.dart';

class AtlasMusicApp extends StatefulWidget {
  const AtlasMusicApp({super.key});

  @override
  State<AtlasMusicApp> createState() => _AtlasMusicAppState();
}

class _AtlasMusicAppState extends State<AtlasMusicApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<void>? _identifySub;
  StreamSubscription<void>? _historySub;
  StreamSubscription<void>? _autoStartSub;
  bool _sheetOpen = false;
  bool _pendingOpen = false;

  @override
  void initState() {
    super.initState();
    final bridge = IdentifyBridge.instance;
    _identifySub = bridge.requests.listen((_) => _openIdentify());
    _historySub = bridge.historyRequests.listen((_) => _openAutoFinds());
    _autoStartSub = bridge.autoStartRequests.listen((_) {
      AutoListenController.instance.start();
    });
    bridge.start();
  }

  @override
  void dispose() {
    _identifySub?.cancel();
    _historySub?.cancel();
    _autoStartSub?.cancel();
    super.dispose();
  }

  /// Raised by a tapped song-found / Auto-listen notification: open the Auto
  /// song fetch history (never the full player).
  void _openAutoFinds() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        pushAppPage(ctx, const AutoFindsScreen());
      }
    });
  }

  /// Shows the Find-song sheet after the next frame, so the navigator is ready
  /// and recording starts once the UI is on screen.
  ///
  /// ponytail: no null-navigator retry — every trigger arrives once Dart is
  /// already running, so the navigator exists. Add one if a cold-start tap is
  /// ever dropped.
  void _openIdentify() {
    if (_sheetOpen) {
      // Still open (or closing): re-open as soon as it closes.
      _pendingOpen = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _sheetOpen) return;
      final ctx = _navigatorKey.currentContext;
      if (ctx == null) return;
      _sheetOpen = true;
      await showIdentifySheet(ctx);
      _sheetOpen = false;
      if (_pendingOpen) {
        _pendingOpen = false;
        _openIdentify();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Atlas Music',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: AppTheme.light(),
      home: const WelcomeScreen(),
    );
  }
}
