import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../services/audio_service.dart';
import '../widgets/floating_glass_nav.dart';
import '../widgets/liquid_background.dart';
import '../widgets/mini_player.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/library_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/welcome_flow.dart';

class AtlasMusicApp extends StatelessWidget {
  const AtlasMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Atlas Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const WelcomeScreen(),
    );
  }
}

/// Root tabs with floating glass nav. [userName] renders top-right only —
/// never app title in header per design spec.
class MainNavigation extends StatefulWidget {
  final String userName;
  final bool interactive;
  const MainNavigation(
      {super.key, required this.userName, this.interactive = true});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _index = 0;
  List<Widget>? _screens;
  late final PageController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = PageController(initialPage: _index);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background pause can drift Dart UI state from native player state.
    // Re-sync on foreground so Play/Pause never appears dead. The flag
    // lets the player tell genuine completion apart from background
    // telemetry gaps — without it every background blip looks live.
    if (state == AppLifecycleState.resumed && mounted) {
      try {
        final audio = context.read<AudioPlayerService>();
        audio.setAppBackgrounded(false);
        audio.syncPlaybackState();
      } catch (_) {}
    } else if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        mounted) {
      try {
        context.read<AudioPlayerService>().setAppBackgrounded(true);
      } catch (_) {}
    }
  }

  List<Widget> _buildScreens() {
    return _screens ??= [
      _KeepAliveTab(child: HomeScreen(userName: widget.userName)),
      const _KeepAliveTab(child: SearchScreen()),
      const _KeepAliveTab(child: LibraryScreen()),
      _KeepAliveTab(child: ProfileScreen(userName: widget.userName)),
    ];
  }

  void _selectTab(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _tabController.animateToPage(
      index,
      duration: AppMotion.tab,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Selector instead of watch: rebuild shell only when song identity
    // changes (start/stop), NOT every 1/sec position tick.
    // Include isLoading so the bar stays visible across auto-advance
    // gaps and cold-start loads instead of vanishing.
    final hasSong = context.select<AudioPlayerService, bool>(
        (s) => s.currentSong != null || s.isLoading);
    return LiquidBackground(
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: Colors.transparent,
            extendBody: true,
            body: IgnorePointer(
              ignoring: !widget.interactive,
              child: PageView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: _buildScreens(),
              ),
            ),
            bottomNavigationBar: IgnorePointer(
              ignoring: !widget.interactive,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: AppMotion.modal,
                    curve: AppMotion.curve,
                    alignment: Alignment.bottomCenter,
                    child: AnimatedSwitcher(
                      duration: AppMotion.modal,
                      switchInCurve: AppMotion.curve,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.16),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: hasSong
                          ? const Padding(
                              key: ValueKey('mini-player-visible'),
                              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: MiniPlayer(),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('mini-player-hidden'),
                            ),
                    ),
                  ),
                  FloatingGlassNav(
                    currentIndex: _index,
                    onTap: _selectTab,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PageView's children are normally eligible for disposal offscreen. Keeping
/// each tab alive preserves its scroll position, filters, and in-progress UI
/// state while still allowing the shell to glide between tabs.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
