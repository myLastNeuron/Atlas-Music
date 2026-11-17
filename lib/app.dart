import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import 'screens/auto_finds_screen.dart';
import 'screens/player_screen.dart';
import 'screens/welcome_flow.dart';
import 'services/auto_listen.dart';
import 'services/identify_bridge.dart';
import 'services/terms.dart';
import 'services/theme_settings.dart';
import 'services/user_prefs.dart';
import 'widgets/app_transitions.dart';
import 'widgets/identify_sheet.dart';

/// The observer the app installs on its navigator, exposed so a widget test
/// can attach it to a test navigator.
@visibleForTesting
NavigatorObserver buildPlayerRouteObserver() => _PlayerRouteObserver();

bool _isPlayerRoute(Route<dynamic>? route) =>
    route?.settings.name == PlayerScreen.routeName;

/// Keeps [playerRouteAbove] in step with the navigator. The route below the
/// player must not fade while the player's card grows over it: the card grows
/// out of the mini bar, so that bar has to stay put and visible.
class _PlayerRouteObserver extends NavigatorObserver {
  Animation<double>? _closingAnimation;
  void Function(AnimationStatus)? _closingListener;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A new route supersedes any close still in flight.
    _detachClosingListener();
    playerRouteAbove = _isPlayerRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_isPlayerRoute(route)) {
      playerRouteAbove = false;
      return;
    }
    // Still true while the player pops: the card shrinks back into the bar,
    // which must not fade in beneath it.
    playerRouteAbove = true;
    _detachClosingListener();
    final Animation<double>? animation =
        route is TransitionRoute<dynamic> ? route.animation : null;
    if (animation == null) {
      // No animation to watch: the route is already gone.
      playerRouteAbove = _isPlayerRoute(previousRoute);
      return;
    }
    if (animation.status == AnimationStatus.dismissed) {
      // The pop finished before the observer was notified.
      playerRouteAbove = _isPlayerRoute(previousRoute);
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.dismissed) {
        // The reverse animation completed: the player route is gone.
        playerRouteAbove = _isPlayerRoute(previousRoute);
        _detachClosingListener();
      } else if (status == AnimationStatus.completed) {
        // A cancelled close left the player on screen.
        playerRouteAbove = true;
        _detachClosingListener();
      }
    }

    _closingAnimation = animation;
    _closingListener = onStatus;
    animation.addStatusListener(onStatus);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isPlayerRoute(route)) _detachClosingListener();
    playerRouteAbove = _isPlayerRoute(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (_isPlayerRoute(oldRoute) || _isPlayerRoute(newRoute)) {
      _detachClosingListener();
      playerRouteAbove = _isPlayerRoute(newRoute);
    }
  }

  /// Drops the one-shot close listener so it cannot later overwrite the state
  /// set by a newer navigation event.
  void _detachClosingListener() {
    if (_closingAnimation != null && _closingListener != null) {
      _closingAnimation!.removeStatusListener(_closingListener!);
    }
    _closingAnimation = null;
    _closingListener = null;
  }
}

class AtlasMusicApp extends StatefulWidget {
  const AtlasMusicApp({super.key});

  @override
  State<AtlasMusicApp> createState() => _AtlasMusicAppState();
}

class _AtlasMusicAppState extends State<AtlasMusicApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _playerRouteObserver = _PlayerRouteObserver();
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTerms());
  }

  /// First launch: the terms gate. Nothing is stored until Accept, so a
  /// Decline (which closes the app) asks again on the next launch.
  Future<void> _maybeShowTerms() async {
    if (await UserPrefs().hasAcceptedTerms()) return;
    if (!mounted) return;
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text(kTermsTitle),
          content: SingleChildScrollView(
            child: Text(kTermsBody,
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft)),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogCtx);
                SystemNavigator.pop();
              },
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () async {
                await UserPrefs().acceptTerms();
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
              },
              child: const Text('Accept'),
            ),
          ],
        ),
      ),
    );
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
    // Watching the mode rebuilds this app from the root, which is what lets
    // the palette change reach every screen. The frost level is *not* watched
    // here: the glass surfaces read it themselves.
    context.watch<ThemeSettings>();
    return MaterialApp(
      title: 'Atlas Music',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: [_playerRouteObserver],
      theme: AppTheme.build(),
      home: const WelcomeScreen(),
    );
  }
}
